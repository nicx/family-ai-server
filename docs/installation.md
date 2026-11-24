# Installation guide

*[Deutsche Version](installation.de.md)*

Family AI Server runs on **one computer at home** that is on all the time. Everyone else just opens a web address. Choose one variant:

| | **A) Mac** | **B) Docker** |
|---|---|---|
| For | a Mac mini / MacBook that stays on | a Linux server, NAS, Raspberry Pi 5, or any machine with Docker |
| Handling | menu-bar app, starts at login | container, `docker compose` |
| Keys | macOS keychain | encrypted file + master key |
| Backups | built in (daily) | your volume backup |
| Effort | build once (about 5 minutes) | `docker compose up -d` |

Both variants are the same server and the same web app. Steps 1 and 4 are identical.

## 1. Prepare OpenRouter (once, both variants)

All AI models come through [OpenRouter](https://openrouter.ai) – one account, many models.

1. Create an account and add credit.
2. Set the privacy rules **now**, so that it applies to every key from the start (reasons and details: [Privacy & security](privacy.md)):
   - *Settings → Privacy*: disable providers that may train on your inputs; enable ZDR (Zero Data Retention) for the provider groups you use.
   - *Default workspace → Guardrails*: ZDR for Anthropic, OpenAI, Google, xAI and "Other" on; free training off.
3. Create **one key per person** (*Keys*) with a **monthly limit**. Keep the keys at hand, you enter them in the admin area later.

## 2A. Install on a Mac

**You need:** macOS 14 or newer, the Command Line Tools (`xcode-select --install`) and Go (`brew install go`).

```bash
git clone https://github.com/nicx/family-ai-server.git
cd family-ai-server
./Scripts/make-app.sh
```

The script builds the server and the runner apps (macOS menu-bar app, Windows taskbar apps, Linux programs) and creates `dist/Family AI Server.app`. Move it to `/Applications`.

Optional: sign it with your own certificate so macOS remembers permissions across rebuilds: `CODESIGN_IDENTITY="My certificate" ./Scripts/make-app.sh`. Without one, the app is ad-hoc signed.

**First start:** right-click the app → *Open* (it is not notarized by Apple). On newer macOS versions: *System Settings → Privacy & Security → Open Anyway*. A star appears in the menu bar.

**Settings (menu bar → Settings):** *Start at login* (recommended on a server), *Daily backup at 3 a.m.* and the backup folder (a network drive works while mounted). Everything about people, keys and models is in the web app.

**Updating:** `git pull`, quit the app (menu bar → *Quit*), `./Scripts/make-app.sh`, start again. Data stays in `~/Library/Application Support/Family AI Server`.

Then continue with step 3.

## 2B. Install with Docker

**You need:** Docker with the compose plugin on a 64-bit Linux machine (amd64 or arm64).

```bash
mkdir family-ai && cd family-ai
curl -O https://raw.githubusercontent.com/nicx/family-ai-server/main/docker-compose.yml
openssl rand -base64 32 > master.key && chmod 600 master.key
docker compose up -d
docker compose logs family-ai
```

- `master.key` encrypts the stored OpenRouter keys. **Store a copy separate from your backups** (password manager).
- The log shows a **setup code** (`XXXX-XXXX`). You need it in the next step.
- The server listens on port 8097.

Updating: `docker compose pull && docker compose up -d`. HTTPS with Caddy, backups, settings and troubleshooting: [Docker guide](docker.md).

## 3. Set up the family (both variants)

1. Open `http://<computer>:8097` in a browser (Mac: menu bar → *Open Family AI Server*). In the same network use the computer's name or IP address.
2. Create the **first account** (it becomes admin). With Docker, enter the setup code. Optionally enter your own OpenRouter key.
3. *Admin → People*: add everyone (children get stricter defaults), enter each person's OpenRouter key.
4. *Admin → Family & AI*: choose the AI's name and models. The defaults already work with "no retention". Test once: a chat with web search, an image, read-aloud, dictation and a document.

## 4. Make it reachable

- **Only at home:** nothing more to do. Use the computer's address in the home network. *Admin → Family & AI → “Admin only from home network/VPN”* is a good setting.
- **From outside:** use a VPN (recommended) or put a reverse proxy with **HTTPS** in front, for example [Caddy](https://caddyserver.com):

  ```
  ai.example.org {
      reverse_proxy 127.0.0.1:8097
  }
  ```

  Enter the public address (`https://ai.example.org`) under *Admin → Family & AI*. Passkeys, the microphone (dictation) and the iPhone app need HTTPS. With Docker the proxy runs as a second container ([Docker guide](docker.md)); set `FAMILY_AI_TRUSTED_PROXIES` there.

## 5. Connect the devices

- **iPhone / iPad:** open the address in Safari → Share → *Add to Home Screen*.
- **Mac / Windows / Android:** open it in the browser, optionally install it as an app from the browser menu.
- Everyone signs in with the username and password from step 3 and can add a passkey in *Settings*.

## Backups and removal

- **Mac:** daily backups are on by default (14 copies). Restore by quitting the app and copying a backup over `~/Library/Application Support/Family AI Server/data`.
- **Docker:** back up the volume yourself, together with – but **separate from** – `master.key` ([Docker guide](docker.md)).
- **Removal:** Mac: quit the app, delete it and the data folder. Docker: `docker compose down -v` (this deletes the data).

## If something does not work

- *“Microphone not available”*: dictation needs HTTPS (or `localhost`).
- *Documents are not found*: check *Admin → Family & AI → Embedding model*; it must be ZDR-capable ([list](privacy.md)).
- *“ZDR violation”* or *“No endpoints found matching your data policy”*: the chosen model has no “no retention” endpoint, pick another one.
- Docker: see *Troubleshooting* in the [Docker guide](docker.md).
