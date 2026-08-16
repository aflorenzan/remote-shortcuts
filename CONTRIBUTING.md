# Contributing

Thanks for taking a look. This is a small project with one hard rule and a few
soft ones.

## The hard rule: no third-party dependencies

This server runs with permission to read and write your calendars, reminders
and notes, and to execute shortcuts. Every package added to it is code with
those permissions that nobody in this repository has read.

So `Package.swift` keeps an empty `dependencies` array, and
`scripts/audit-dependencies.sh` fails CI if that changes, if an `import`
appears that is not in the macOS SDK allow-list, or if a script starts piping
downloads into a shell.

If you genuinely need something the SDK does not provide, open an issue first
and let's talk about writing the small piece by hand — that is how the CIDR
matcher and the HTTP parser got here.

## Getting set up

```bash
git clone https://github.com/aflorenzan/remote-shortcuts.git
cd remote-shortcuts
make test     # unit tests
make audit    # supply-chain checks
make run      # foreground server on 127.0.0.1:8787
```

You need macOS 13+ and the Xcode Command Line Tools. `make run` uses your real
config, so `remote-shortcuts init` first if you have not installed yet.

## Before you open a pull request

- `make test` passes.
- `make audit` passes.
- New behaviour has a test. The security-relevant paths — parsing, auth, rate
  limiting, address matching — are where tests matter most, because they are
  the pieces an attacker interacts with.
- `shellcheck scripts/*.sh` is clean if you touched shell.

CI runs the tests on a real macOS runner, so anything EventKit-specific gets
compiled even though it cannot be exercised without a signed-in account.

## House style

Match the surrounding code. A few conventions worth naming:

- **Comments explain why, not what.** If a line is doing something surprising —
  a workaround for an EventKit quirk, a deliberate rejection in the parser —
  say why it is there. Skip comments that restate the code.
- **Errors are written for the person wiring up the automation.** `APIError`
  messages should say what went wrong *and* what to do about it, and never leak
  internal paths or secrets.
- **No shell.** Subprocesses go through `ProcessRunner` with an argument
  vector. AppleScript takes user data through `argv`, never string
  interpolation. This is what makes injection structurally impossible rather
  than a thing we try to escape our way out of.
- British or American spelling, either is fine; be consistent within a file.

## Testing against real Apple apps

The unit tests deliberately do not touch EventKit or Notes — they would need a
signed-in Mac with real data and would be flaky. If you change those services,
exercise them by hand and say what you did in the pull request:

```bash
TOKEN=$(remote-shortcuts token show)
curl -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8787/v1/calendars | head
```

## Reporting security issues

Use GitHub's private vulnerability reporting on the repository. Please do not
open a public issue for anything exploitable.
