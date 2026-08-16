# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
