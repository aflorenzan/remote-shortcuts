#!/bin/bash
#
# remote-shortcuts installer.
#
# Builds from the source in this checkout, wraps the binary in an app bundle so
# macOS can attribute privacy permissions to it, generates an API token, and
# registers a LaunchAgent that starts the server at login.
#
# Supply-chain note: this script downloads nothing. It compiles the sources you
# can read next to it, using the Swift toolchain already on the machine. There
# is deliberately no `curl | bash` install path — piping a remote script into a
# shell is exactly the attack this project is trying not to be part of.

set -euo pipefail

readonly BUNDLE_ID="com.remoteshortcuts.server"
readonly APP_NAME="RemoteShortcuts"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_DIR="${HOME}/Applications/${APP_NAME}.app"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
LOG_DIR="${HOME}/Library/Logs/remote-shortcuts"
BIN_LINK="${HOME}/.local/bin/remote-shortcuts"
CONFIG_DIR="${HOME}/.config/remote-shortcuts"

SKIP_PREFLIGHT=0
SKIP_AGENT=0
SERVER_UP=0

usage() {
    cat <<EOF
Usage: scripts/install.sh [options]

  --no-preflight   Do not prompt for macOS permissions during install
  --no-agent       Build and configure only; do not install the LaunchAgent
  -h, --help       Show this help

After installing, useful commands:
  remote-shortcuts doctor        Check permissions and configuration
  remote-shortcuts token show    Print the API token
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-preflight) SKIP_PREFLIGHT=1; shift ;;
        --no-agent) SKIP_AGENT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 64 ;;
    esac
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Preconditions ------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || die "remote-shortcuts only runs on macOS."

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if (( macos_major < 13 )); then
    die "macOS 13 (Ventura) or newer is required; this machine reports $(sw_vers -productVersion)."
fi

if ! command -v swift >/dev/null 2>&1; then
    die "The Swift toolchain is missing. Install the Xcode Command Line Tools with:
    xcode-select --install"
fi

if ! xcode-select -p >/dev/null 2>&1; then
    die "No active developer directory. Run: xcode-select --install"
fi

info "Building remote-shortcuts (release)"
cd "${REPO_ROOT}"

# Refuse to build if a dependency ever sneaks into the manifest. The zero-dep
# guarantee is only worth something if it is enforced mechanically.
if grep -qE '^\s*\.package\(' Package.swift; then
    die "Package.swift declares an external dependency. This project must stay dependency-free — refusing to build."
fi

# No --disable-sandbox: this package has no build plugins, so the sandbox costs
# nothing and keeps the promise that installing runs nothing untrusted.
swift build -c release 2>&1 | sed 's/^/    /'
BINARY="$(swift build -c release --show-bin-path)/remote-shortcuts"
[[ -x "${BINARY}" ]] || die "Build finished but ${BINARY} is missing."

# --- 2. App bundle ---------------------------------------------------------
#
# The binary is wrapped in a .app because TCC (the privacy database) keys
# permissions off a bundle identifier and code signature. A bare executable
# gets re-prompted or silently denied after every rebuild.

REINSTALL=0
[[ -d "${APP_DIR}" ]] && REINSTALL=1

info "Assembling ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
cp "${REPO_ROOT}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${BINARY}" "${APP_DIR}/Contents/MacOS/remote-shortcuts"
chmod 755 "${APP_DIR}/Contents/MacOS/remote-shortcuts"

# Ad-hoc signature with a stable identifier. Note what this does NOT buy:
# without a Team ID, TCC indexes the grant by CDHash, and the CDHash changes on
# every build. So Calendars/Reminders permissions must be granted again after a
# rebuild. (Apple Events, oddly, tends to survive.) Signing with a Developer ID
# certificate is what makes them persist — see README.
info "Signing the bundle (ad-hoc)"
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_DIR}" 2>&1 | sed 's/^/    /' || \
    warn "codesign failed; the bundle may not be able to hold privacy permissions at all."

APP_BINARY="${APP_DIR}/Contents/MacOS/remote-shortcuts"

# --- 3. CLI symlink --------------------------------------------------------

mkdir -p "$(dirname "${BIN_LINK}")"
ln -sf "${APP_BINARY}" "${BIN_LINK}"
info "Linked CLI at ${BIN_LINK}"

case ":${PATH}:" in
    *":$(dirname "${BIN_LINK}"):"*) ;;
    *) warn "$(dirname "${BIN_LINK}") is not on your PATH. Add this to your shell profile:
      export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# --- 4. Configuration ------------------------------------------------------

if [[ -f "${CONFIG_DIR}/config.json" ]]; then
    info "Keeping existing config at ${CONFIG_DIR}/config.json"
else
    info "Creating config and API token"
    "${APP_BINARY}" init >/dev/null
fi
chmod 700 "${CONFIG_DIR}" 2>/dev/null || true
chmod 600 "${CONFIG_DIR}/config.json" 2>/dev/null || true

TOKEN="$("${APP_BINARY}" token show)"
ENDPOINT="$("${APP_BINARY}" endpoint)"

# --- 5. LaunchAgent --------------------------------------------------------

if (( SKIP_AGENT == 0 )); then
    info "Installing the LaunchAgent"
    mkdir -p "${LOG_DIR}" "$(dirname "${LAUNCH_AGENT}")"

    # Unload any previous instance before overwriting the plist.
    launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || true

    cat > "${LAUNCH_AGENT}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${BUNDLE_ID}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${APP_BINARY}</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/server.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/server.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
</dict>
</plist>
PLIST

    chmod 644 "${LAUNCH_AGENT}"
    launchctl bootstrap "gui/$(id -u)" "${LAUNCH_AGENT}" 2>/dev/null || \
        launchctl load -w "${LAUNCH_AGENT}" 2>/dev/null || \
        warn "Could not register the LaunchAgent automatically. Load it with:
      launchctl bootstrap gui/\$(id -u) ${LAUNCH_AGENT}"

    # Any HTTP status means the server answered, and answering is the whole
    # question here. Not `curl -f`: that turns a 403 into the same silence as a
    # refused connection, and a 403 from 'allowed_origins' is a *running* server
    # declining this address. Reading it as "not running" skipped the permission
    # step below and left the install with no way to grant the service anything.
    probe_status() {
        curl -s -o /dev/null --max-time 2 -w '%{http_code}' "${ENDPOINT}/v1/health" 2>/dev/null || true
    }

    info "Waiting for the server to come up"
    STATUS=000
    for _ in $(seq 1 25); do
        STATUS="$(probe_status)"
        [[ "${STATUS}" != "000" ]] && break
        sleep 0.4
    done

    if [[ "${STATUS}" == "000" ]]; then
        warn "The server did not answer on ${ENDPOINT}. Check ${LOG_DIR}/server.error.log"
    elif [[ "${STATUS}" == "403" ]]; then
        SERVER_UP=1
        warn "The server is running, but it refused this machine with 403.
      That is 'allowed_origins' in ${CONFIG_DIR}/config.json: it lists which
      source addresses may call, and this Mac is not among them. Permissions
      can still be requested — the prompts appear on this screen either way —
      but ordinary calls from here will keep failing until you add its address."
    else
        info "Server is healthy"
        SERVER_UP=1
    fi
fi

# --- 6. Permissions --------------------------------------------------------
#
# This runs *after* the LaunchAgent is up, and not by accident. macOS attributes
# a privacy grant to the responsible process, so a prompt raised by this script
# would be granted to your terminal, not to the service. `preflight` therefore
# asks the running service to raise the prompts itself, which means the service
# has to exist first.

if (( SKIP_PREFLIGHT == 0 )); then
    if (( SERVER_UP == 1 )); then
        info "Requesting macOS permissions for the service (approve the prompts that appear)"
        if ! "${APP_BINARY}" preflight; then
            # Ask the service what it ended up with rather than trusting the
            # exit status of the call that reported the problem. A prompt
            # accepted a moment after that call stopped waiting still granted
            # the permission, and reporting failure then is simply wrong.
            info "Checking what the service ended up with"
            if "${APP_BINARY}" doctor >/dev/null 2>&1; then
                info "Permissions are in place after all"
            else
                warn "Some permissions are still missing. Accept the prompts if they are
      on screen, then run:
        remote-shortcuts preflight
        remote-shortcuts doctor"
            fi
        fi
    else
        warn "Skipping permission prompts: the service is not running, and only the
      service can be granted anything. Start it and run 'remote-shortcuts preflight':
      launchctl kickstart -k gui/\$(id -u)/${BUNDLE_ID}"
    fi
fi

# --- 7. Summary ------------------------------------------------------------

cat <<SUMMARY

$(printf '\033[1;32mInstalled.\033[0m')

  Endpoint    ${ENDPOINT}
  Token       ${TOKEN}
  Config      ${CONFIG_DIR}/config.json
  Logs        ${LOG_DIR}/server.log

  Try it:
    curl -H "Authorization: Bearer ${TOKEN}" ${ENDPOINT}/v1

  From n8n, use an HTTP Request node with a Header Auth credential:
    Name: Authorization    Value: Bearer ${TOKEN}

$(if (( REINSTALL == 1 )); then cat <<'REGRANT'
  ⚠️  You reinstalled over an existing bundle, which rebuilt the binary and so
      changed its code hash. With an ad-hoc signature macOS may treat that as a
      new app and forget the Calendars and Reminders grants — it does not always,
      and guessing either way is how this notice got it wrong before. Ask:

        remote-shortcuts doctor        # reports what the *service* holds

      If the grants are gone, re-request them with the service running:

        remote-shortcuts preflight     # asks the service to prompt; approve

      Prompting from a terminal any other way grants your terminal, not the
      service. Until the service holds them, those endpoints return 403.

REGRANT
fi)
  Manage the service:
    launchctl kickstart -k gui/\$(id -u)/${BUNDLE_ID}   # restart
    remote-shortcuts doctor                            # diagnose
    scripts/uninstall.sh                               # remove

SUMMARY
