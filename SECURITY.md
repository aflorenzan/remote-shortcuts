# Security

This server holds permissions to read and write your calendars, reminders and
notes, and to run shortcuts — which can do anything you can do on the machine.
The design below follows from that.

## Threat model

**In scope**

- A process or device on your network reaching the port
- A malicious or compromised automation sending crafted payloads
- Credential leakage through logs, config files or process listings
- A dependency shipping malicious code into a privileged process
- A web page in your browser trying to reach the server (DNS rebinding, CSRF)

**Out of scope**

- An attacker who already has your user account on this Mac. They can read the
  config file, and they already have the permissions this server has.
- Physical access to an unlocked machine.

## Supply-chain posture

The reason this is written in Swift with no packages:

| Control | Implementation |
| --- | --- |
| **Zero third-party dependencies** | `Package.swift` declares an empty `dependencies` array. Everything linked — `Foundation`, `Network`, `EventKit`, `CryptoKit`, `Security` — ships inside macOS, signed by Apple. |
| **Mechanically enforced** | `scripts/audit-dependencies.sh` (run by `make audit` and by CI) fails the build if a dependency is declared, if a `Package.resolved` appears with remote pins, or if any source file imports a module outside the SDK allow-list. |
| **No install-time downloads** | `scripts/install.sh` fetches nothing. It compiles the source in the checkout with the toolchain already on the machine. |
| **No `curl \| bash`** | There is no remote install one-liner, and the audit script fails if one appears. You clone, read, then run. |
| **No build plugins or codegen** | Nothing executes at build time beyond the Swift compiler. |
| **Pinned CI actions** | GitHub Actions are pinned to full commit SHAs, not floating tags. |
| **Reproducible from source** | The binary you run is built on your machine from the code in the repo. No release artefact to be tampered with. |

The practical consequence: the set of code that runs inside a process holding
your Calendar and Reminders grants is *this repository plus macOS itself*.

## Network and authentication

- **Binds to `127.0.0.1` by default.** The listener is bound to a concrete
  local endpoint, not filtered after the fact.
- **Bearer token on every endpoint except `/v1/health`.** 32 bytes from
  `SecRandomCopyBytes`, rendered as 43 URL-safe base64 characters.
- **Constant-time comparison.** Tokens are compared as SHA-256 digests through
  an OR-accumulator that never branches on the data, so response timing does
  not leak the token byte by byte.
- **Tokens are never read from the query string** — only `Authorization:
  Bearer` and `X-API-Key` — because query strings land in proxy logs and
  browser history.
- **Rate limited** per source address (120 req/min default), which bounds
  online guessing and stops a runaway automation from hammering EventKit.
- **Source-address allow-list.** `loopback_only` is on automatically whenever
  the bind address is loopback; `allowed_origins` accepts IPs and CIDRs.
- **`Host` header validation** blocks DNS rebinding: a browser can be pointed
  at your port through an attacker-controlled hostname, but it cannot forge
  the `Host` header.
- **No CORS headers are ever sent**, and every response carries
  `Content-Security-Policy: default-src 'none'` plus `X-Content-Type-Options:
  nosniff`, so a page in your browser cannot read a response even if it
  manages to issue a request.

## Injection

The two places user input meets an interpreter:

**Shortcuts.** The shortcut name is one element of an argument vector passed
straight to `posix_spawn` via `Process`. No shell is involved anywhere in this
codebase, so a shortcut named `"; rm -rf ~"` is just a string. Input is passed
through a file in a mode-700 temporary directory, not on the command line.

**AppleScript.** Every script in `NotesService` is a compile-time constant
with an `on run argv` entry point; caller data arrives as process arguments.
Nothing is interpolated into script text, which makes AppleScript injection
structurally impossible rather than something we try to escape our way out of.

## Request parsing

The HTTP parser is deliberately strict:

- `Transfer-Encoding` is rejected with 501 — chunked bodies alongside
  `Content-Length` are the classic request-smuggling primitive, and an
  automation client never needs streaming uploads.
- More than one `Content-Length` is rejected.
- Obsolete header line-folding is rejected.
- Request line (8 KB), header block (32 KB), header count (100) and body
  (1 MB, configurable) are all capped, so a peer cannot force unbounded
  allocation.
- `..` in a path is rejected after percent-decoding.
- Concurrent connections are capped at 64, requests per connection at 100, and
  idle connections time out.
- CR/LF is stripped from every response header value, so no value can inject
  headers or split the response.

## Credentials at rest

- `~/.config/remote-shortcuts/` is created mode 700, `config.json` mode 600,
  written atomically.
- The server **refuses to start** if the config or token file is group- or
  world-readable, rather than warning and continuing.
- The logger redacts anything resembling a bearer token as a second line of
  defence.
- The token is never passed as a command-line argument, so it does not appear
  in `ps`.

## Reducing blast radius

If you expose the server beyond loopback, set both of these:

```json
{
  "allowed_shortcuts": ["Daily Briefing", "Log Expense"],
  "allowed_origins": ["192.168.1.0/24"]
}
```

`allowed_shortcuts` is the important one. Without it, anyone holding the token
can run *any* shortcut on the machine. Also consider `"read_only": true` for
consumers that only need to query, and turning off unused `modules`.

## Reporting a vulnerability

Open a GitHub issue for anything low-risk. For something exploitable, use
GitHub's private vulnerability reporting on the repository rather than a
public issue.
