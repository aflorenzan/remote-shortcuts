<div align="center">

# remote-shortcuts

**Drive Siri Shortcuts, Calendar, Reminders and Apple Notes on your Mac over HTTP.**

[![CI](https://github.com/aflorenzan/remote-shortcuts/actions/workflows/ci.yml/badge.svg)](https://github.com/aflorenzan/remote-shortcuts/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/aflorenzan/remote-shortcuts?sort=semver)](https://github.com/aflorenzan/remote-shortcuts/releases)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#requirements)
[![Dependencies: zero](https://img.shields.io/badge/dependencies-zero-brightgreen.svg)](SECURITY.md#supply-chain-posture)

</div>

A small webhook server for macOS. Point n8n — or anything that can make an HTTP
request — at it, and it drives the Apple apps on your Mac through Apple's own
frameworks.

> [!NOTE]
> **Status:** the current artefacts are a pre-release. They start and pass the
> full CI suite, including a smoke test that boots the server over TCP, but the
> EventKit, Notes and Shortcuts paths are still being verified against real data
> on a Mac. Building from source with `scripts/install.sh` is the recommended
> path meanwhile. The v1.0.0 artefacts were withdrawn — that build could not
> start at all.

```bash
curl -X POST http://127.0.0.1:8787/v1/reminders \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Call the bank","due":"2026-08-16T10:00:00","list":"Work"}'
```

```json
{
  "reminder": {
    "id": "x-apple-reminderkit://REMCDReminder/6F2A…",
    "title": "Call the bank",
    "list": "Work",
    "due": "2026-08-16T10:00:00.000Z",
    "completed": false
  }
}
```

## Contents

- [Guide](#guide)
- [Why it looks like this](#why-it-looks-like-this)
- [Requirements](#requirements)
- [Install](#install)
- [Configuration](#configuration)
- [Running it on more than one Mac](#running-it-on-more-than-one-mac)
- [API](#api)
- [Troubleshooting](#troubleshooting)
- [Development](#development)
- [Uninstall](#uninstall)
- [Contributing](#contributing)
- [Security](#security)
- [Licence](#licence)

## Guide

**New here? Start with [docs/GUIDE.md](docs/GUIDE.md)** — what it does, getting
it running, wiring it into n8n, and the handful of behaviours that will surprise
you. This README covers installation and configuration; the guide covers using
the thing.

## Why it looks like this

**Swift, zero third-party dependencies.** Everything links against frameworks
that ship signed inside macOS: `Network` for HTTP, `EventKit` for Calendar and
Reminders, `CryptoKit` for the token comparison. There is no package to be
typosquatted, no lockfile to be poisoned, no postinstall script. A CI job fails
the build if that ever stops being true — see [SECURITY.md](SECURITY.md).

**Native SDKs throughout.** Calendar and Reminders go through EventKit, so every
account the Mac already syncs — iCloud, Google, Exchange, CalDAV — works with no
extra credentials anywhere. Shortcuts run via `/usr/bin/shortcuts`, Apple's own
CLI. Notes uses its AppleScript dictionary, because Apple ships no public SDK
for Notes and that is the supported automation interface.

**Loopback by default.** It binds to `127.0.0.1` until you tell it otherwise,
and every endpoint except `/v1/health` requires a bearer token.

## Requirements

| | |
| --- | --- |
| macOS | 13 (Ventura) or newer |
| Toolchain | Xcode Command Line Tools — `xcode-select --install` |
| Apps | Shortcuts (built in); Notes only if you use the notes endpoints |

## Install

```bash
git clone https://github.com/aflorenzan/remote-shortcuts.git
cd remote-shortcuts
./scripts/install.sh
```

That one command builds from source, wraps the binary in an app bundle so macOS
can attribute privacy permissions to it, prompts for those permissions,
generates an API token, and registers a LaunchAgent so the server starts at
login. It prints your token and endpoint at the end.

Nothing is downloaded. Read `scripts/install.sh` first if you like — it is
shell with no network access except a health check against your own machine.
There is deliberately no `curl | bash` one-liner.

<details>
<summary>Installer options</summary>

```bash
./scripts/install.sh --no-preflight   # skip the permission prompts
./scripts/install.sh --no-agent       # build and configure only, no LaunchAgent
```
</details>

Check everything at any time:

```bash
remote-shortcuts doctor
```

```
Permissions
  Calendars: granted ✓
  Reminders: granted ✓

Dependencies
  /usr/bin/shortcuts: present ✓
  Apple Notes: reachable ✓ (7 folders)
```

## Configuration

`~/.config/remote-shortcuts/config.json`, mode 600 because it holds your token:

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
| `host` | Interface to bind: `127.0.0.1` (default), a LAN IP, or `0.0.0.0`. |
| `token` | Bearer token. Use `token_file` instead to read it from a separate file. |
| `modules` | Turn whole API surfaces off. A disabled module 404s before any Apple framework is touched. |
| `allowed_shortcuts` | When non-empty, only these shortcuts may run. **Set this if you expose the server beyond loopback.** |
| `allowed_origins` | IPs/CIDRs allowed to connect when not loopback-only, e.g. `["192.168.1.0/24"]`. |
| `read_only` | Disables every POST/PATCH/DELETE. |
| `rate_limit_per_minute` | Per source address. `0` disables limiting. |

Every key has an environment-variable override (`REMOTE_SHORTCUTS_HOST`,
`REMOTE_SHORTCUTS_PORT`, `REMOTE_SHORTCUTS_DISABLE`, …), so one machine can run
a different profile without editing the file. Run `remote-shortcuts help` for
the full list.

After changing the config, restart the service:

```bash
launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server
```

## Running it on more than one Mac

Nothing is hard-coded to a hostname or user. Clone the repo on the new Mac and
run the installer; to put several Macs behind one n8n instance, give each its
own credential in n8n and point at each host — the API is identical.

To reach it from an n8n instance that is not on this Mac, pick one:

| Approach | How |
| --- | --- |
| **Tailscale / WireGuard** (recommended) | Keep `host` at `127.0.0.1` and let the VPN carry it, or bind to the Tailscale IP |
| **LAN** | Set `host` to the Mac's LAN IP and fill in `allowed_origins` |
| **Cloudflare Tunnel** | Point the tunnel at `127.0.0.1:8787` |

> [!WARNING]
> Do not port-forward this to the public internet. A shortcut can do anything
> you can do on the machine.

## API

How to use it: **[docs/GUIDE.md](docs/GUIDE.md)**. Full endpoint reference:
**[docs/API.md](docs/API.md)**. n8n recipes: **[docs/n8n.md](docs/n8n.md)**.

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

Errors are always JSON, with a stable `code` and a hint about what to do:

```json
{
  "error": {
    "code": "permission_denied",
    "message": "macOS has not granted access to Calendars. Access was previously denied.",
    "hint": "Open System Settings → Privacy & Security → Calendars, enable 'Remote Shortcuts', then run: remote-shortcuts doctor"
  }
}
```

## Troubleshooting

<details>
<summary><b>macOS asks for permissions again after I rebuild</b></summary>

Expected, and unavoidable with the default install. The installer signs the
bundle ad-hoc, and without a Team ID, TCC keys the grant to the bundle's code
hash — which changes on every build. macOS therefore sees a new app and forgets
the Calendars and Reminders grants. (Automation, for Notes, usually survives.)

After a rebuild, with the service running:

```bash
launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server   # load the new build
remote-shortcuts preflight   # asks the service to prompt; approve them
remote-shortcuts doctor      # confirm what the service holds
```

`preflight` has to reach the running service, because the service is what needs
the grant — see [`POST /v1/system/permissions/request`](docs/API.md#post-v1systempermissionsrequest).
Until the service holds them, those endpoints return `403`.

**For a machine that runs this as a service**, sign with a Developer ID
certificate instead. TCC then keys the grant to the stable Team ID and the
permissions persist across rebuilds:

```bash
codesign --force --sign "Developer ID Application: Your Name (TEAMID)" \
  --identifier com.remoteshortcuts.server ~/Applications/RemoteShortcuts.app
```

That needs a paid Apple Developer account, which is why it is not the default.
</details>

<details>
<summary><b>403 <code>permission_denied</code> on calendar or reminder calls</b></summary>

Start the service if it is not running, then run `remote-shortcuts preflight`
from a terminal, with somebody at the Mac to approve the dialogs. `preflight`
asks the *service* to raise them; a prompt raised any other way from a terminal
is granted to the terminal instead, which is why `doctor` can look healthy while
the service still has nothing.

If a permission was previously denied, macOS will not re-prompt — enable it
manually in System Settings → Privacy & Security.
</details>

<details>
<summary><b>Notes endpoints return <code>permission_denied</code> for "Automation"</b></summary>

Notes is driven through Apple Events, which is a separate grant from Calendars
and Reminders. Look under System Settings → Privacy & Security → Automation for
"Remote Shortcuts", and allow it to control Notes.
</details>

<details>
<summary><b>The server does not answer at all</b></summary>

```bash
launchctl print gui/$(id -u)/com.remoteshortcuts.server | head -20
tail -50 ~/Library/Logs/remote-shortcuts/server.error.log
```

A sleeping Mac does not answer either. For a machine serving scheduled
automations, keep it awake or schedule for times it is up.
</details>

<details>
<summary><b>429 <code>too_many_requests</code> from a loop in n8n</b></summary>

The default is 120 requests/minute per source address. Batch the work, add a
Wait node, or raise `rate_limit_per_minute`.
</details>

<details>
<summary><b>A shortcut times out</b></summary>

Pass `"timeout": 300` in the request body, or raise
`shortcut_timeout_seconds`. Also raise the timeout on the n8n HTTP node itself,
which has its own.
</details>

## Development

```bash
make test        # unit tests
make audit       # verify the zero-dependency guarantee
make run         # run in the foreground
make logs        # tail the service logs
make help        # everything else
```

The layout:

```
Sources/RemoteShortcutsCore/
  HTTP/          Server, parser, router — built on Network.framework
  Security/      Token auth, rate limiting, CIDR matching
  Services/      EventKit, Notes (AppleScript), Shortcuts CLI
  Routes/        The API surface
  Config/        Configuration loading and validation
```

## Uninstall

```bash
./scripts/uninstall.sh          # keeps your config
./scripts/uninstall.sh --purge  # removes it too
```

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).
The one rule that is not negotiable: **no third-party dependencies**. CI
enforces it.

## Security

The threat model, the supply-chain controls and the hardening choices are
documented in [SECURITY.md](SECURITY.md). To report a vulnerability, use
GitHub's private vulnerability reporting rather than a public issue.

## Licence

MIT — see [LICENSE](LICENSE).
