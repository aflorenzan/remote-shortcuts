#!/bin/bash
#
# Boots the real server and talks to it over TCP.
#
# This exists because the unit tests never open a socket. A bug that made
# `NWListener` refuse to start on any host but 0.0.0.0 — that is, on every
# default install — passed a green build, got merged, and shipped in a release.
# Compiling and unit-testing a server is not the same as starting one.
#
# Runs against a throwaway config so it cannot touch a real installation.

set -euo pipefail

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

WORKDIR="$(mktemp -d)"
export REMOTE_SHORTCUTS_CONFIG_DIR="${WORKDIR}/config"
# Modules off: this is about the listener and the request pipeline, not about
# EventKit or Notes, which need permissions a CI runner does not have.
export REMOTE_SHORTCUTS_DISABLE="shortcuts,calendars,reminders,notes"
export REMOTE_SHORTCUTS_LOG_LEVEL="debug"

PORT="${SMOKE_PORT:-18787}"
export REMOTE_SHORTCUTS_PORT="${PORT}"

SERVER_PID=""
cleanup() {
    [[ -n "${SERVER_PID}" ]] && kill "${SERVER_PID}" 2>/dev/null || true
    rm -rf "${WORKDIR}"
}
trap cleanup EXIT

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mFAIL:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }

BIN="$(swift build -c release --show-bin-path)/remote-shortcuts"
[[ -x "${BIN}" ]] || die "${BIN} is missing — build first"

info "Generating a throwaway config"
"${BIN}" init --force > /dev/null
TOKEN="$("${BIN}" token show)"
[[ -n "${TOKEN}" ]] || die "no token was generated"

# The default host. This is the case that was broken: a concrete address in
# requiredLocalEndpoint alongside an explicit port made the listener fail EINVAL.
info "Starting the server on 127.0.0.1:${PORT}"
"${BIN}" serve > "${WORKDIR}/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
    curl -fsS --max-time 1 "http://127.0.0.1:${PORT}/v1/health" >/dev/null 2>&1 && break
    kill -0 "${SERVER_PID}" 2>/dev/null || { cat "${WORKDIR}/server.log"; die "the server exited during startup"; }
    sleep 0.2
done

curl -fsS --max-time 2 "http://127.0.0.1:${PORT}/v1/health" >/dev/null \
    || { cat "${WORKDIR}/server.log"; die "the server never answered on 127.0.0.1:${PORT}"; }
ok "listener is up and /v1/health answers"

# --- The request pipeline, end to end over a real socket -------------------

HEALTH="$(curl -fsS "http://127.0.0.1:${PORT}/v1/health")"
echo "${HEALTH}" | grep -q '"status":"ok"' || die "unexpected health payload: ${HEALTH}"
ok "health payload is well formed"

STATUS="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/v1")"
[[ "${STATUS}" == "401" ]] || die "expected 401 without a token, got ${STATUS}"
ok "401 without credentials"

STATUS="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer wrong-token-entirely" "http://127.0.0.1:${PORT}/v1")"
[[ "${STATUS}" == "401" ]] || die "expected 401 with a bad token, got ${STATUS}"
ok "401 with the wrong token"

STATUS="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/v1")"
[[ "${STATUS}" == "200" ]] || die "expected 200 with a good token, got ${STATUS}"
ok "200 with the right token"

# Disabled modules must 404 before any Apple framework is touched.
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/v1/notes")"
[[ "${STATUS}" == "404" ]] || die "expected 404 for a disabled module, got ${STATUS}"
ok "disabled modules 404"

STATUS="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${TOKEN}" "http://127.0.0.1:${PORT}/v1/definitely-not-a-route")"
[[ "${STATUS}" == "404" ]] || die "expected 404 for an unknown route, got ${STATUS}"
ok "unknown routes 404"

# HEAD is answered as a bodyless GET, which uptime monitors rely on.
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -I "http://127.0.0.1:${PORT}/v1/health")"
[[ "${STATUS}" == "200" ]] || die "expected 200 for HEAD, got ${STATUS}"
ok "HEAD works"

# Security headers are added on every response, error paths included.
HEADERS="$(curl -sS -D - -o /dev/null "http://127.0.0.1:${PORT}/v1/health")"
echo "${HEADERS}" | grep -qi 'X-Content-Type-Options: nosniff' || die "missing X-Content-Type-Options"
echo "${HEADERS}" | grep -qi "Content-Security-Policy" || die "missing Content-Security-Policy"
ok "security headers present"

# Chunked bodies are refused rather than parsed — request-smuggling defence.
STATUS="$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer ${TOKEN}" \
    -H 'Content-Type: application/json' -H 'Transfer-Encoding: chunked' \
    --data '{"a":1}' "http://127.0.0.1:${PORT}/v1/notes" 2>/dev/null || echo 000)"
[[ "${STATUS}" == "501" || "${STATUS}" == "000" ]] || die "expected Transfer-Encoding to be refused, got ${STATUS}"
ok "Transfer-Encoding refused"

info "Checking a clean shutdown on SIGTERM"
kill -TERM "${SERVER_PID}"
for _ in $(seq 1 25); do
    kill -0 "${SERVER_PID}" 2>/dev/null || break
    sleep 0.2
done
kill -0 "${SERVER_PID}" 2>/dev/null && die "the server ignored SIGTERM"
SERVER_PID=""
ok "exits on SIGTERM"

printf '\n\033[1;32mSmoke test passed.\033[0m\n'
