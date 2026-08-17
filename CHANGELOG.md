# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Fixes from the first runtime verification against real data on macOS. Every
item below was observed, not inferred — the code compiled and passed its unit
tests throughout.

### Added

- **Recurring occurrences are individually addressable.** Each occurrence now
  comes back with a composite `id` (`<series_id>/RID=<seconds>`) plus a
  `series_id`. Sending the composite id back pins `PATCH` and `DELETE` to that
  occurrence, so `span=future_events` finally means "from this occurrence
  onwards" rather than rewriting the series from its start.

  The seconds are on Apple's reference date, which is what EventKit itself emits
  for a detached occurrence, so those ids round-trip unchanged.

  A bare identifier is still accepted and keeps its previous meaning — the
  series master, anchored at the series' original start — so nothing written
  against the old shape breaks. See
  [docs/proposals/occurrence-ids.md](docs/proposals/occurrence-ids.md) for the
  decision and the options considered.

### Changed

- **Unknown request fields are rejected with a 400** instead of being ignored.
  Sending `due_date` instead of `due` created a reminder with `due: null` and
  returned `201`. The error names the offending fields, suggests the intended
  one, and lists what is accepted. Fields that exist but are not writable
  (`attendees`, `organizer`, `recurrence`) explain why.
  **This is a behaviour change** for any client that was sending extra fields.
- `docs/API.md` now documents the composite occurrence ids and `span` semantics,
  and states measured Notes write latency (~1.5–2 s) instead of the "few hundred
  milliseconds" it previously claimed.

### Fixed

- **Notes: `GET /v1/notes` returned 404 for every folder that had notes in it.**
  Folders reached through `folders whose name is X` are evaluated references
  rather than object specifiers, so bulk property access (`id of candidates`)
  failed with -1728. Empty folders skipped the bulk fetch and so appeared to
  work. Folders are now addressed by index, and the bulk fetch falls back to
  per-note access rather than failing outright.
- **Notes: ids containing slashes were unroutable.** `GET`, `PATCH` and
  `DELETE` on `/v1/notes/:id` answered "no route" for every id this API emits
  (`x-coredata://…/ICNote/p123`). Paths are now split before percent-decoding,
  each segment decoded separately, and a trailing `:id` captures the remainder.
  This also fixes detached calendar occurrences (`<id>/RID=<n>`).
- **Notes: a scripting failure was reported as 404.** A bare -1728 now returns
  502 with the real AppleScript message; only our own sentinel means "not
  found". Conflating them is what disguised the bug above.
- **Notes: `container` was unreadable**, so created notes reported
  `folder: ""` and 33 of 41 folders reported `account: ""`.
- **Calendars: `DELETE …?span=this_event` could report success without
  deleting anything.** When the occurrence had already been detached, the id
  resolved to the series master and removal silently did nothing. The API now
  verifies the occurrence exists before removing it and that it is gone
  afterwards, returning 404 rather than a false `{"deleted": true}`.
- **Calendars: `PATCH …span=this_event` could resurrect a deleted
  occurrence.** Same root cause; now returns 404 instead of recreating it.
- **Permissions: `/v1/system/permissions` reported `not_determined` for
  permissions that were granted**, until some other call exercised them. It now
  reports effective access, probed without prompting.

## [1.0.0] — 2026-08-15

First release.

### Added

**Shortcuts**
- `GET /v1/shortcuts` lists the shortcuts on the machine and whether the
  allow-list permits each one.
- `POST /v1/shortcuts/run` runs a shortcut with optional input and returns its
  output, parsing it as `output_json` when the shortcut emits JSON.
- Optional `allowed_shortcuts` allow-list, per-request and global timeouts.

**Calendars** (EventKit — covers iCloud, Google, Exchange, CalDAV and local
accounts)
- List calendars; query events by date range, calendar and free text.
- Create, update and delete events, including all-day events, alarms,
  availability, time zones and recurring-series spans.

**Reminders** (EventKit)
- List reminder lists; query by list, completion state, due window and text.
- Create, update, complete and delete reminders, with priority, notes, URLs and
  due dates that behave the way the Reminders app does.

**Notes** (AppleScript — Apple ships no public SDK for Notes)
- List folders; list and search notes; read a note's HTML and plain text.
- Create notes from plain text or HTML, append/prepend/replace content, delete.

**Operations**
- `remote-shortcuts` CLI: `serve`, `init`, `token show|rotate`, `preflight`,
  `doctor`, `config`, `endpoint`, `version`.
- `scripts/install.sh` builds from source, assembles a signed app bundle so
  macOS can attribute privacy permissions, requests those permissions, and
  registers a LaunchAgent that starts the server at login.
- Configuration via `~/.config/remote-shortcuts/config.json` with an
  environment-variable override for every key.

### Security

- Zero third-party dependencies, enforced in CI by
  `scripts/audit-dependencies.sh`, which also rejects imports outside the macOS
  SDK allow-list and any download piped into a shell.
- Binds to `127.0.0.1` by default; source-address allow-list (IP/CIDR) and
  `Host` header validation against DNS rebinding.
- Bearer token of 32 CSPRNG bytes, compared in constant time via SHA-256
  digests. Tokens are never accepted from the query string.
- Refuses to start if the config or token file is group- or world-readable.
- Rate limiting per source address; caps on body size, header size, header
  count, concurrent connections and requests per connection.
- Strict HTTP parsing: rejects `Transfer-Encoding`, duplicate `Content-Length`,
  obsolete line folding and path traversal.
- No shell anywhere; AppleScript receives user data only through `argv`.

[Unreleased]: https://github.com/aflorenzan/remote-shortcuts/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/aflorenzan/remote-shortcuts/releases/tag/v1.0.0
