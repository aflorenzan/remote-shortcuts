# remote-shortcuts

A tiny webhook server for macOS that lets n8n — or any tool that can make an
HTTP request — drive **Siri Shortcuts**, **Calendar**, **Reminders** and
**Apple Notes** on your Mac.

```bash
curl -X POST http://127.0.0.1:8787/v1/reminders \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Call the bank","due":"2026-08-16T10:00:00","list":"Work"}'
```

## Why it looks like this

- **Swift, zero third-party dependencies.** Everything links against
  frameworks that ship signed inside macOS: `Network` for HTTP, `EventKit` for
  Calendar and Reminders, `CryptoKit` for the token comparison. There is no
  package to be typosquatted, no lockfile to be poisoned, no postinstall
  script. See [SECURITY.md](SECURITY.md).
- **Native SDKs.** Calendar and Reminders go through EventKit, so every
  account the Mac already syncs (iCloud, Google, Exchange, CalDAV) works with
  no extra credentials. Shortcuts run via `/usr/bin/shortcuts`, Apple's own
  CLI. Notes uses its AppleScript dictionary — Apple ships no public SDK for
  Notes, and this is the supported automation interface.
- **Loopback by default.** It binds to `127.0.0.1` until you tell it
  otherwise, and every endpoint except `/v1/health` needs a bearer token.

## Requirements

- macOS 13 (Ventura) or newer
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/aflorenzan/remote-shortcuts.git
cd remote-shortcuts
./scripts/install.sh
```

The installer builds from source, wraps the binary in an app bundle so macOS
can attribute privacy permissions to it, prompts for those permissions,
generates an API token, and registers a LaunchAgent so the server starts at
login. It prints your token and endpoint at the end.

Nothing is downloaded — read `scripts/install.sh` before running it if you
like; it is 200 lines of shell with no network access except a health check
against your own machine.

Check everything at any time:

```bash
remote-shortcuts doctor
```

## Configuration

`~/.config/remote-shortcuts/config.json` (mode 600 — it holds your token):

```json
{
  "host": "127.0.0.1",
  "port": 8787,
  "token": "generated-at-install",
  "modules": { "shortcuts": true, "calendars": true, "reminders": true, "notes": true },
  "allowed_shortcuts": [],
  "allowed_origins": [],
  "read_only": false,
  "rate_limit_per_minute": 120,
  "shortcut_timeout_seconds": 120,
  "log_level": "info"
}
```

| Key | Meaning |
| --- | --- |
| `host` | Interface to bind. `127.0.0.1` (default), a LAN IP, or `0.0.0.0`. |
| `token` | Bearer token. Use `token_file` instead to read it from a separate file. |
| `modules` | Turn whole API surfaces off. A disabled module 404s before any Apple framework is touched. |
| `allowed_shortcuts` | When non-empty, only these shortcuts may run. **Set this if you expose the server beyond loopback.** |
| `allowed_origins` | IPs/CIDRs allowed to connect when not loopback-only, e.g. `["192.168.1.0/24"]`. |
| `read_only` | Disables every POST/PATCH/DELETE. |

Every key has an environment-variable override (`REMOTE_SHORTCUTS_HOST`,
`REMOTE_SHORTCUTS_PORT`, `REMOTE_SHORTCUTS_DISABLE`, …) so one machine can run
a different profile without editing the file — run `remote-shortcuts help` for
the full list.

After changing the config:

```bash
launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server
```

## Not tied to one machine

Nothing is hard-coded to a hostname or user. To move it: clone the repo on the
new Mac and run the installer. To run several Macs behind one n8n instance,
give each its own credential in n8n and point at each host — the API is
identical.

To reach it from an n8n instance that is not on this Mac, pick one:

1. **Tailscale / WireGuard** (recommended) — keep `host` at `127.0.0.1` and let
   the VPN carry the traffic, or bind to the Tailscale IP.
2. **LAN** — set `host` to the Mac's LAN IP and fill in `allowed_origins`.
3. **Cloudflare Tunnel** — point the tunnel at `127.0.0.1:8787`.

Do not port-forward this to the public internet. A shortcut can do anything
you can do.

## API

Full reference: [docs/API.md](docs/API.md). n8n recipes:
[docs/n8n.md](docs/n8n.md).

```
GET    /v1                          What this server exposes
GET    /v1/health                   Liveness (no auth)
GET    /v1/system/permissions       Which macOS permissions are granted

GET    /v1/shortcuts                List shortcuts
POST   /v1/shortcuts/run            Run one, with input, and get its output

GET    /v1/calendars                List calendars across all accounts
GET    /v1/calendars/events         Query events by range, calendar, text
POST   /v1/calendars/events         Create an event
PATCH  /v1/calendars/events/:id     Update an event
DELETE /v1/calendars/events/:id     Delete an event

GET    /v1/reminders/lists          List reminder lists
GET    /v1/reminders                Query reminders
POST   /v1/reminders                Create a reminder
PATCH  /v1/reminders/:id            Update a reminder
POST   /v1/reminders/:id/complete   Mark done
DELETE /v1/reminders/:id            Delete a reminder

GET    /v1/notes/folders            List Notes folders
GET    /v1/notes                    List/search notes
GET    /v1/notes/:id                Read one note, with body
POST   /v1/notes                    Create a note
PATCH  /v1/notes/:id                Replace, append or prepend content
DELETE /v1/notes/:id                Move to Recently Deleted
```

Errors are always JSON and say what to do about it:

```json
{
  "error": {
    "code": "permission_denied",
    "message": "macOS has not granted access to Calendars. Access was previously denied.",
    "hint": "Open System Settings → Privacy & Security → Calendars, enable 'Remote Shortcuts', then run: remote-shortcuts doctor"
  }
}
```

## Development

```bash
make test        # unit tests
make audit       # verify the zero-dependency guarantee
make run         # run in the foreground
make logs        # tail the service logs
```

## Uninstall

```bash
./scripts/uninstall.sh          # keeps your config
./scripts/uninstall.sh --purge  # removes it too
```

## Licence

MIT — see [LICENSE](LICENSE).
