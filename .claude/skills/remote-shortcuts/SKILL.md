---
name: remote-shortcuts
description: Drive a Mac's Siri Shortcuts, Calendar, Reminders and Notes over the remote-shortcuts HTTP API, and diagnose its install, permissions and n8n wiring. Use this whenever the user wants to run a Shortcut remotely, read or write Apple Calendar events, Reminders or Notes through an API, build an n8n workflow that touches any Apple app, or debug remote-shortcuts itself — including 403 permission errors, allowed_origins refusals, recurring-event span behaviour, or anything under ~/.config/remote-shortcuts. Also use it when the user mentions this repository, `remote-shortcuts doctor`, or a webhook server on their Mac, even if they do not name the API explicitly.
---

# remote-shortcuts

An HTTP server on a Mac that exposes Siri Shortcuts, Calendar, Reminders and
Notes through Apple's own frameworks. This skill is about **driving it
correctly**, because several of its behaviours will mislead you if you guess.

Every trap in the "Getting it wrong quietly" section below was a real bug found
by running this against real data. Read that section before writing calls.

## Connecting

The server tells you how to reach it. Never hardcode a port or token:

```bash
BASE=$(remote-shortcuts endpoint)      # e.g. http://192.168.1.129:8787
TOKEN=$(remote-shortcuts token show)
```

If the `remote-shortcuts` CLI is not on PATH, the same values are in
`~/.config/remote-shortcuts/config.json` (mode 600 — read it, never print the
token into a shared transcript or commit it).

Every call except `GET /v1/health` needs `Authorization: Bearer $TOKEN`.

```bash
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1" | python3 -m json.tool
```

`GET /v1` lists exactly what this install exposes — modules can be switched off,
so trust it over your memory of the API.

## The four things it does

```bash
# Run a Shortcut and read its output
curl -s -X POST "$BASE/v1/shortcuts/run" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"Daily Briefing","input":{"city":"Santo Domingo"}}'

# Calendar
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/v1/calendars/events?start=2026-09-01&end=2026-09-08"

# Reminders
curl -s -X POST "$BASE/v1/reminders" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"title":"Call the supplier","due":"2026-09-01T15:00:00"}'

# Notes
curl -s -X PATCH "$BASE/v1/notes/$ENCODED_ID" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"append":"\n- 14:30 called back","format":"text"}'
```

Full endpoint list with every field: `references/endpoints.md`.

## Getting it wrong quietly

These are the failure modes that return a plausible answer rather than an
error. They cost real debugging time before the API was hardened, and knowing
them is most of this skill's value.

### `span` goes in the body for PATCH, the query for DELETE

`PATCH` reads `span` from the JSON body. `DELETE` has no body, so it reads it
from the query string. Getting this backwards used to be accepted silently and
apply `this_event` — which on a recurring series changes one occurrence, and is
indistinguishable from `future_events` being broken. Two rounds of testing were
lost to it. It is now a `400`, but write it correctly the first time:

```bash
# PATCH — body
-d '{"title":"Moved","span":"future_events"}'

# DELETE — query
"$BASE/v1/calendars/events/$ID?span=future_events"
```

### Recurring occurrences have composite ids

Each occurrence comes back with `id` shaped `<series_id>/RID=<seconds>` plus a
plain `series_id`. Send the **composite id** to act on that occurrence; send the
**bare series_id** and `future_events` rewrites the series from its beginning.
Pick deliberately — they do different things and both return 200.

### Note ids contain slashes — percent-encode them

Ids look like `x-coredata://UUID/ICNote/p123`. Unencoded, the path is
unroutable:

```bash
E=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "$ID")
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1/notes/$E"
```

### Unknown fields and query parameters are refused

`due_date` instead of `due`, or `?calendar=` instead of `?calendars=`, returns a
`400` naming the mistake — it does not silently ignore them. If you get that
400, read the suggestion in the message rather than guessing again.

### Note bodies are expensive and capped

`include_body=true` on a listing is capped at 15 notes and budgeted by total
size. A note too large to return comes back with `body_omitted` instead of
`body`, and the rest of the note is still there — so check for `body_omitted`
before assuming a note has no content. `include_body=false` on a single note is
for *reaching* an oversized note, not for speed; on small notes it is marginally
slower.

### It is not fast, and that is not a bug

Apple's scripting layer costs ~0.5s before this server does anything. Reading a
note is about a second, creating one is one to two. Never poll in a tight loop;
prefer one call that returns a list over many that return one thing each.

### A deleted note keeps answering

`DELETE` moves a note to Recently Deleted, so its id still resolves for ~30
days. Do not treat a successful `GET` as proof the note is live.

## When something returns 403

Two different causes, and the message distinguishes them:

- **`permission_denied`** — macOS has not granted the *service* that permission.
  The grant belongs to the service, not to whoever runs a command in a terminal.
  The fix is `remote-shortcuts preflight` with somebody at the Mac's screen to
  accept the dialogs, then `remote-shortcuts doctor` to confirm.
- **`forbidden`, mentioning `allowed_origins`** — the service is running and
  declined this source address. Add the address to `allowed_origins` in the
  config and restart. Do not tell the user to start the service; it answered.

`remote-shortcuts doctor` is the first move for anything permissions-shaped. It
prints two sections; the one headed **"the service"** is the one that matters.

More install and permission diagnosis: `references/troubleshooting.md`.

## Wiring it into n8n

An HTTP Request node with a **Header Auth** credential — name `Authorization`,
value `Bearer <token>`. There is no community node and no OAuth.

For a Shortcut, have it end in a Text action containing JSON: the response then
carries `output_json` alongside the raw `output`, and n8n can read fields
directly instead of parsing a string.

Errors are uniform, so a workflow can branch on the status: `400` malformed,
`403` permission or origin, `404` gone, `429` rate limited (honour
`Retry-After`), `502` the Apple app refused, `504` too slow.

## Working on the code

If the task is changing remote-shortcuts rather than calling it:

- Zero third-party dependencies, enforced by `scripts/audit-dependencies.sh`.
  Do not add a package; the constraint is the point.
- `make test` and `make audit` before proposing anything.
- The unit tests cannot exercise EventKit, Notes or TCC. Anything touching those
  is unverified until it runs on a real Mac — say so rather than implying it was
  tested.
- `docs/API.md` is the endpoint contract; `docs/GUIDE.md` is the human guide;
  `CHANGELOG.md` records what was found and, where a claim was later withdrawn,
  says so.
