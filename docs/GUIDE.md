# Using remote-shortcuts

A practical guide: what this thing is for, how to get it running, and how to
drive it from n8n. If you want the exhaustive endpoint reference instead, that
is [docs/API.md](API.md).

## Contents

- [What it is](#what-it-is)
- [Getting it running](#getting-it-running)
- [The first call](#the-first-call)
- [Wiring it into n8n](#wiring-it-into-n8n)
- [Running a Shortcut](#running-a-shortcut)
- [Calendars](#calendars)
- [Reminders](#reminders)
- [Notes](#notes)
- [Configuration](#configuration)
- [Things that will surprise you](#things-that-will-surprise-you)
- [When something breaks](#when-something-breaks)

---

## What it is

A small HTTP server that runs on your Mac and lets another machine — n8n, a
script, anything that can make a request — do four things:

- **run a Siri Shortcut** and get its output back,
- **read and write Calendar events**,
- **read and write Reminders**,
- **read and write Notes**.

Everything goes through Apple's own frameworks and apps, so what you see through
the API is what you see in the app. There is no cloud service in the middle and
no third-party library anywhere in the build.

It is one process, listening on one port, protected by one token.

### What it is not

It is not multi-user, it has no web interface, and it does not sync anything. It
does what the Mac it runs on can already do, over HTTP.

---

## Getting it running

You need macOS 13 or newer and the Xcode Command Line Tools
(`xcode-select --install`).

**From source**, which requires trusting nothing but this repository:

```bash
git clone https://github.com/aflorenzan/remote-shortcuts.git
cd remote-shortcuts
./scripts/install.sh
```

**From a release**, if you would rather not compile:

```bash
curl -fsSLO https://github.com/aflorenzan/remote-shortcuts/releases/latest/download/SHA256SUMS
# download the tarball named in SHA256SUMS, then:
shasum -a 256 -c SHA256SUMS
tar -xzf remote-shortcuts-*-macos-universal.tar.gz -C remote-shortcuts
cd remote-shortcuts && ./install.sh
```

The installer builds the binary, wraps it in an app bundle, generates a token,
registers a LaunchAgent so it starts at login, and then asks macOS for the
permissions it needs.

### The permission prompts matter

Dialogs will appear asking to allow Calendars, Reminders and controlling Notes.
**Somebody has to be at the Mac to accept them.** They are granted to the
*service*, not to your terminal — which is why the installer asks the running
service to raise them rather than raising them itself.

If you miss them, nothing is lost:

```bash
remote-shortcuts preflight   # ask again, with someone watching
remote-shortcuts doctor      # see what the service actually holds
```

`doctor` prints two sections. The one headed **"the service"** is the one that
matters; the other is only there to make the difference visible.

---

## The first call

```bash
TOKEN=$(remote-shortcuts token show)
BASE=$(remote-shortcuts endpoint)

curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1" | python3 -m json.tool
```

That lists every endpoint the server is currently exposing. If it answers, you
are done installing.

`GET /v1/health` needs no token, which makes it the right thing to point a
monitor at.

---

## Wiring it into n8n

### 1. Let n8n reach the Mac

By default the server listens on `127.0.0.1`, which only the Mac itself can
reach. To accept calls from n8n, bind to the LAN address and say which addresses
may call:

```json
{
  "host": "192.168.1.129",
  "port": 8787,
  "allowed_origins": ["192.168.50.204/32"]
}
```

in `~/.config/remote-shortcuts/config.json`, then:

```bash
launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server
```

`allowed_origins` is a list of CIDRs. The Mac's own address is always allowed,
whatever the list says, so `doctor` and `preflight` keep working.

> **Do not put this on the open internet.** The token is the only thing between
> a caller and your calendar. A LAN, a VPN, or a Tailscale-style overlay is the
> intended shape.

### 2. Credentials

In n8n, create a **Header Auth** credential:

- **Name**: `Authorization`
- **Value**: `Bearer <the token from remote-shortcuts token show>`

Attach it to an **HTTP Request** node. That is the whole integration — there is
no n8n community node to install, and no OAuth dance.

### 3. A first workflow

An HTTP Request node with:

- **Method**: `POST`
- **URL**: `http://192.168.1.129:8787/v1/reminders`
- **Authentication**: the Header Auth credential above
- **Send Body**: on, JSON:

```json
{ "title": "Call the supplier", "due": "2026-09-01T15:00:00", "list": "Work" }
```

The response comes back as JSON with the created reminder, including its `id`,
which you can keep for a later `PATCH` or `DELETE`.

### 4. Errors, so your workflow can branch on them

Every error is the same shape:

```json
{ "error": { "code": "not_found", "message": "…", "hint": "…" } }
```

The status codes worth handling in n8n: **400** you sent something wrong,
**403** a macOS permission is missing, **404** the thing is gone, **429** you
are calling too fast (there is a `Retry-After`), **502** the Apple app refused,
**504** it took too long.

---

## Running a Shortcut

```bash
curl -s -X POST "$BASE/v1/shortcuts/run" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"Daily Briefing","input":{"city":"Santo Domingo"}}'
```

```json
{
  "shortcut": "Daily Briefing",
  "output": "{\"temp\":31}",
  "output_json": { "temp": 31 },
  "duration_seconds": 1.842
}
```

**Make your shortcut end in a Text action containing JSON.** When the output
parses, it comes back as `output_json` too, and n8n can read fields from it
directly instead of parsing a string.

`GET /v1/shortcuts` lists what is installed. If you want to allow only some of
them, set `allowed_shortcuts` in the config — anything not listed is refused.

---

## Calendars

```bash
# What is on this week
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/v1/calendars/events?start=2026-09-01&end=2026-09-08"

# Book something
curl -s -X POST "$BASE/v1/calendars/events" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"title":"Dentist","start":"2026-09-03T10:00:00","end":"2026-09-03T11:00:00","calendar":"Personal"}'
```

Dates accept three forms: `2026-09-03T10:00:00Z` (that instant),
`2026-09-03T10:00:00` (local time on the Mac), and `2026-09-03` (that whole
day, local).

### Recurring events

Every occurrence comes back with its own `id`, which looks like
`<series_id>/RID=<seconds>`. Send that id back and you are editing **that
occurrence**. Send the plain `series_id` and you are editing the series.

To change one occurrence and every later one, put `span` **in the body**:

```bash
curl -s -X PATCH "$BASE/v1/calendars/events/$ID" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"title":"Moved","span":"future_events"}'
```

For `DELETE`, which has no body, `span` goes in the query string:

```bash
curl -s -X DELETE "$BASE/v1/calendars/events/$ID?span=future_events" \
  -H "Authorization: Bearer $TOKEN"
```

Getting that backwards used to be accepted silently. It is now a `400`.

---

## Reminders

```bash
# What is open
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1/reminders?completed=false"

# Add one
curl -s -X POST "$BASE/v1/reminders" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"title":"Renew the domain","due":"2026-09-15T09:00:00","priority":1}'

# Tick it off
curl -s -X POST "$BASE/v1/reminders/$ID/complete" -H "Authorization: Bearer $TOKEN"
```

A `due` with a time gets an alarm automatically, the same as it would in the
Reminders app. A bare `2026-09-15` does not.

---

## Notes

```bash
# List a folder
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1/notes?folder=Work&limit=20"

# Write one
curl -s -X POST "$BASE/v1/notes" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"title":"Meeting notes","body":"Point one\nPoint two","folder":"Work"}'

# Append to a running log
curl -s -X PATCH "$BASE/v1/notes/$ID" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"append":"\n- Called the supplier at 14:30","format":"text"}'
```

`append` and `prepend` are the useful ones for automation: they add to the note
without you having to read it first.

Note bodies are HTML, because that is how Notes stores them. Send `"format":
"text"` and yours gets escaped and line-broken for you.

**Bodies are expensive.** `include_body=true` on a listing is capped at 15 notes
and budgeted by size; a note too large to return comes back with `body_omitted`
instead of `body`, and the rest of the note is still there. Fetch bodies one
note at a time unless you know they are small.

---

## Configuration

`~/.config/remote-shortcuts/config.json`, mode `600`. Restart the service after
editing it.

| Key | Default | What it does |
| --- | --- | --- |
| `host` | `127.0.0.1` | Address to bind. Set to the LAN address for n8n |
| `port` | `8787` | |
| `token` | generated | The bearer token. `token_file` reads it from a file instead |
| `allowed_origins` | `[]` | CIDRs allowed to call. Empty means any address that has the token |
| `loopback_only` | derived | Refuse anything but localhost, whatever else is set |
| `read_only` | `false` | Refuse every write. Useful while you are exploring |
| `calendars`, `reminders`, `notes`, `shortcuts` | `true` | Turn a module off and its routes disappear |
| `allowed_shortcuts` | `[]` | Empty means all. Otherwise only these may run |
| `shortcut_timeout_seconds` | `120` | |
| `request_timeout_seconds` | `30` | |
| `rate_limit_per_minute` | `120` | Per source address |
| `max_notes_with_body` | `15` | Cap on `include_body` listings |
| `note_body_budget_bytes` | `6000000` | Total note body a single reply may carry |
| `log_level` | `info` | |

Useful commands:

```bash
remote-shortcuts doctor         # configuration, permissions, dependencies
remote-shortcuts token show     # print the token
remote-shortcuts token rotate   # generate a new one
remote-shortcuts endpoint       # print the base URL
launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server   # restart
tail -f ~/Library/Logs/remote-shortcuts/server.log
```

---

## Things that will surprise you

**It is not fast, and it cannot be.** Every Notes and Calendar operation goes
through Apple's scripting layer, which costs a fixed half-second or so before
this server does anything. Reading one note takes about a second. Creating one
takes one to two. Budget for that in your workflows; do not poll in a tight
loop.

**A rebuild can cost you the permissions.** The app bundle is signed ad-hoc, so
macOS may decide a rebuilt binary is a new app and forget its grants. It does
not always. After reinstalling, run `remote-shortcuts doctor`; if they are gone,
`remote-shortcuts preflight` gets them back. Signing with a Developer ID
certificate makes them persist — see the README.

**Deleted notes keep answering.** Deleting a note moves it to *Recently
Deleted*, so its id still resolves for about thirty days. That is Notes' own
behaviour, not this server's.

**Unknown fields and parameters are refused.** Sending `due_date` instead of
`due`, or `?calendar=` instead of `?calendars=`, gets a `400` naming the mistake
rather than a `200` that quietly ignored it. This is deliberate: the earlier
behaviour created reminders with no due date and returned every event on the
Mac while looking like a filtered answer.

**Write-only calendar access is refused for reads.** If macOS grants only
"add events", reads would return an empty list rather than failing — which looks
exactly like an empty calendar. The API returns `403` instead and says why.

---

## When something breaks

Start here:

```bash
remote-shortcuts doctor
```

It checks the configuration, asks the *service* what permissions it holds, and
tells you what to do about anything missing.

| Symptom | Usually |
| --- | --- |
| `403 permission_denied` | The service lacks a macOS permission. `remote-shortcuts preflight` with someone at the screen |
| `403 forbidden`, "not in allowed_origins" | The calling address is not in the list. Add it and restart |
| Connection refused | The service is not running. `launchctl kickstart -k gui/$(id -u)/com.remoteshortcuts.server` |
| `404` on a note id | Percent-encode the id — Notes ids contain slashes |
| `429` | Rate limit. Honour `Retry-After`, or raise `rate_limit_per_minute` |
| `502` from Notes | Notes.app refused the operation; the real AppleScript error is in the message |
| Everything hangs then fails | Check `~/Library/Logs/remote-shortcuts/server.error.log` |

If the logs do not explain it, the endpoint reference in [docs/API.md](API.md)
documents each route's failure modes, including the ones that exist because
they were found the hard way.
