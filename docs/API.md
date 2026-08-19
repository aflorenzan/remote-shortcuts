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

**Unknown fields are rejected.** A body carrying a field the endpoint does not
know gets a `400` naming it, rather than having it dropped — a typo like
`due_date` for `due` used to produce a reminder with no due date and a `201`.
The error suggests the intended field where it can, and lists what is accepted.

**Errors** are always shaped like this:

```json
{ "error": { "code": "not_found", "message": "…", "hint": "…" } }
```

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | `bad_request` | Malformed JSON, missing, wrong-typed or **unknown** field |
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
| `future_events` | That occurrence and everything after it | The whole series |

Use the `id` you were given. The bare form is accepted for compatibility and
behaves as it always did, which is rarely what you want: an edit with
`future_events` against a bare id rewrites the series from its beginning.

`<seconds>` is on Apple's reference date (2001-01-01), matching what EventKit
itself emits when an occurrence is detached — so a detached occurrence's id
round-trips unchanged.

If the occurrence an id names no longer exists, the API returns `404` rather
than silently doing nothing (`DELETE`) or recreating it (`PATCH`).

### `DELETE /v1/calendars/events/:id`
`?span=future_events` for a series. Returns `{"deleted": true}`.

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

> **Size limit.** The server buffers at most 8 MB from Apple Notes in one call.
> Note bodies are HTML and can be large — a folder of long notes can pass 8 MB in
> around 20 of them. Over the limit you get `413 payload_too_large` promptly,
> not a hang; lower `limit`, or drop `include_body` and fetch the bodies you
> actually need one note at a time.

### `GET /v1/notes/:id`
Returns the note including `body` (HTML) and `plain_text`.

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
