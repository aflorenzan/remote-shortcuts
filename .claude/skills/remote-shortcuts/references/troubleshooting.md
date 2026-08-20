# Install, permissions and diagnosis

Read this when the server will not start, will not answer, or answers `403`.

## Contents

- [First move](#first-move)
- [The permission model](#the-permission-model)
- [Symptoms](#symptoms)
- [Installing and reinstalling](#installing-and-reinstalling)
- [Configuration](#configuration)
- [Logs and service control](#logs-and-service-control)

## First move

```bash
remote-shortcuts doctor
```

It checks the configuration, asks the **running service** what permissions it
holds, and prints remedies. It deliberately shows two sections:

- **"Permissions — the service"** — the one that matters.
- **"Permissions — this terminal (not the service)"** — shown only so the
  difference is visible, because confusing the two wasted a lot of time.

If `doctor` says it could not reach the service, read the message: it
distinguishes *nothing answered* (start the service) from *the service refused
this address* (an `allowed_origins` problem, and the service is fine).

## The permission model

macOS attributes a privacy grant to the **responsible process**. For a command
typed into a terminal, that is the terminal application — not this service. So
a prompt raised by a CLI grants Terminal.app and leaves the LaunchAgent with
nothing, while cheerfully reporting success.

The only way to grant the service anything is to have the service raise the
prompts itself:

```bash
remote-shortcuts preflight     # asks the service to prompt; somebody must accept
remote-shortcuts doctor        # confirm what the service now holds
```

Somebody has to be physically at the Mac. Under launchd there is usually nobody
watching, which is why an unanswered prompt is reported distinctly from a
declined one — they need different remedies.

A permission request can take a few minutes if the prompts sit unanswered. If
`preflight` stops waiting, it prints what the service *actually* holds rather
than assuming failure: a prompt accepted a second later still granted the
permission.

## Symptoms

| Symptom | Cause | Fix |
| --- | --- | --- |
| `403 permission_denied` | The service lacks a macOS permission | `remote-shortcuts preflight` with someone at the screen |
| `403 forbidden`, mentions `allowed_origins` | Service is running and declined this source address | Add the address to `allowed_origins`, restart. **Do not** tell anyone to start the service |
| Connection refused | Service not running | `launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server` |
| `404` on a note id | Id not percent-encoded | Encode it; Notes ids contain slashes |
| `429` | Rate limit, per source address | Honour `Retry-After` or raise `rate_limit_per_minute` |
| `502` from Notes | Notes.app refused | The real AppleScript error is in the message |
| `504` | Operation exceeded `request_timeout_seconds` | Raise it, or narrow the request |
| Reads return empty but the calendar has events | `write_only` grant | Re-grant properly; the API returns `403` for reads under this grant |
| Permissions vanished after a rebuild | Ad-hoc signature, new code hash | `remote-shortcuts preflight`. Developer ID signing makes them persist |

The Mac's own address is always allowed through `allowed_origins`, whatever the
list says — a request whose source is the address the server bound to came from
that same host. Without that, `doctor` and `preflight` would be locked out of
their own service.

## Installing and reinstalling

```bash
./scripts/install.sh              # build, bundle, token, LaunchAgent, permissions
./scripts/install.sh --no-agent   # build and configure only
./scripts/install.sh --no-preflight
./scripts/uninstall.sh
```

The order matters and is deliberate: the LaunchAgent is registered **before**
permissions are requested, because `preflight` asks the running service to
prompt and therefore needs it to exist.

Reinstalling rebuilds the binary, which changes its code hash. With an ad-hoc
signature macOS may treat it as a new app and forget the grants — it does not
always, so check with `doctor` rather than assuming either way.

## Configuration

`~/.config/remote-shortcuts/config.json`, mode 600. Restart after editing.

| Key | Default | Notes |
| --- | --- | --- |
| `host` | `127.0.0.1` | Set to the LAN address to accept remote calls |
| `port` | `8787` | |
| `token` / `token_file` | generated | |
| `allowed_origins` | `[]` | CIDRs. Empty means any address holding the token |
| `loopback_only` | derived from `host` | Refuse anything but localhost |
| `read_only` | `false` | Refuse all writes |
| `calendars`, `reminders`, `notes`, `shortcuts` | `true` | Turn a module off and its routes disappear |
| `allowed_shortcuts` | `[]` | Empty means all |
| `shortcut_timeout_seconds` | `120` | |
| `request_timeout_seconds` | `30` | |
| `rate_limit_per_minute` | `120` | Per source address |
| `max_notes_with_body` | `15` | |
| `note_body_budget_bytes` | `6000000` | |
| `log_level` | `info` | |

Binding beyond loopback with no `allowed_origins` is allowed but warned about:
the token becomes the only control. Keep it on a LAN or a private overlay
network — never expose it to the internet.

## Logs and service control

```bash
launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server   # restart
launchctl print gui/$(id -u)/com.remoteshortcuts.server | head -20
tail -f ~/Library/Logs/remote-shortcuts/server.log
tail -50 ~/Library/Logs/remote-shortcuts/server.error.log
```

Two markers worth grepping for in the error log, both meaning a fast path fell
back to a slower one rather than failing:

- `RS_BULK_FALLBACK` — a bulk Notes property fetch failed, so it went per-note.
- `RS_PROPS_FALLBACK` — reading a note's `properties` in one round trip failed,
  so it read each field separately.

Neither is an error on its own, but either explains unexpected slowness.
