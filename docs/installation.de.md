# Installationsanleitung

*[English version](installation.md)*

Family AI Server läuft auf **einem Rechner zu Hause**, der durchgehend eingeschaltet ist. Alle anderen öffnen nur eine Webadresse. Wähle eine Variante:

| | **A) Mac** | **B) Docker** |
|---|---|---|
| Für | einen Mac mini / ein MacBook, das an bleibt | einen Linux-Server, ein NAS, Raspberry Pi 5 oder jeden Rechner mit Docker |
| Bedienung | Menüleisten-App, startet beim Anmelden | Container, `docker compose` |
| Schlüssel | macOS-Schlüsselbund | verschlüsselte Datei + Master-Schlüssel |
| Sicherungen | eingebaut (täglich) | eigene Sicherung des Volumes |
| Aufwand | einmal bauen (ca. 5 Minuten) | `docker compose up -d` |

Beide Varianten sind derselbe Server und dieselbe Web-App. Die Schritte 1 und 4 sind gleich.

## 1. OpenRouter vorbereiten (einmalig, beide Varianten)

Alle KI-Modelle kommen über [OpenRouter](https://openrouter.ai) – ein Konto, viele Modelle.

1. Konto anlegen und Guthaben aufladen.
2. Datenschutz-Regeln **jetzt** einstellen, damit sie von Anfang an für jeden Schlüssel gelten (Gründe und Details: [Datenschutz & Sicherheit](privacy.de.md)):
   - *Settings → Privacy*: Anbieter, die mit euren Eingaben trainieren dürfen, ausschalten; ZDR (Zero Data Retention) für die genutzten Anbietergruppen einschalten.
   - *Default workspace → Guardrails*: ZDR für Anthropic, OpenAI, Google, xAI und „Other“ an; Free training aus.
3. **Pro Person einen Schlüssel** anlegen (*Keys*) mit **monatlichem Limit**. Die Schlüssel bereithalten, du trägst sie später in der Verwaltung ein.

## 2A. Auf dem Mac installieren

**Du brauchst:** macOS 14 oder neuer, die Command Line Tools (`xcode-select --install`) und Go (`brew install go`).

```bash
git clone https://github.com/nicx/family-ai-server.git
cd family-ai-server
./Scripts/make-app.sh
```

Das Skript baut den Server und die Runner-Apps (macOS-Menüleisten-App, Windows-Taskleisten-Apps, Linux-Programme) und erzeugt `dist/Family AI Server.app`. Die App nach `/Programme` (`/Applications`) verschieben.

Optional: mit einem eigenen Zertifikat signieren, damit macOS Berechtigungen über neue Builds hinweg behält: `CODESIGN_IDENTITY="Mein Zertifikat" ./Scripts/make-app.sh`. Ohne Zertifikat wird ad hoc signiert.

**Erster Start:** Rechtsklick auf die App → *Öffnen* (sie ist nicht von Apple notarisiert). Bei neueren macOS-Versionen: *Systemeinstellungen → Datenschutz & Sicherheit → Trotzdem öffnen*. In der Menüleiste erscheint ein Stern.

**Einstellungen (Menüleiste → Einstellungen):** *Beim Anmelden starten* (auf einem Server empfohlen), *Täglich um 3 Uhr sichern* und der Sicherungsordner (ein Netzlaufwerk geht, solange es eingehängt ist). Alles zu Personen, Schlüsseln und Modellen steht in der Web-App.

**Aktualisieren:** `git pull`, App beenden (Menüleiste → *Beenden*), `./Scripts/make-app.sh`, wieder starten. Die Daten liegen in `~/Library/Application Support/Family AI Server`.

Weiter mit Schritt 3.

## 2B. Mit Docker installieren

**Du brauchst:** Docker mit dem Compose-Plugin auf einem 64-Bit-Linux-Rechner (amd64 oder arm64).

```bash
mkdir family-ai && cd family-ai
curl -O https://raw.githubusercontent.com/nicx/family-ai-server/main/docker-compose.yml
openssl rand -base64 32 > master.key && chmod 600 master.key
docker compose up -d
docker compose logs family-ai
```

- `master.key` verschlüsselt die gespeicherten OpenRouter-Schlüssel. **Eine Kopie getrennt von den Sicherungen aufbewahren** (Passwortmanager).
- Im Protokoll steht ein **Einrichtungscode** (`XXXX-XXXX`), den du im nächsten Schritt brauchst.
- Der Server lauscht auf Port 8097.

Aktualisieren: `docker compose pull && docker compose up -d`. HTTPS mit Caddy, Sicherungen, Einstellungen und Fehlersuche: [Docker-Anleitung](docker.de.md).

## 3. Die Familie einrichten (beide Varianten)

1. `http://<rechner>:8097` im Browser öffnen (Mac: Menüleiste → *Family AI Server öffnen*). Im selben Netz den Namen oder die IP-Adresse des Rechners verwenden.
2. Das **erste Konto** anlegen (es wird Admin). Bei Docker den Einrichtungscode eingeben. Optional den eigenen OpenRouter-Schlüssel eintragen.
3. *Verwaltung → Personen*: alle anlegen (Kinder bekommen strengere Voreinstellungen), den OpenRouter-Schlüssel jeder Person eintragen.
4. *Verwaltung → Familie & KI*: Namen der KI und Modelle wählen. Die Voreinstellungen funktionieren bereits mit „keine Speicherung“. Einmal testen: Chat mit Websuche, ein Bild, Vorlesen, Diktieren und ein Dokument.

## 4. Erreichbar machen

- **Nur zu Hause:** nichts weiter nötig. Die Adresse des Rechners im Heimnetz verwenden. *Verwaltung → Familie & KI → „Verwaltung nur aus Heimnetz/VPN“* ist eine gute Einstellung.
- **Von außen:** per VPN (empfohlen) oder mit einem Reverse Proxy mit **HTTPS** davor, z. B. [Caddy](https://caddyserver.com):

  ```
  ai.example.org {
      reverse_proxy 127.0.0.1:8097
  }
  ```

  Die öffentliche Adresse (`https://ai.example.org`) unter *Verwaltung → Familie & KI* eintragen. Passkeys, das Mikrofon (Diktieren) und die iPhone-App brauchen HTTPS. Bei Docker läuft der Proxy als zweiter Container ([Docker-Anleitung](docker.de.md)); dort `FAMILY_AI_TRUSTED_PROXIES` setzen.

## 5. Geräte verbinden

- **iPhone / iPad:** Adresse in Safari öffnen → Teilen → *Zum Home-Bildschirm*.
- **Mac / Windows / Android:** im Browser öffnen, optional über das Browser-Menü als App installieren.
- Alle melden sich mit Benutzername und Passwort aus Schritt 3 an und können in den *Einstellungen* einen Passkey hinzufügen.

## Sicherungen und Entfernen

- **Mac:** Die tägliche Sicherung ist standardmäßig an (14 Kopien). Wiederherstellen: App beenden und eine Sicherung über `~/Library/Application Support/Family AI Server/data` kopieren.
- **Docker:** Das Volume selbst sichern, zusammen mit – aber **getrennt von** – `master.key` ([Docker-Anleitung](docker.de.md)).
- **Entfernen:** Mac: App beenden, App und Datenordner löschen. Docker: `docker compose down -v` (das löscht die Daten).

## Wenn etwas nicht klappt

- *„Mikrofon nicht verfügbar“*: Diktieren braucht HTTPS (oder `localhost`).
- *Dokumente werden nicht gefunden*: *Verwaltung → Familie & KI → Embedding-Modell* prüfen, es muss ZDR-fähig sein ([Liste](privacy.de.md)).
- *„ZDR violation“* oder *„No endpoints found matching your data policy“*: Das gewählte Modell hat keinen Endpunkt ohne Speicherung, ein anderes wählen.
- Docker: siehe *Fehlersuche* in der [Docker-Anleitung](docker.de.md).
