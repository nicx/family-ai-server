# Docker (Linux, NAS, Server)

*[English version](docker.md)* · [Installationsanleitung](installation.de.md)

Neben der macOS-Menüleisten-App gibt es ein Docker-Image für Linux-Rechner (`amd64` und `arm64`: Server, NAS, Raspberry Pi 5 u. ä.). Es ist derselbe Server und dieselbe Web-App, die ohne Oberfläche im Container laufen.

> **Stand:** Der Autor betreibt Family AI Server auf einem Mac. Die Docker-Variante wird automatisch gebaut und geprüft (Selbstprüfung unter Linux bei jedem Release), wird aber von der Gemeinschaft mitgetragen. Bitte Probleme als Issue melden.

## Schnellstart

```bash
mkdir family-ai && cd family-ai
curl -O https://raw.githubusercontent.com/nicx/family-ai-server/main/docker-compose.yml
openssl rand -base64 32 > master.key && chmod 600 master.key
docker compose up -d
docker compose logs family-ai
```

Im Protokoll steht ein **Einrichtungscode** (`==> Einrichtungscode … XXXX-XXXX`). `http://<server>:8097` öffnen, den Code eingeben, das erste Konto anlegen (es wird Admin) und den OpenRouter-Schlüssel eintragen. Danach geht es wie in der README weiter: Personen anlegen, Schlüssel, Modelle und Funktionen einstellen.

Bis das erste Konto existiert, kann es niemand ohne den Code anlegen. Ein frisch gestarteter Container lässt sich also nicht aus dem Netz übernehmen. Nach einem Neustart vor der Einrichtung wird ein neuer Code ausgegeben.

## Der Master-Schlüssel

Die OpenRouter-Schlüssel liegen **verschlüsselt** (AES-256-GCM) im Datenvolume (`/data/keys.enc`). Der Schlüssel dafür ist der **Master-Schlüssel** (`master.key`), der bewusst **außerhalb** des Datenvolumes liegt. Ein gestohlenes Volume oder Backup verrät damit keinen OpenRouter-Schlüssel.

- `master.key` sicher und **getrennt von den Daten-Sicherungen** aufbewahren (z. B. im Passwortmanager).
- Mit falschem oder geändertem Master-Schlüssel startet der Server nicht und überschreibt `keys.enc` nie. Mit dem richtigen Schlüssel läuft alles wieder.
- Ist der Master-Schlüssel endgültig verloren: `keys.enc` löschen und die OpenRouter-Schlüssel neu eintragen (*Verwaltung → Personen*). Konten und Chats bleiben unberührt, Schlüssel lassen sich bei OpenRouter neu erzeugen.

Der Master-Schlüssel kann als Docker Secret (`FAMILY_AI_MASTER_KEY_FILE`, wie in der Compose-Datei) oder direkt als `FAMILY_AI_MASTER_KEY` übergeben werden.

## HTTPS und Reverse Proxy

Für Passkeys, die iPhone-App und den Zugriff von außerhalb sollte der Server über **HTTPS** erreichbar sein. Im Repository liegt ein Zusatz mit [Caddy](https://caddyserver.com) (automatische Zertifikate):

1. Domain in `docker/Caddyfile` eintragen (zusammen mit `docker-compose.proxy.yml` herunterladen; die Domain muss auf den Server zeigen, Ports 80/443 erreichbar).
2. `docker compose -f docker-compose.yml -f docker-compose.proxy.yml up -d`
3. Die öffentliche Adresse unter *Verwaltung → Familie & KI* eintragen (Passkeys brauchen sie).

Jeder andere Reverse Proxy geht genauso: Er muss `X-Forwarded-For` und `X-Forwarded-Proto` senden.

### `FAMILY_AI_TRUSTED_PROXIES` (wichtig)

Hinter einem Proxy sieht der Server nur dessen Adresse. Die Client-Adresse aus `X-Forwarded-For` glaubt er **nur**, wenn der direkte Absender in `FAMILY_AI_TRUSTED_PROXIES` steht (Adressen oder Netze, kommagetrennt, z. B. `172.29.77.0/24`). Die Adresse braucht „Verwaltung nur aus Heimnetz/VPN“ und die Anmelde-Sperre.

- Der Zusatz setzt es für sein festes Netz bereits. Bei einem eigenen Proxy **dessen** Adresse oder Netz eintragen, so eng wie möglich.
- **Ohne** die Einstellung gilt ein Proxy in einem anderen Container selbst als Client: Dann sieht alles nach „Heimnetz“ aus und *Verwaltung nur aus Heimnetz/VPN* schützt nichts. Immer setzen, wenn ein Proxy davor sitzt, und Port 8097 nur zum Proxy hin veröffentlichen, nicht ins Internet.

## Einstellungen (Umgebungsvariablen)

| Variable | Standard | Bedeutung |
|---|---|---|
| `FAMILY_AI_MASTER_KEY_FILE` / `FAMILY_AI_MASTER_KEY` | – (Pflicht) | Master-Schlüssel (Datei, z. B. Docker Secret, oder Wert) |
| `FAMILY_AI_TRUSTED_PROXIES` | – | Reverse Proxys, die `X-Forwarded-For` setzen dürfen |
| `FAMILY_AI_PORT` | `8097` | Port im Container |
| `FAMILY_AI_HOST` | `0.0.0.0` | Adresse, auf der gelauscht wird |
| `FAMILY_AI_DATA` | `/data` | Datenordner (das Volume) |
| `TZ` | `UTC` | Zeitzone (Datum, das die KI sieht, Mail-Zeitstempel), z. B. `Europe/Berlin` |

Alles andere (Personen, Schlüssel, Modelle, Funktionen, Mail) stellst du wie am Mac in der Web-App unter *Verwaltung* ein.

## Sicherungen

Der Container führt keine zeitgesteuerten Sicherungen aus, das Volume gehört dir. Beispiel (Datenbank, Dateien, verschlüsselte Schlüssel):

```bash
docker run --rm -v family-ai-server_family-ai-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/family-ai-$(date +%F).tgz -C /data .
```

Am besten bei gestopptem Container (`docker compose stop`) ausführen, sonst ist es eine Live-Kopie der SQLite-Datenbank. `keys.enc` in der Sicherung ist ohne Master-Schlüssel wertlos – beides **getrennt** aufbewahren.

## Aktualisieren

```bash
docker compose pull && docker compose up -d
```

Oder das Image selbst bauen: `docker compose build` (dauert ein paar Minuten, braucht etwa 2 GB Platz).

## Unterschiede zur Mac-App

| | macOS-App | Docker |
|---|---|---|
| OpenRouter-Schlüssel | macOS-Schlüsselbund | verschlüsselte Datei + Master-Schlüssel |
| Sicherungen | eingebaut (täglich) | liegt bei dir (siehe oben) |
| Dokumente | PDF, Word, RTF, ODT, Text | PDF, **DOCX**, **ODT**, Text (kein RTF/DOC/Pages) |
| Runner-Download für macOS | universal | nur Apple Silicon |
| Sprachaufnahmen aus Safari, iPhone-Fotos (HEIC) | System-Frameworks | `ffmpeg` und `libheif` im Image |
| Erstes Konto | in der App | Einmal-Code aus dem Protokoll |

## Datenschutz

Alles auf der Seite [Datenschutz & Sicherheit](privacy.de.md) gilt unverändert: Es gehen dieselben Anfragen an OpenRouter (nur der Vorname, „keine Speicherung“ in jeder Anfrage). Die OpenRouter-Guardrail richtest du wie dort beschrieben ein. Die lokalen Daten liegen auf deinem Server im Volume – der Schutz hängt an diesem Rechner, seinen Sicherungen und deinem Netzwerk.

## Fehlersuche

- *„kein Master-Schlüssel“* im Protokoll: `master.key` fehlt oder ist leer, oder das Secret ist nicht eingebunden. Wie oben anlegen.
- *„keys.enc lässt sich … nicht entschlüsseln“*: Der Master-Schlüssel weicht vom bisherigen ab. Mit dem richtigen starten (siehe oben).
- `docker compose logs family-ai` zeigt den Einrichtungscode. Er verschwindet von der Seite, sobald das erste Konto angelegt ist.
- *Verwaltung „nur aus Heimnetz“ sperrt dich aus*: `FAMILY_AI_TRUSTED_PROXIES` prüfen und ob der Proxy `X-Forwarded-For` sendet.
