# Endpoint reference

Condensed from `docs/API.md` in the repository, which is the authority if the
two ever disagree. `GET /v1` on a running server lists what that install
actually exposes — modules can be turned off in the config.

All calls need `Authorization: Bearer $TOKEN` except `GET /v1/health`.

## Contents

- [Conventions](#conventions)
- [Meta](#meta)
- [Shortcuts](#shortcuts)
- [Calendars](#calendars)
- [Recurring series](#recurring-series)
- [Reminders](#reminders)
- [Notes](#notes)

## Conventions

**Dates** accept three forms:

| Input | Read as |
| --- | --- |
| `2026-09-03T10:00:00Z` | That exact instant |
| `2026-09-03T10:00:00` | Local time on the Mac |
| `2026-09-03` | That calendar day, local |

Output is always `2026-09-03T10:00:00.000Z`.

**Errors** are uniform:

```json
{ "error": { "code": "not_found", "message": "…", "hint": "…" } }
```

| Status | Code | Meaning |
| --- | --- | --- |
| 400 | `bad_request` | Malformed, missing, wrong-typed, or **unknown** field or query parameter |
| 401 | `unauthorized` | Missing or wrong token |
| 403 | `forbidden` | Read-only mode, blocked shortcut, or refused source address |
| 403 | `permission_denied` | macOS has not granted the service the permission |
| 404 | `not_found` | No such route, event, reminder or note |
| 413 | `payload_too_large` | Reply over the buffer |
| 422 | `unprocessable_entity` | Valid JSON the system cannot act on |
| 429 | `too_many_requests` | Rate limited; see `Retry-After` |
| 502 | `upstream_failure` | Calendar, Notes or Shortcuts refused |
| 504 | `timeout` | Ran too long |

Unknown fields and query parameters are rejected with a `400` that names the
offender and suggests the intended one. `GET /v1` and `GET /v1/health` are
exempt from the query check so health probes can append cache-busters.

## Meta

| Route | Notes |
| --- | --- |
| `GET /v1` | Every route this install exposes |
| `GET /v1/health` | No auth. Point monitors here |
| `GET /v1/system/permissions` | What the service holds |
| `POST /v1/system/permissions/request` | Ask the service to raise the macOS prompts. The only way to grant the service anything; somebody must be at the screen |
| `GET /v1/diagnostics/event-resolution/:id` | Read-only. What `event(withIdentifier:)` returns for an id and which resolver branch fires |

Permission values: `granted`, `write_only`, `denied`, `not_determined`,
`restricted`. `write_only` means macOS allows creating but not reading — reads
are refused with a `403` rather than returning an empty list, because an empty
list is indistinguishable from an empty calendar.

## Shortcuts

| Route | Notes |
| --- | --- |
| `GET /v1/shortcuts` | List installed shortcuts |
| `POST /v1/shortcuts/run` | Run one |
| `POST /v1/shortcuts/{name}/run` | Same, name in the path (percent-encode spaces) |

`POST /v1/shortcuts/run`:

| Field | Type | Notes |
| --- | --- | --- |
| `name` | string, required | Exact shortcut name |
| `input` | any | A string passes through; objects and arrays are re-encoded as JSON text |
| `timeout` | number | Seconds, 1–600. Defaults to `shortcut_timeout_seconds` |

Response carries `output`, `duration_seconds`, and `output_json` when the
output parses as JSON. A missing shortcut is a `404`.

`allowed_shortcuts` in the config restricts which may run; empty means all.

## Calendars

Covers every account the Mac syncs — iCloud, Google, Exchange, CalDAV, local.

| Route | Notes |
| --- | --- |
| `GET /v1/calendars` | All calendars across accounts |
| `GET /v1/calendars/events` | Query by range, calendar, text |
| `POST /v1/calendars/events` | Create |
| `GET /v1/calendars/events/:id` | One event |
| `PATCH /v1/calendars/events/:id` | Edit — `span` in the **body** |
| `DELETE /v1/calendars/events/:id` | Delete — `span` in the **query** |

`GET /v1/calendars/events`:

| Query | Default | Notes |
| --- | --- | --- |
| `start` | today 00:00 | |
| `end` | `start` + 7 days | Range must be ≤ 4 years, an EventKit limit |
| `calendars` | all | Comma-separated names or ids. **Plural** |
| `q` | — | Case-insensitive over title, notes, location |
| `limit` | 250 | Max 1000 |

`POST /v1/calendars/events`:

| Field | Type | Notes |
| --- | --- | --- |
| `title` | string, required | |
| `start` | date, required | |
| `end` | date | Defaults to `start` + 1 hour |
| `all_day` | bool | |
| `calendar` | string | Name or id. Defaults to the system default |
| `location`, `notes`, `url` | string | |
| `time_zone` | string | e.g. `America/Santo_Domingo` |
| `availability` | string | `busy`, `free`, `tentative`, `unavailable` |
| `alarms_minutes_before` | number[] | `[10, 60]` gives two alerts |

`attendees`, `organizer` and `recurrence` are not writable; sending them
returns a `400` explaining why.

## Recurring series

Every occurrence carries `id` shaped `<series_id>/RID=<seconds>` and a plain
`series_id`. On a one-off event `series_id` equals `id`, so a client formatting
a mixed list needs no special case.

| `span` | With a composite id | With a bare `series_id` |
| --- | --- | --- |
| `this_event` (default) | That one occurrence | The series master at its original start |
| `future_events` | That occurrence and every later one | Rewrites the series from its beginning |

`<seconds>` is on Apple's reference date (2001-01-01), matching what EventKit
emits for a detached occurrence, so those ids round-trip unchanged.

If the occurrence an id names no longer exists, the API returns `404` rather
than silently doing nothing (`DELETE`) or recreating it (`PATCH`).

A `future_events` edit that ends up touching only its own occurrence returns
`502` rather than a misleading `200`. That has never been observed on real
hardware; it is a guard, not a description.

## Reminders

| Route | Notes |
| --- | --- |
| `GET /v1/reminders/lists` | |
| `GET /v1/reminders` | `lists`, `completed`, `due_after`, `due_before`, `q`, `limit` |
| `POST /v1/reminders` | |
| `PATCH /v1/reminders/:id` | Any create field, plus `completed` |
| `POST /v1/reminders/:id/complete` | No body needed |
| `DELETE /v1/reminders/:id` | |

`POST /v1/reminders`:

| Field | Type | Notes |
| --- | --- | --- |
| `title` | string, required | |
| `notes` | string | |
| `list` | string | Name or id. Defaults to the system default list |
| `due` | date | A date **with a time** gets an alarm automatically, as the Reminders app does. A bare `yyyy-MM-dd` does not |
| `priority` | 0–9 | 0 none, 1 high, 5 medium, 9 low |
| `url` | string | |

## Notes

| Route | Notes |
| --- | --- |
| `GET /v1/notes/folders` | Folders per account |
| `GET /v1/notes` | `folder`, `q`, `limit`, `include_body` |
| `GET /v1/notes/:id` | `include_body` |
| `POST /v1/notes` | |
| `PATCH /v1/notes/:id` | At least one of `body`, `append`, `prepend` |
| `DELETE /v1/notes/:id` | Moves to Recently Deleted |

Ids contain slashes (`x-coredata://UUID/ICNote/p123`) — percent-encode them.

`POST /v1/notes`:

| Field | Type | Notes |
| --- | --- | --- |
| `title` | string, required | Becomes the first line, which is what Notes shows as the title |
| `body` | string | |
| `format` | `text` (default) or `html` | `text` is escaped and line-broken for you |
| `folder` | string | Defaults to the default folder |

`PATCH` takes `body` (replaces), `append`, or `prepend`, with `format` applying
to all three. `append` is the useful one for automation — it adds without
needing a read first.

### Body size

`include_body=true` on a listing is capped at `max_notes_with_body` (15) and
budgeted by `note_body_budget_bytes` (6 MB total). Behaviour:

- An **explicit** over-cap `limit` returns `413` in milliseconds.
- An **omitted** `limit` clamps, and the reply carries `limit_applied` and a
  `note` so a short list is not mistaken for a short library.
- A body that will not fit is replaced by `body_omitted` naming the size; the
  note itself still comes back. The reply carries `bodies_omitted` with a count.

A listing that reaches a very large note still succeeds but is slow — Notes
hands the body over before its size can be known. Scope with `folder=` to
avoid it.

### Latency, measured

| Operation | Typical |
| --- | --- |
| `GET /v1/notes/:id`, small note | ~1.0 s |
| Same with `include_body=false` | ~1.2 s — for reach, not speed |
| Same on a 17.8 MB note | ~10 s with body, ~1.3 s without |
| Creating a note | 1.5–2 s |

The floor is AppleScript itself: 0.51–0.56 s before this server does anything.

### Deleted notes

`DELETE` moves the note to Recently Deleted, so `GET /v1/notes/:id` keeps
answering for about 30 days. That is Notes' own behaviour.
