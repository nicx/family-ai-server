# Docker (Linux, NAS, server)

*[Deutsche Version](docker.de.md)* · [Installation guide](installation.md)

Besides the macOS menu-bar app there is a Docker image for Linux hosts (`amd64` and `arm64`: server, NAS, Raspberry Pi 5 and similar). It is the same server and the same web app, running headless in a container.

> **Status:** The author runs Family AI Server on a Mac. The Docker variant is built and checked automatically (self-checks on Linux for every release), but it is community-supported. Please report problems as an issue.

## Quick start

```bash
mkdir family-ai && cd family-ai
curl -O https://raw.githubusercontent.com/nicx/family-ai-server/main/docker-compose.yml
openssl rand -base64 32 > master.key && chmod 600 master.key
docker compose up -d
docker compose logs family-ai
```

The log prints a **setup code** (`==> Einrichtungscode … XXXX-XXXX`). Open `http://<server>:8097`, enter the code, create the first account (it becomes admin) and your OpenRouter key. Then continue as in the main README: create people, set keys, models and features.

Until the first account exists nobody can create it without the code, so a freshly started container cannot be taken over from the network. After a restart before the setup a new code is printed.

## The master key

OpenRouter keys are stored **encrypted** (AES-256-GCM) in the data volume (`/data/keys.enc`). The key for this encryption is the **master key** (`master.key`), which is deliberately kept **outside** the data volume. A stolen volume or backup therefore does not reveal any OpenRouter key.

- Keep `master.key` safe and **separate from the data backups** (e.g. in your password manager).
- With a wrong or changed master key the server refuses to start and never overwrites `keys.enc`. Starting with the right key works again.
- If the master key is lost for good: delete `keys.enc` and enter the OpenRouter keys again (*Admin → People*). Accounts and chats are not affected. Keys can be created anew at OpenRouter.

The master key can be given as a Docker secret (`FAMILY_AI_MASTER_KEY_FILE`, as in the compose file) or directly as `FAMILY_AI_MASTER_KEY`.

## HTTPS and reverse proxy

For passkeys, the iPhone app and access from outside the home network the server should be reachable via **HTTPS**. The repository contains an overlay with [Caddy](https://caddyserver.com) (automatic certificates):

1. Enter your domain in `docker/Caddyfile` (download it with `docker-compose.proxy.yml`; the domain must point to the server, ports 80/443 reachable).
2. `docker compose -f docker-compose.yml -f docker-compose.proxy.yml up -d`
3. Enter the public address under *Admin → Family & AI* (passkeys need it).

Any other reverse proxy works the same way: it has to send `X-Forwarded-For` and `X-Forwarded-Proto`.

### `FAMILY_AI_TRUSTED_PROXIES` (important)

Behind a proxy the server only sees the proxy's address. It believes the client address from `X-Forwarded-For` **only** if the direct sender is listed in `FAMILY_AI_TRUSTED_PROXIES` (comma-separated addresses or networks such as `172.29.77.0/24`). The address is used for “Admin only from home network/VPN” and the login lockout.

- The overlay already sets it for its fixed network. For your own proxy, enter **the proxy's** address or network, as narrow as possible.
- **Without** the setting a proxy in another container counts as the client: then everything looks like “home network” and *Admin only from home network/VPN* would not protect anything. Set it whenever a proxy sits in front, and publish port 8097 only to the proxy, not to the internet.

## Settings (environment variables)

| Variable | Default | Meaning |
|---|---|---|
| `FAMILY_AI_MASTER_KEY_FILE` / `FAMILY_AI_MASTER_KEY` | – (required) | master key (file, e.g. Docker secret, or value) |
| `FAMILY_AI_TRUSTED_PROXIES` | – | reverse proxies that may set `X-Forwarded-For` |
| `FAMILY_AI_PORT` | `8097` | port in the container |
| `FAMILY_AI_HOST` | `0.0.0.0` | listen address |
| `FAMILY_AI_DATA` | `/data` | data directory (the volume) |
| `TZ` | `UTC` | time zone (the date the AI sees, mail timestamps), e.g. `Europe/Berlin` |

Everything else (people, keys, models, features, mail) is set in the web app under *Admin*, as on the Mac.

## Backups

The container does not run scheduled backups; the volume belongs to you. Example (database, files, encrypted keys):

```bash
docker run --rm -v family-ai-server_family-ai-data:/data -v "$PWD":/backup alpine \
  tar czf /backup/family-ai-$(date +%F).tgz -C /data .
```

Run it with the container stopped (`docker compose stop`) or accept a live copy of the SQLite database. `keys.enc` in the backup is useless without the master key – store both **separately**.

## Updates

```bash
docker compose pull && docker compose up -d
```

Or build the image yourself: `docker compose build` (needs a few minutes and about 2 GB of space).

## Differences from the Mac app

| | macOS app | Docker |
|---|---|---|
| OpenRouter keys | macOS keychain | encrypted file + master key |
| Backups | built in (daily) | up to you (see above) |
| Documents | PDF, Word, RTF, ODT, text | PDF, **DOCX**, **ODT**, text (no RTF/DOC/Pages) |
| Runner downloads | macOS menu-bar app, Windows apps, Linux | Windows apps and Linux; macOS only as an Apple-silicon terminal program (the macOS app needs a Mac to build) |
| Voice recordings from Safari, iPhone photos (HEIC) | system frameworks | `ffmpeg` and `libheif` in the image |
| First account | in the app | one-time code from the log |

## Privacy

Everything in [Privacy & security](privacy.md) applies unchanged: the same requests go to OpenRouter (first name only, “no retention” in every request). Set up the OpenRouter guardrail as described there. Local data lives on your server in the volume – the protection depends on that host, its backups and your network.

## Troubleshooting

- *“kein Master-Schlüssel”* in the log: `master.key` is missing or empty, or the secret is not mounted. Create it as above.
- *“keys.enc lässt sich … nicht entschlüsseln”*: the master key differs from the one used before. Start with the right one (see above).
- `docker compose logs family-ai` shows the setup code; it disappears from the page after the first account is created.
- *Admin area “only from home network” blocks you*: check `FAMILY_AI_TRUSTED_PROXIES` and that the proxy sends `X-Forwarded-For`.
