# Family AI Server — Project Guide

Familien-KI: native macOS-Menüleisten-App (Swift), die einen eingebetteten HTTP-Server
(Hummingbird 2) betreibt und eine Web-App (PWA, reines JS) ausliefert. Modelle nur über
OpenRouter, ein Schlüssel pro Person. Repo `nicx/family-ai-server` (MIT, Copyright „nicx“).
Öffentlich-tauglich halten: keine IPs, Hostnamen, Mailadressen, Schlüssel oder echten Namen committen
(Beispiele: `ai.example.org`, Demo-Familie Alex/Mia/Leo/Sam).

## Aufbau

- `Sources/FamilyAICore`: `Server.swift` (alle Routen, Middleware), `ChatEngine.swift` (Prompt,
  Werkzeug-Schleife, Titel), `OpenRouter.swift` (Chat-Streaming, /images, /audio/speech,
  /audio/transcriptions, /embeddings, /key, /models), `Store.swift` + `Database.swift`
  (SQLite über libsqlite3, Actor), `Auth.swift` (bcrypt, Sessions, Passkeys/WebAuthn,
  Limiter), `RunnerHub.swift` (Long-Polling-Jobs für Family AI Runner), `Documents.swift`
  (PDFKit-Text, Chunking, Embedding- + Stichwortsuche), `Mailer.swift` (SMTP über curl +
  BudgetMonitor), `KeyStore.swift` (Schlüsselbund via `/usr/bin/security`, FileKeyStore für Tests).
- `Sources/FamilyAIServer`: Menüleisten-App (`FamilyAIMenuBarApp.swift`), `main.swift` mit Headless-Modus `--serve`.
- `Web/`: `index.html`, `app.js`, `markdown.js`, `i18n.js` (de/en), `app.css`, `sw.js`, Icons.
- `Runner/`: Family AI Runner in Go (nur Standardbibliothek). `Scripts/build-runner.sh` baut nach `dist/runner/`, `make-app.sh` legt die Programme unter `Resources/Web/runner/` ins Bundle (Download unter `/runner/…`, Liste über `SHA256SUMS`).
  `__V__` in HTML/JS wird beim Ausliefern durch einen Start-Zeitstempel ersetzt (Cache-Busting).
- `Tests/FamilyAIChecks`: Selbstprüfungen als Executable (`swift run FamilyAIChecks`).

## Bauen & testen

```bash
swift build                                   # Standard-SDK (27) – NICHT auf SDK 26 pinnen (swift-collections bricht)
swift run FamilyAIChecks
(cd Runner && go test ./...)                  # Go via Homebrew
swift run FamilyAIServer --serve --port 8197 --host 127.0.0.1 --data /tmp/family-ai --keys-file /tmp/family-ai-keys.json --web Web
CODESIGN_IDENTITY="nicx Selfsign" ./Scripts/make-app.sh    # → dist/Family AI Server.app
python3 Scripts/make-icons.py                # Icons aus Resources/AppIcon.svg neu rendern (macOS, Pillow)
```

## Linux / Docker

- Gleicher Quelltext, `#if os(macOS)` / `canImport(...)` nur an den Systemgrenzen: `Documents.pdfText`/`officeText` (PDFKit ↔ `pdftotext`/`unzip`), `AudioConvert` (afconvert/ImageIO ↔ `ffmpeg`/`heif-convert`), CryptoKit ↔ `swift-crypto`, `SQLite3` ↔ `CSQLite`, `URLSession.bytes` ↔ `LineStreamLoader`, Menüleisten-App nur mit SwiftUI. Neue Mac-APIs immer mit Linux-Gegenstück bauen.
- Linux testen ohne Spur auf GitHub: Image `fas-dev` (swift:latest + libsqlite3-dev poppler-utils unzip zip ffmpeg libheif-examples libheif-plugin-libde265 python3), Repo kopieren und dort `swift run FamilyAIChecks`; Docker-Image: `docker build -t family-ai-server:test .` (Dauer ~3 min). Release-Workflow `.github/workflows/docker.yml` läuft nur bei Tag `v*`.
- Docker-Schlüssel: `EncryptedKeyStore` (`keys.enc`, AES-GCM, Master-Schlüssel aus `FAMILY_AI_MASTER_KEY[_FILE]`, nie im Volume); falscher Schlüssel → `isLocked`, nie überschreiben. Erstes Admin-Konto nur mit Einmal-Code aus dem Log (`requireSetupCode`, nur Linux). `FAMILY_AI_TRUSTED_PROXIES` bestimmt, welchem Proxy `X-Forwarded-For` geglaubt wird (`Net.clientIP`, `IPRange`) – ohne das ist „Admin nur Heimnetz“ hinter einem Proxy-Container wirkungslos.
- Docker-Runner-Download: Windows-Apps (Tray) + Linux; macOS nur als arm64-Terminalprogramm (keine Mac-App/kein lipo unter Linux; die UI zeigt es nur, wenn `family-ai-runner-macos-app.zip` fehlt); Dokumente ohne RTF/DOC/Pages.

## Fallen

- **Keine SwiftUI-Makros** (`@State`, `@Observable`) – das Standard-SDK 27 der Command Line Tools hat kein Makro-Plugin. `ObservableObject` + `@Published`/`@AppStorage` verwenden. Aus demselben Grund kein XCTest/Swift Testing.
- App läuft produktiv aus `dist/` – `make-app.sh` bricht ab, wenn sie läuft. Nicht aus der Entwicklungsumgebung starten, sondern selbst; vor einem Build beenden.
- Schlüssel nur über `/usr/bin/security` (sonst Schlüsselbund-Abfrage nach jedem Rebuild).
- Alle schreibenden API-Aufrufe brauchen Header `X-Family-AI: 1` (CSRF). Runner-Endpunkte sind ausgenommen (Bearer-Token).
- Modell-Sichtbarkeit (`Server.allowedModels`): Admin = alle; sonst Standardmodelle (Familie/Person) + Profil-`allowedModels` (ZUSÄTZLICH). Keine Familienliste und kein Picker-Schalter: Picker erscheint ab ≥2 Modellen. Eskalationsmodell (`escalationModel`, Familie + Profil: ""=Familie, "off", Modell-ID) wird per `POST chats/:id/regenerate {escalate:true}` einmalig genutzt und von der Liste nicht geprüft.
- Embeddings: Chunks speichern ihr Modell (`chunks.model`); bei Modellwechsel werden abweichende Dokumente in `Documents.search` im Hintergrund neu indiziert, bis dahin greift die Stichwortsuche.
- Datenschutz an OpenRouter: Systemprompt nennt nur den Vornamen (`ChatEngine.firstName`), nie Nach- oder Familienname; Chat-Anfragen tragen `user` = Pseudonym (`ChatEngine.pseudonym`, SHA-256 der Nutzer-ID). Lokal (DB/UI) bleibt alles unverändert. Websuche fest auf Engine `native` (Anbieter-eigene Suche; Firecrawl ist per ZDR blockiert, Google-Modelle ohne ZDR-Endpunkt gehen ohnehin nicht). ZDR wird doppelt erzwungen: Guardrail im OpenRouter-Konto UND in jeder Anfrage (`OpenRouter.request()` setzt `provider: {zdr: true, data_collection: deny}`) – Embedding-, Bild-, TTS- und STT-Modell müssen ZDR-fähig sein (Auswahl testen!).
- OpenRouter-Guardrails der Personen-Schlüssel müssen Bild-, TTS-, STT- und Embedding-Modell erlauben.
- Mail über `/usr/bin/curl` (Konfig-Datei, Passwort nie auf der Kommandozeile); SMTP-Passwort im KeyStore unter `smtp-password`.
- Programmier-Modus ist pro Chat (`mode` "chat"|"code" + `deviceId`) und lässt sich jederzeit per `PATCH chats/:id {mode, deviceId}` umschalten (Server prüft Profil `code` und Besitz des Computers). UI: Schalter `.code-toggle` in der Topbar (`updateCodeBtn`/`setCodeMode`), „Neuer Chat“ startet immer einen normalen Chat. Chatliste: `</>` + Punkt rechts (`codeMark`, grün = Runner online), Geräte-Status wird alle 5 s nachgeladen (`refreshDevices`). Online-Erkennung (`RunnerHub.isOnline`): Poll wartet, Poll vor <6 s oder Job läuft; Poll-Timeout 10 s, Runner meldet sich beim Beenden per `POST runner/bye` ab (sofort offline), Wiederverbinden max. 10 s Pause. Harter Abbruch (kill -9) dauert ~5–10 s, weil Hummingbird das Verbindungsende nicht an den wartenden Handler meldet.
- Runner-Apps: Windows = derselbe Go-Code mit `-tags tray` (`Runner/tray_windows.go`, reines Win32 per syscall, `-H=windowsgui`, Ausgabe `family-ai-runner-tray-windows-*.exe`; Einstellungen per PowerShell-InputBox, Autostart per `reg` in HKCU\\Run, Einzelinstanz per Mutex; `main()` ruft dort `trayMain`, die Schleife steckt in `serve()`; NICHT auf echtem Windows getestet). macOS = `RunnerApp/main.swift` (AppKit, `swiftc` in `Scripts/make-runner-app.sh`, vom `build-runner.sh` aufgerufen) startet das mitgelieferte Runner-Binary als Kindprozess, liest dessen Log für den Status und schreibt `config.json` (Pfad über `$HOME` wie der Runner); Ausgabe `family-ai-runner-macos-app.zip`. Reine Windows-/macOS-Konsolenprogramme werden nicht mehr ausgeliefert (Mac-Runner steckt nur in der App). Log: `logf` schreibt zusätzlich nach `FamilyAIRunner/runner.log` (neben config.json; ab 1 MB wird sie zu `.1`, höchstens ~2 MB, auch bei Dauerbetrieb); Menüpunkt „Protokoll anzeigen“ öffnet es (Mac: Standard-App/Konsole, Windows: Notepad). Standard: Schreiben von Dateien wird nachgefragt (`allowWrites` in config.json / `--allow-writes` hebt das auf). Werkzeug `save_image` (Server liest Bild aus dem Dateispeicher, schickt es base64 als Job-Argument `data`, max. 5 MB; Runner prüft Endung png/jpg/jpeg/webp/gif + Magic Bytes, max. 6 MB, Nachfrage wie `write_file`); `write_file` kann nur Text. Freigabe im Chat: nur wenn der Runner lokal `approveInChat` hat (Schalter in den Apps, `config.json`; der Server kann es NICHT erzwingen – Sicherheitsgrund: Popup am Computer ist der Standard, auch für Kinder). Ablauf: Runner `POST /api/runner/ask {jobId}` (Long-Poll je ≤20 s, Antwort `allow`/`deny`/`pending`, Runner fragt bis 5 min nach, 404 = alter Server → Popup) → `RunnerHub.ask` löst einmal `onAsk` aus → Chat-Ereignis `approval` (Karte `approvalCard` in app.js) → `POST /api/approvals/:jobId {allow}` (nur Besitzer des Computers) → `RunnerHub.decide`. Karte geht beim Neuladen verloren (dann läuft die Anfrage in den Timeout = abgelehnt). Test-Haken: `FAMILY_AI_OPENROUTER_URL` leitet Modellverkehr an einen lokalen Mock um (Ende-zu-Ende-Test der Chat-Freigabe: Mock-OpenRouter mit Werkzeugaufruf + Wegwerf-Server + Runner mit temporärem `HOME`; beim Beenden Runner per PID, nicht per pkill-Muster). Ohne Terminal bricht `ask()` bei EOF ab (sonst Endlosschleife in `setup`).
- Runner-Abfrageparameter mit `%20` statt `+` kodieren (Hummingbird dekodiert `+` nicht).
- TTS: MAI-Stimmen brauchen den langen Namen (`de-DE-Mia:MAI-Voice-2.1-Flash`) und `response_format: mp3`; Gemini-TTS liefert nur PCM (unbrauchbar).
