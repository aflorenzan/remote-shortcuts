# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] — 2026-08-17

Fixes from runtime verification against real data on macOS. Every item below was
observed, not inferred — the code compiled and passed its unit tests throughout,
which is exactly why none of it was caught earlier.

### Fixed — the server did not start

- **The listener never came up.** `requiredLocalEndpoint` carried the port and
  `NWListener(using:on:)` was given it again; Network.framework rejects the pair
  with `EINVAL`, so `serve` failed on any host other than `0.0.0.0` — that is,
  on every default install. It surfaced as `POSIXErrorCode(rawValue: 22)` and
  exit 70. **v1.0.0 could not run.**
- **CI now boots the server.** The unit tests never opened a socket, which is
  how a server that could not start passed a green build and shipped in a
  release. `scripts/smoke-test.sh` starts the real binary on the default
  loopback host and exercises auth, routing, headers and shutdown over TCP.
- **The idle timeout discarded slow responses.** The timer shares the
  connection's queue with request handling, so it fired the instant the queue
  freed up and cancelled the socket just after the handler returned: the client
  got an empty reply while the log recorded a 504. Anything slower than
  `request_timeout_seconds` was unreachable — a large Notes folder, or any
  shortcut over 30s. The timer is now disarmed while work is in flight.

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

### Fixed — everything else

- **`GET /v1/notes` returned 404 for every folder that had notes in it.**
  Folders reached through `folders whose name is X` are evaluated references
  rather than object specifiers, so bulk property access (`id of candidates`)
  failed with -1728. Empty folders skipped the bulk fetch and so appeared to
  work.

  Addressing folders by index was necessary but **not sufficient**: what breaks
  the bulk fetch is assigning the plural to a variable, which materialises it
  into a list. `a reference to (notes of folder i of account a)` keeps it a
  specifier. Measured on a real 389-note folder: 389 ids in 0.30 s, where the
  previous form failed and timed out past 30 s.
- **Note bodies are requested separately from the other properties.** A bulk
  `body` fetch exceeds the Apple Event size limit (-1741) somewhere between 55
  and 389 notes, and that failure used to drag ids and dates onto the per-note
  path with it.
- **`account` was empty on nested folders** (35 of 43). `container` is not
  readable there, and even when it resolves it names the parent *folder*, not
  the account. Folders are now enumerated per account.
- **`POST /v1/notes` and `GET /v1/notes/:id` reported `folder: ""`.** Same
  unreadable `container`; the folder is now found by matching ids, which is
  cheap now that they come back in bulk.
- **Notes: ids containing slashes were unroutable.** `GET`, `PATCH` and
  `DELETE` on `/v1/notes/:id` answered "no route" for every id this API emits
  (`x-coredata://…/ICNote/p123`). Paths are now split before percent-decoding,
  each segment decoded separately, and a trailing `:id` captures the remainder.
  This also fixes detached calendar occurrences (`<id>/RID=<n>`).
- **Notes: a scripting failure was reported as 404.** A bare -1728 now returns
  502 with the real AppleScript message; only our own sentinel means "not
  found". Conflating them is what disguised the bug above.
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
- **Write-only calendar access was reported as `granted`, and reads lied.** With
  that grant EventKit returns a single `VIRTUAL_APP_CALENDAR` placeholder and
  empty event queries instead of failing, so a Mac with ten calendars answered
  `200 {"count": 0}` — indistinguishable from an empty schedule. `write_only` is
  now its own state, reads are refused with an explanation, writes still work,
  and the placeholder is filtered out of listings.
- **A missing shortcut returned 502 instead of 404**: the Shortcuts CLI writes
  "Couldn't find" with a typographic apostrophe, which the match missed.
- **429 responses now carry a `Retry-After` header**, not just prose.
- **Calendar colours are converted to sRGB** before being read as hex. A
  greyscale calendar has two components, so the old code read alpha as green.
- **`install.sh` no longer claims TCC grants survive a rebuild.** They do not
  with an ad-hoc signature, because TCC keys them to the code hash. The
  installer now says so when reinstalling, and the README documents Developer ID
  signing as the fix for a service machine.
- **`docs/API.md` documents that a deleted note's id keeps resolving** for ~30
  days, which is Notes' own trash semantics.

## [1.0.0] — 2026-08-15

First release. **Superseded: this version cannot start.** The listener failed
with `EINVAL` on any host other than `0.0.0.0`, which is every default install
— see the Unreleased section. Do not use the v1.0.0 artefacts.

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

[Unreleased]: https://github.com/aflorenzan/remote-shortcuts/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/aflorenzan/remote-shortcuts/releases/tag/v1.1.0
[1.0.0]: https://github.com/aflorenzan/remote-shortcuts/releases/tag/v1.0.0
