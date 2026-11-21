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

## Fallen

- **Keine SwiftUI-Makros** (`@State`, `@Observable`) – das Standard-SDK 27 der Command Line Tools hat kein Makro-Plugin. `ObservableObject` + `@Published`/`@AppStorage` verwenden. Aus demselben Grund kein XCTest/Swift Testing.
- App läuft produktiv aus `dist/` – `make-app.sh` bricht ab, wenn sie läuft. Nicht aus der Entwicklungsumgebung starten, sondern selbst; vor einem Build beenden.
- Schlüssel nur über `/usr/bin/security` (sonst Schlüsselbund-Abfrage nach jedem Rebuild).
- Alle schreibenden API-Aufrufe brauchen Header `X-Family-AI: 1` (CSRF). Runner-Endpunkte sind ausgenommen (Bearer-Token).
- OpenRouter-Guardrails der Personen-Schlüssel müssen Bild-, TTS-, STT- und Embedding-Modell erlauben.
- Mail über `/usr/bin/curl` (Konfig-Datei, Passwort nie auf der Kommandozeile); SMTP-Passwort im KeyStore unter `smtp-password`.
- Runner-Abfrageparameter mit `%20` statt `+` kodieren (Hummingbird dekodiert `+` nicht).
- TTS: MAI-Stimmen brauchen den langen Namen (`de-DE-Mia:MAI-Voice-2.1-Flash`) und `response_format: mp3`; Gemini-TTS liefert nur PCM (unbrauchbar).
