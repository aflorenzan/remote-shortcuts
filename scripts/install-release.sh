#!/bin/bash
#
# Installer shipped inside the release tarball.
#
# Unlike scripts/install.sh in the repository, this one does not compile —
# the tarball already contains a signed universal app bundle built by CI from
# the tagged commit. If you would rather not trust a prebuilt binary, clone the
# repository and run scripts/install.sh instead; it produces the same thing
# from source on your own machine.
#
# You can verify what you downloaded before running this:
#   shasum -a 256 -c SHA256SUMS
#   gh attestation verify remote-shortcuts-<version>-macos-universal.tar.gz \
#      --repo aflorenzan/remote-shortcuts

set -euo pipefail

readonly BUNDLE_ID="com.remoteshortcuts.server"
readonly APP_NAME="RemoteShortcuts"
readonly SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

APP_DIR="${HOME}/Applications/${APP_NAME}.app"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
LOG_DIR="${HOME}/Library/Logs/remote-shortcuts"
BIN_LINK="${HOME}/.local/bin/remote-shortcuts"
CONFIG_DIR="${HOME}/.config/remote-shortcuts"

SKIP_PREFLIGHT=0
SKIP_AGENT=0

usage() {
    cat <<EOF
Usage: ./install.sh [options]

  --no-preflight   Do not prompt for macOS permissions during install
  --no-agent       Install the app only; do not register the LaunchAgent
  -h, --help       Show this help
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

# --- Preconditions ---------------------------------------------------------

[[ "$(uname -s)" == "Darwin" ]] || die "remote-shortcuts only runs on macOS."

macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if (( macos_major < 13 )); then
    die "macOS 13 (Ventura) or newer is required; this machine reports $(sw_vers -productVersion)."
fi

[[ -d "${SOURCE_DIR}/${APP_NAME}.app" ]] || \
    die "${APP_NAME}.app is not next to this script. Run install.sh from the extracted tarball."

# The bundle is ad-hoc signed, so this proves the contents have not been
# modified since it was built — not who built it. Provenance comes from the
# attestation (see the header of this file).
info "Verifying the bundle signature"
codesign --verify --deep --strict "${SOURCE_DIR}/${APP_NAME}.app" || \
    die "Signature check failed. Do not install this bundle; download it again."

# --- Install ---------------------------------------------------------------

info "Installing to ${APP_DIR}"
rm -rf "${APP_DIR}"
mkdir -p "$(dirname "${APP_DIR}")"
cp -R "${SOURCE_DIR}/${APP_NAME}.app" "${APP_DIR}"

# Strip the quarantine attribute Safari/curl attaches to downloads, which would
# otherwise make Gatekeeper block a bundle that is not Developer ID signed.
xattr -dr com.apple.quarantine "${APP_DIR}" 2>/dev/null || true

APP_BINARY="${APP_DIR}/Contents/MacOS/remote-shortcuts"
[[ -x "${APP_BINARY}" ]] || die "The installed bundle has no executable."

mkdir -p "$(dirname "${BIN_LINK}")"
ln -sf "${APP_BINARY}" "${BIN_LINK}"
info "Linked CLI at ${BIN_LINK}"

case ":${PATH}:" in
    *":$(dirname "${BIN_LINK}"):"*) ;;
    *) warn "$(dirname "${BIN_LINK}") is not on your PATH. Add this to your shell profile:
      export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# --- Configuration ---------------------------------------------------------

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

# --- Permissions -----------------------------------------------------------

if (( SKIP_PREFLIGHT == 0 )); then
    info "Requesting macOS permissions (approve the prompts that appear)"
    "${APP_BINARY}" preflight || warn "Some permissions were not granted. Run 'remote-shortcuts doctor' later."
fi

# --- LaunchAgent -----------------------------------------------------------

if (( SKIP_AGENT == 0 )); then
    info "Installing the LaunchAgent"
    mkdir -p "${LOG_DIR}" "$(dirname "${LAUNCH_AGENT}")"
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

    info "Waiting for the server to come up"
    for _ in $(seq 1 25); do
        curl -fsS --max-time 2 "${ENDPOINT}/v1/health" >/dev/null 2>&1 && break
        sleep 0.4
    done

    if curl -fsS --max-time 2 "${ENDPOINT}/v1/health" >/dev/null 2>&1; then
        info "Server is healthy"
    else
        warn "The server did not answer on ${ENDPOINT}. Check ${LOG_DIR}/server.error.log"
    fi
fi

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

  Manage the service:
    launchctl kickstart -k gui/\$(id -u)/${BUNDLE_ID}   # restart
    remote-shortcuts doctor                            # diagnose
    ./uninstall.sh                                     # remove

SUMMARY
