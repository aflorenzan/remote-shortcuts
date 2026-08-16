#!/bin/bash
#
# Supply-chain audit.
#
# The security story of this project rests on one claim: no third-party code
# runs in the request path. A claim nobody checks decays, so this script
# mechanically verifies it and is wired into CI and the Makefile.
#
# It fails the build if:
#   1. Package.swift declares any external dependency
#   2. a Package.resolved appears with pinned remote packages
#   3. any source file imports a module outside the Apple SDK allow-list
#   4. any script pipes a download straight into a shell

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

FAILURES=0
pass() { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
fail() { printf '  \033[1;31m✗\033[0m %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

echo "Supply-chain audit"
echo

# --- 1. No package dependencies -------------------------------------------

if grep -qE '^[[:space:]]*\.package\(' Package.swift; then
    fail "Package.swift declares an external dependency"
    grep -nE '^[[:space:]]*\.package\(' Package.swift | sed 's/^/      /'
else
    pass "Package.swift declares no external dependencies"
fi

# --- 2. No resolved remote pins -------------------------------------------

if [[ -f Package.resolved ]]; then
    if grep -q '"location"\|"repositoryURL"' Package.resolved 2>/dev/null; then
        fail "Package.resolved pins remote packages"
    else
        pass "Package.resolved contains no remote packages"
    fi
else
    pass "No Package.resolved (nothing to pin)"
fi

# --- 3. Imports restricted to the Apple SDK -------------------------------
#
# Every module here ships with macOS and is signed by Apple. Anything else
# would mean code we did not audit is linked into a process that holds
# Calendars, Reminders and Automation permissions.

ALLOWED_IMPORTS=(
    Foundation
    Network
    CoreGraphics
    EventKit
    CryptoKit
    Security
    Dispatch
    XCTest
    RemoteShortcutsCore
)

UNEXPECTED=0
while IFS= read -r line; do
    # `grep -rn` gives "path:lineno:import Foo"
    file="$(echo "${line}" | cut -d: -f1)"
    module="$(echo "${line}" | cut -d: -f3- | sed -E 's/^[[:space:]]*import[[:space:]]+([A-Za-z_][A-Za-z0-9_]*).*/\1/')"
    [[ -z "${module}" ]] && continue

    allowed=0
    for candidate in "${ALLOWED_IMPORTS[@]}"; do
        if [[ "${module}" == "${candidate}" ]]; then allowed=1; break; fi
    done
    if (( allowed == 0 )); then
        fail "Unexpected import '${module}' in ${file}"
        UNEXPECTED=$((UNEXPECTED + 1))
    fi
done < <(grep -rn --include='*.swift' -E '^[[:space:]]*import[[:space:]]' Sources Tests 2>/dev/null || true)

if (( UNEXPECTED == 0 )); then
    pass "All imports come from the macOS SDK"
fi

# --- 4. No curl-pipe-shell anywhere ---------------------------------------

# Comment lines are stripped first, so the sentence in install.sh explaining
# why we do not do this does not trip the check that we do not do it.
if grep -rnE '(curl|wget)[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' scripts/ Makefile 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'; then
    fail "A script pipes a download into a shell"
else
    pass "No download-piped-to-shell patterns"
fi

# --- 5. Installers must not fetch anything --------------------------------
#
# The release installer unpacks an already-downloaded tarball; neither
# installer should reach the network except to health-check the local server.

NETWORK_CALLS=0
for installer in scripts/install.sh scripts/install-release.sh; do
    [[ -f "${installer}" ]] || continue
    if grep -nE '^[^#]*\b(curl|wget)\b' "${installer}" \
        | grep -vE 'localhost|127\.0\.0\.1|\$\{ENDPOINT\}' >/dev/null 2>&1; then
        fail "${installer} reaches out to the network"
        NETWORK_CALLS=$((NETWORK_CALLS + 1))
    fi
done
if (( NETWORK_CALLS == 0 )); then
    pass "Installers only talk to the local server"
fi

# --- 6. GitHub Actions pinned to commit SHAs ------------------------------
#
# A tag can be moved to point at new code; a 40-character SHA cannot. Actions
# run with write access to this repository during releases, so they get the
# same pinning rule as everything else.

UNPINNED=0
if [[ -d .github/workflows ]]; then
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        if ! echo "${line}" | grep -qE 'uses:[[:space:]]*[^@]+@[0-9a-f]{40}([[:space:]]|$|#)'; then
            fail "Action not pinned to a commit SHA: ${line#*:}"
            UNPINNED=$((UNPINNED + 1))
        fi
    done < <(grep -rhnE '^[[:space:]]*(-[[:space:]]*)?uses:' .github/workflows/ 2>/dev/null || true)
fi
if (( UNPINNED == 0 )); then
    pass "All GitHub Actions pinned to commit SHAs"
fi

echo
if (( FAILURES > 0 )); then
    printf '\033[1;31m%d check(s) failed.\033[0m\n' "${FAILURES}"
    exit 1
fi
printf '\033[1;32mAll supply-chain checks passed.\033[0m\n'
