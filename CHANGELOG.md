# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] — 2026-08-20

1.1.0 has not shipped as a stable release yet, so this section is where its
fixes accumulate until it does, and each release candidate ships the whole of
it. Fixes from runtime verification against real data on macOS: every item was
observed, not inferred — the code compiled and passed its unit tests throughout,
which is exactly why none of it was caught earlier.

### Fixed — later rounds of runtime verification

- **The install's permission step gave up while the prompts were still on
  screen.** `requestAllAccess` raises one prompt per entity and waits up to 120s
  for each, so it can legitimately take 240s to answer. The client waited 180.
  When a rebuild had invalidated the TCC grants — which happens intermittently
  with an ad-hoc signature — the install printed "could not reach the service"
  and told the user to start a service that had answered a health check two
  lines earlier. Running `preflight` by hand straight afterwards worked, taking
  52s.

  The client now waits longer than the service's worst case, and a timeout is
  no longer reported as unreachability: the connection was accepted, so the
  service is running by definition. On a timeout, `preflight` and `install.sh`
  ask the service what it actually ended up holding rather than trusting the
  verdict of the call that stopped waiting — a prompt accepted a second later
  still granted the permission.

- **`include_body=false` on a small note stays slightly slower, and now says
  why.** It is not a second `osascript` — there is one per request either way —
  but two extra Apple Events: reading `properties` fetches name, dates, body,
  plaintext and the container in a single round trip, and the metadata-only
  path cannot use it, because asking for properties transfers the body it
  exists to avoid. Measured: ~1.24s against ~1.05s on a two-line note, and
  ~1.27s against ~10.3s on the 17.8 MB one. Documented as what it is — a switch
  for large notes, not a general speed-up. H17 is closed at the measured floor
  of 0.51–0.56s of AppleScript.

- **`PATCH …?span=future_events` was accepted, ignored, and answered `200`.**
  `span` is read from the body on `PATCH`; the query string was on the allowed
  list and nothing read it. So the request ran as `this_event` and changed
  exactly one occurrence of the series — which is what `future_events` failing
  would also look like.

  It was taken for exactly that. Two rounds of verification chased it, a
  working safety net was rewritten to catch it, and three false statements went
  into `docs/API.md`. `PATCH` now refuses a `span` query with a `400` saying
  where it goes; `DELETE`, which has no body, still takes it in the query.

  The lesson is the one H18 was about: a parameter accepted and not read is
  worse than one rejected, because the answer still looks like an answer. The
  allow-list is what let this single parameter through.

- **`docs/API.md` described `future_events` as broken. It is not.** Re-measured
  with `span` in the body, on a weekly series of four: editing the third
  occurrence with a composite id changes the third and fourth, leaves the first
  two alone, keeps everything recurring and shifts no dates. A bare id rewrites
  the series from its beginning — which is what this document said originally,
  before it was "corrected" on the strength of the invalid tests. The warning
  block is gone and the table says what was measured.

- **The `future_events` guard would have failed a correct edit.** Rewritten
  under the same invalid evidence, it flagged any saved occurrence that came
  back without recurrence rules. Editing the *last* occurrence of a series
  legitimately produces exactly that — nothing follows it, so nothing recurs —
  and it would have returned `502` for an edit that worked. Losing the rules now
  only counts if the later occurrences were also left behind.

  The guard stays, as a guard: no detachment has ever been observed on real
  hardware, and the comments no longer claim otherwise. Code comments that
  attributed the `isDetached` staleness to a measurement have been corrected —
  that measurement never happened.

- **`GET /v1/notes/:id?include_body=false` was slower than fetching the body.**
  The full read gets the container inside `properties`; the metadata-only path
  skipped that and fell through to a second `tell` block for the folder, with a
  whole-library scan behind it. It reads the container in the block already
  open. `include_body=false` exists so an oversized note stays reachable, not
  to be fast, and the docs now say so — along with the real floor, ~0.56s of
  AppleScript before this server does anything.

- **`event(withIdentifier:)` never returns the series master for a composite
  id.** Measured through the new diagnostic endpoint on four cases: it returns
  nil for a live occurrence and the occurrence itself for a detached one. The
  defensive re-check in `resolve` is therefore unreachable. It is kept as an
  assertion, with the evidence recorded, rather than deleted — the cost is one
  date comparison, and the cost of the observation not generalising across macOS
  versions is a write to an occurrence the caller did not name.

- **A 403 from `allowed_origins` read as "the service is not running", and that
  stopped the install dead.** With the ordinary configuration — bind to the LAN
  address, allow only n8n's — the installer's health probe used `curl -f`, so a
  403 arrived as the same silence as a refused connection. It skipped the
  permission step, `doctor` told the user to start a service that was already
  running, and `preflight` said the same. Since `preflight` became the only way
  to grant the service anything, there was no route left to finish an install.

  Three fixes, because one would not do. The probe now treats **any** HTTP
  status as proof the server answered. `doctor` and `preflight` distinguish a
  refusal from silence and point at `allowed_origins` rather than at
  `launchctl`. And the filter itself no longer locks a Mac out of its own
  service: a request whose source address is the address the server bound to
  came from this same host, and is allowed.

  Also in the same messages: the `launchctl kickstart` line was missing the
  slash between the domain and the service name, and the reinstall notice
  claimed permissions "had to be granted again" — on the Mac they survived the
  rebuild. It no longer asserts either way and points at `doctor`.

- ~~**`PATCH ?span=future_events` still returned 200 for an edit it did not
  make.**~~ **Retracted.** This entry, published in `v1.1.0-rc.6`, was wrong.
  `future_events` was never broken: the requests behind the report sent `span`
  in the query string, which `PATCH` does not read, so they ran as `this_event`
  and correctly changed one occurrence. The safety net was rewritten, and the
  documentation altered, to chase a bug that did not exist. See the entry above
  on the ignored `span` query for what was actually wrong and what was undone.

- **A single large note made itself unfetchable and poisoned every listing it
  appeared in.** One note of embedded images measured 17.8 MB — 107 characters
  of text. `GET /v1/notes/:id` returned `413` for it, so its title, folder and
  dates were unreachable because one field was too big, and the error advised
  fetching bodies "one note at a time", which is what that endpoint already is.
  `include_body=false` was ignored there. And because the cap counted notes
  rather than bytes, any listing that happened to include that note failed —
  slowly, at 13.5s, with the generic message.

  Bodies are now budgeted in bytes (`note_body_budget_bytes`, 6 MB) and measured
  inside the AppleScript, which can size a body without shipping it. A body that
  will not fit is replaced by **`body_omitted`** naming the size; the note comes
  back regardless. `include_body=false` is honoured on the detail endpoint.

  This buys correctness rather than speed on listings: Notes hands a body to the
  script before its size can be known, so a listing that reaches a very large
  note now succeeds where it used to fail, but is still slow. Documented.

- **A misspelled query parameter was ignored, and the answer looked fine.**
  `?calendar=RS-Test` — the parameter is `calendars` — returned `200` with all
  74 events on the Mac, and quietly contaminated a verification run before
  anyone noticed. Request bodies have rejected unknown fields since the
  `due_date` incident; query strings now do too, with the same near-miss
  suggestions. **This is a behaviour change** for any client passing extra
  parameters. `GET /v1` and `GET /v1/health` are exempt, since health checks
  routinely append cache-busters.

- **`GET /v1/notes/:id` took 1.2s where the equivalent AppleScript took 0.33s.**
  Every property read is a round trip to Notes, and the script was making about
  nine of them: a redundant name probe before the real one, then each field
  separately. It now reads `properties` in a single round trip when the body is
  wanted anyway — which also yields the container, removing the folder lookup —
  and falls back to the old per-property path, logging `RS_PROPS_FALLBACK`, if
  that fails.

- **Four release candidates shipped notes that omitted their own fixes.** The
  release workflow builds its notes from the CHANGELOG section matching the
  version being tagged, and everything since rc.1 had accumulated under
  `Unreleased` — so the artefact contained the fixes and the release page did
  not mention them. The fixes are filed under `1.1.0` now, and the workflow
  appends anything still under `Unreleased` instead of dropping it silently.

- **`doctor` and `preflight` reported the permissions of whatever ran them, not
  the service's.** macOS attributes a privacy grant to the *responsible
  process* — for a command run in a terminal, that is the terminal application.
  So `preflight` granted Terminal (or Claude.app, or whatever launched it) and
  `doctor` then read those grants back and printed "Reminders: granted ✓" while
  the LaunchAgent was answering 403 to every request. The remedy the error
  itself printed — "run preflight from a terminal" — could never work for the
  service.

  `doctor` now asks the running service over HTTP and labels the two clearly,
  the service's first. A new **`POST /v1/system/permissions/request`** makes the
  service raise its own prompts, which is the only route that grants the
  service; `preflight` uses it. All the remedy text was rewritten to stop
  recommending something that cannot work.

  `scripts/install.sh` runs the permission step *after* the LaunchAgent is up
  rather than before it, since `preflight` now needs a service to talk to, and
  its reinstall notice no longer claims a bare `preflight` re-grants the service.

- **Every read blocked for 60 seconds before its 403 when permissions were
  undetermined.** The prompt was raised on each request with a 60-second wait,
  and under launchd nobody is watching to accept it, so a permission problem
  presented as a hang. The prompt is now raised at most once per process, waits
  8 seconds, and the outcome is cached — later requests fail in milliseconds.
  The message also distinguishes "the prompt went unanswered" from "the user
  declined", which need different remedies.

- **`GET /v1/notes/:id` took ~1.9 s, of which ~1.6 s was scanning every folder.**
  The note's container is readable directly; the catch is the coercion —
  `name of container of n` in one expression fails with -1700, and the container
  has to be bound to a variable first. That single-expression form is what made
  it look unreadable and sent us scanning. The scan remains as a fallback.

- **An over-limit `include_body` request took up to 17 seconds to return 413.**
  The deadlock fix was correct but could not make the failure fast: `osascript`
  returns its whole result at the end, so nothing exceeds the cap until all the
  work is done, and killing the child saves nothing. `include_body` is now
  capped at 15 notes (`max_notes_with_body`, configurable) and checked before
  any work starts, so it fails in milliseconds. An explicit over-cap `limit` is
  refused; an omitted one is clamped, since the default of 50 is the server's
  choice and `?include_body=true` on its own should not fail. The response
  reports `limit_applied` when it clamps.

- **Span operations resolve the occurrence through a date predicate**, the route
  EventKit's span semantics are defined against, rather than through an
  identifier lookup. The outcome is then verified: if a `future_events` edit
  ends up affecting only its own occurrence, or a `future_events` delete leaves
  later occurrences behind, the call returns `502` saying so instead of a
  misleading `200`.

  > **Superseded.** This entry originally reported that `future_events` changed
  > only the occurrence it named. It does not, and never did — see the retracted
  > entry above. Whether this report shared the query-string mistake that
  > invalidated the later ones was never established, but no detachment has been
  > observed since, on any invocation known to have been well formed. The
  > predicate resolution and the check are kept as safeguards; the claim that
  > they were fixing an observed failure is withdrawn.

- **A reply over 8 MB deadlocked the subprocess instead of erroring.** The pipe
  reader stopped draining once the output cap was hit, which left `osascript`
  blocked forever writing into a full pipe; only the 30-second timeout freed it,
  and the caller was told "Apple Notes did not respond" — the opposite of the
  truth, since Notes had answered and nobody was reading. Observed as
  `GET /v1/notes?include_body=true` failing with a 504 at exactly `limit=20` on
  a folder of long notes, while `limit=15` worked.

  The reader now drains and discards past the cap, the child is stopped as soon
  as the cap is passed rather than at the timeout, and the error is
  `413 payload_too_large` naming the limit and what to do about it. Any command
  producing more than 8 MB was affected, not just Notes.

### Fixed — the server did not start (found in the first round)

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

- **`GET /v1/diagnostics/event-resolution/:id`**, read-only, reporting what
  `event(withIdentifier:)` returns for an id and which branch of the resolver a
  real call takes. The question cannot be answered from outside the service —
  all three possible answers produce the same observable behaviour, and only a
  process holding the calendar grant can look — so the resolver's dead branches
  can now be removed with evidence instead of guesswork.

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
