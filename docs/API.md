# API reference

Base URL: `http://127.0.0.1:8787` (whatever `remote-shortcuts endpoint` prints).

Every endpoint except `GET /v1/health` requires:

```
Authorization: Bearer <token>
```

`X-API-Key: <token>` works too. Request bodies are JSON and need
`Content-Type: application/json`.

## Conventions

**Dates** are ISO-8601. Three forms are accepted on input:

| Input | Read as |
| --- | --- |
| `2026-08-15T09:30:00Z` | Exactly that instant |
| `2026-08-15T09:30:00` | 09:30 **local time** on this Mac |
| `2026-08-15` | That calendar day, local |

Output is always `2026-08-15T09:30:00.000Z`.

**Unknown fields and query parameters are rejected.** A request carrying
something the endpoint does not know gets a `400` naming it, rather than having
it dropped — `due_date` for `due` used to produce a reminder with no due date
and a `201`, and `?calendar=` for `?calendars=` used to return every event on
the Mac while looking like a filtered answer. The error suggests the intended
name where it can, and lists what is accepted.

**Errors** are always shaped like this:

```json
{ "error": { "code": "not_found", "message": "…", "hint": "…" } }
```

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | `bad_request` | Malformed JSON, missing, wrong-typed or **unknown** field or query parameter |
| 401 | `unauthorized` | Missing or wrong token |
| 403 | `forbidden` | Read-only mode, blocked shortcut, rejected source address |
| 403 | `permission_denied` | macOS has not granted the needed privacy permission |
| 404 | `not_found` | No such route, event, reminder or note |
| 413 | `payload_too_large` | Body over the limit |
| 422 | `unprocessable_entity` | Valid JSON the system cannot act on |
| 429 | `too_many_requests` | Rate limit; see `Retry-After` in the message |
| 502 | `upstream_failure` | Calendar, Notes or Shortcuts rejected the operation |
| 504 | `timeout` | A shortcut or Notes call ran too long |

---

## Meta

### `GET /v1`
Lists the modules enabled on this machine and every route they expose. Useful
as a self-describing entry point when wiring up a new automation.

### `GET /v1/health`
No auth. `{"status":"ok","version":"1.0.0","time":"…"}`.

### `POST /v1/system/permissions/request`

Asks the **service** to raise the macOS permission prompts for Calendars and
Reminders, and returns what happened.

This is the only way to grant the service anything. macOS attributes a privacy
grant to the *responsible process*: running `remote-shortcuts preflight` in a
terminal grants **your terminal application**, not the LaunchAgent — so it can
report success while the service still has no access at all.

Somebody has to be at the Mac to accept the prompts, which appear on its screen.

```json
{
  "requested": { "calendars": "granted", "reminders": "unanswered" },
  "permissions": { "calendars": "granted", "reminders": "not_determined" },
  "note": "A prompt went unanswered. …"
}
```

`unanswered` means the prompt was raised and nobody responded — usually nobody
was at the screen. That is different from `denied`, and has a different remedy.

### `GET /v1/system/permissions`
```json
{
  "permissions": {
    "calendars": "granted",
    "reminders": "granted",
    "shortcuts_cli": "available",
    "notes_app": "available"
  }
}
```
Calendar/Reminders values:

| Value | Meaning |
| --- | --- |
| `granted` | Full access — reads and writes work |
| `write_only` | macOS allows creating items but not reading them. **Reads are refused with `403 permission_denied`** rather than returning empty results, because a write-only grant makes `GET` succeed with nothing in it — indistinguishable from "nothing scheduled" |
| `denied` | Refused; re-enable in System Settings |
| `not_determined` | This process has not asked yet. Run `remote-shortcuts preflight` |
| `restricted` | Blocked by device policy |

A `note` field appears alongside when a value needs explaining.

---

## Shortcuts

### `GET /v1/shortcuts`
```json
{
  "shortcuts": [{ "name": "Daily Briefing", "allowed": true }],
  "count": 1,
  "allow_list_active": false
}
```
`allowed` reflects `allowed_shortcuts` in your config.

### `POST /v1/shortcuts/run`

| Field | Type | Notes |
| --- | --- | --- |
| `name` | string, required | Exact shortcut name |
| `input` | any, optional | A string is passed through; objects/arrays are re-encoded as JSON text |
| `timeout` | number, optional | Seconds, 1–600. Defaults to `shortcut_timeout_seconds` |

```bash
curl -X POST http://127.0.0.1:8787/v1/shortcuts/run \
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

`output_json` appears only when the shortcut's output parses as JSON — have
your shortcut end in a *Text* action containing JSON and you can read fields
directly in n8n.

`POST /v1/shortcuts/{name}/run` does the same with the name in the path
(percent-encode spaces), for HTTP clients that find that easier.

---

## Calendars

Covers every account the Mac syncs — iCloud, Google, Exchange, CalDAV, local.

### `GET /v1/calendars`
```json
{
  "calendars": [{
    "id": "3A1F…", "title": "Work", "type": "caldav", "source": "Google",
    "allows_modification": true, "is_subscribed": false, "color": "#1BADF8"
  }],
  "count": 1
}
```

### `GET /v1/calendars/events`

| Query | Default | Notes |
| --- | --- | --- |
| `start` | today 00:00 | |
| `end` | `start` + 7 days | Range must be ≤ 4 years (an EventKit limit) |
| `calendars` | all | Comma-separated names or ids |
| `q` | — | Case-insensitive match on title, notes, location |
| `limit` | 250 | Max 1000 |

Occurrences of a recurring series each carry their own composite `id` — see
[Recurring series](#recurring-series) below.

```bash
curl -G http://127.0.0.1:8787/v1/calendars/events \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode 'start=2026-08-15' \
  --data-urlencode 'end=2026-08-22' \
  --data-urlencode 'calendars=Work'
```

### `POST /v1/calendars/events`

| Field | Type | Notes |
| --- | --- | --- |
| `title` | string, required | |
| `start` | date, required | |
| `end` | date | Defaults to `start` + 1 hour |
| `all_day` | bool | |
| `calendar` | string | Name or id. Defaults to the system default calendar |
| `location`, `notes`, `url` | string | |
| `time_zone` | string | e.g. `America/Santo_Domingo` |
| `availability` | string | `busy`, `free`, `tentative`, `unavailable` |
| `alarms_minutes_before` | number[] | `[10, 60]` → two alerts |

Returns `201` with the created event, including its `id`.

### `PATCH /v1/calendars/events/:id`
Same fields, all optional. Only what you send changes. Add `"span":
"future_events"` to apply the edit to the rest of a recurring series
(default is `this_event`).

#### Recurring series

Each occurrence of a series comes back with its own `id`, in the composite form
`<series_id>/RID=<seconds>`, alongside a `series_id` naming the series itself:

```json
{
  "id": "330D65C2-…/RID=825598800",
  "series_id": "330D65C2-…",
  "start": "2027-03-01T13:00:00.000Z",
  "is_recurring": true
}
```

`series_id` is present on every event, recurring or not; on a one-off it equals
`id`, so a client formatting a mixed list needs no special case.

Send the composite `id` back and `span` acts from **that occurrence**:

| `span` | With a composite id | With a bare `series_id` |
| --- | --- | --- |
| `this_event` (default) | That one occurrence | The series master, anchored at the series' original start |
| `future_events` | See the caveat below | See the caveat below |

> [!WARNING]
> **`future_events` does not reliably work, and the API will tell you when it
> did not.** On a weekly series of four, editing the third occurrence with
> `span=future_events` was observed changing only that occurrence: EventKit
> detached it rather than splitting the series, leaving the fourth untouched.
> The same happened with a bare id.
>
> Rather than return `200` for an edit that did something else, the server
> checks the outcome and returns **`502 upstream_failure`** explaining that only
> one occurrence changed. The edit to that occurrence is kept — it is not rolled
> back.
>
> **To change an occurrence and everything after it**, edit each one using its
> composite `id` from `GET /v1/calendars/events`. Tedious, but it does exactly
> what you asked and nothing else.
>
> `DELETE` with `span=future_events` **does** work: it removes the occurrence
> and every later one, verified on real data. It is only `PATCH` that detaches.

Use the `id` you were given. The bare form is accepted for compatibility, and
with `future_events` it detaches its own occurrence exactly as a composite id
does — it does **not** rewrite the series from its beginning, as this document
claimed until it was measured.

`<seconds>` is on Apple's reference date (2001-01-01), matching what EventKit
itself emits when an occurrence is detached — so a detached occurrence's id
round-trips unchanged.

If the occurrence an id names no longer exists, the API returns `404` rather
than silently doing nothing (`DELETE`) or recreating it (`PATCH`).

### `DELETE /v1/calendars/events/:id`
`?span=future_events` for a series. Returns `{"deleted": true}`.

---

### `GET /v1/diagnostics/event-resolution/:id`

Read-only. Reports what `event(withIdentifier:)` returns for an id — the
occurrence, the series master, or nothing — plus which branch of the resolver a
real call would take.

It exists because that question cannot be answered from outside the service:
all three possible answers make the resolver return the same occurrence, and
only a process holding the calendar grant can look. This is that process.

```json
{
  "requested": "…:…/RID=811710000",
  "parsed": { "identifier": "…", "occurrence_start": "…", "is_composite": true },
  "lookup_verbatim": { "nil": false, "start": "…", "is_detached": false, "has_recurrence_rules": true },
  "lookup_bare": { "nil": false, "start": "…" },
  "verdict": "verbatim lookup returned something else, most likely the series master"
}
```

---

## Reminders

### `GET /v1/reminders/lists`
Same shape as `/v1/calendars`.

### `GET /v1/reminders`

| Query | Notes |
| --- | --- |
| `lists` | Comma-separated list names or ids |
| `completed` | `true`/`false`. Omit for both |
| `due_after`, `due_before` | Dates |
| `q` | Matches title and notes |
| `limit` | Default 250, max 1000 |

### `POST /v1/reminders`

| Field | Type | Notes |
| --- | --- | --- |
| `title` | string, required | |
| `notes` | string | |
| `list` | string | Name or id. Defaults to the system default list |
| `due` | date | A date with a time gets an alarm automatically, matching what the Reminders app does. A bare `yyyy-MM-dd` does not |
| `priority` | 0–9 | 0 none, 1 high, 5 medium, 9 low |
| `url` | string | |

### `PATCH /v1/reminders/:id`
Any of the above, plus `completed`.

### `POST /v1/reminders/:id/complete`
Marks it done. No body needed — the common case gets its own verb.

### `DELETE /v1/reminders/:id`

---

## Notes

Apple ships no public SDK for Notes; this module drives its AppleScript
dictionary. Two consequences worth knowing:

- Notes.app must be installed. It is launched on demand.
- Calls are serialised and slower than EventKit. Measured on an M-series Mac
  Studio: **roughly 1.5–2 seconds per write** (20 notes created in 37 s). Reads
  of a whole folder fetch properties in bulk and are considerably cheaper per
  note. Budget accordingly in n8n — a loop over many notes is slow enough to
  need a longer node timeout.

### `GET /v1/notes/folders`
```json
{ "folders": [{ "id": "x-coredata://…", "name": "Notes", "note_count": 42, "account": "iCloud" }], "count": 1 }
```

### `GET /v1/notes`

| Query | Notes |
| --- | --- |
| `folder` | Exact folder name |
| `q` | Substring of the note title |
| `limit` | Default 50, max 500 |
| `include_body` | `true` to include HTML bodies (slower, and see the size limit below) |

> **`include_body` is capped at 15 notes per call** (`max_notes_with_body`).
> Note bodies are HTML and routinely run to hundreds of kilobytes each, so a few
> dozen exceed the 8 MB the server buffers.
>
> The cap is checked **before** any work starts. It has to be: `osascript`
> returns its whole result at the end, so an over-limit request is not
> detectable until everything has already been computed — a 50-note request
> measured 17 seconds before failing.
>
> Asking for more **explicitly** returns `413` in milliseconds. Omitting `limit`
> entirely clamps to the cap instead of failing, and the response then carries
> `limit_applied` and a `note` so a short list is not mistaken for a short
> library. Page through with `limit` to read more.
>
> Raise `max_notes_with_body` in the config if your notes are short. Listing
> without `include_body` is unaffected and goes up to 500.

> [!NOTE]
> **A count is not a size.** One note of embedded images measured 17.8 MB, so
> ten notes can exceed the 8 MB buffer however small the other nine are.
> Alongside the count cap, each reply carries a **byte budget**
> (`note_body_budget_bytes`, 6 MB by default) spent inside the AppleScript,
> which can measure a body without shipping it.
>
> A note whose body will not fit comes back with **`body_omitted`** — a sentence
> naming the size — instead of `body`, and the reply carries `bodies_omitted`
> with the count. The note itself, its title, folder and dates, is still there.
> Nothing is refused because one note is large.
>
> **This buys correctness, not speed.** Notes still hands the body to the script
> before it can be measured, so a listing that reaches a very large note is
> slow even though it now succeeds — measured at ~13s on a library containing
> the 17.8 MB note. Scope with `folder=` to avoid it. There is no property that
> reports a body's size without transferring it.

### `GET /v1/notes/:id`
Returns the note including `body` (HTML) and `plain_text`.

| Query | Notes |
| --- | --- |
| `include_body` | `false` to return metadata only — title, folder, dates |

If the body is over the byte budget, `body` and `plain_text` are replaced by
`body_omitted`. The rest of the note is returned either way: a note is never
unreachable because it is large.

### `POST /v1/notes`

| Field | Type | Notes |
| --- | --- | --- |
| `title` | string, required | Becomes the note's first line, which is what Notes shows as the title |
| `body` | string | |
| `format` | `text` (default) or `html` | `text` is escaped and line-broken for you |
| `folder` | string | Defaults to the default folder |

```bash
curl -X POST http://127.0.0.1:8787/v1/notes \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"title":"Meeting notes","body":"Point one\nPoint two","folder":"Work"}'
```

### `PATCH /v1/notes/:id`
Send at least one of `body` (replaces), `append`, `prepend`. `format` applies
to all three.

Appending a line to a running log:
```json
{ "append": "\n- Called the supplier at 14:30", "format": "text" }
```

### `DELETE /v1/notes/:id`

Moves the note to *Recently Deleted*, exactly as deleting it in the app does.

**The id keeps resolving afterwards.** `GET /v1/notes/:id` on a deleted note
still returns `200` with its content, for roughly 30 days, until Notes purges
the trash. The folder's `note_count` drops immediately and the note stops
appearing in `GET /v1/notes`.

That is Notes' own semantics and this API does not hide it: a client that can
still read a deleted note can tell "deleted, recoverable" from "never existed",
and nothing here can empty the trash on your behalf.
