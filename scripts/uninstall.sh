#!/bin/bash
#
# Removes the LaunchAgent, app bundle and CLI symlink.
# The config file (which holds your token) is kept unless --purge is passed.

set -euo pipefail

readonly BUNDLE_ID="com.remoteshortcuts.server"
APP_DIR="${HOME}/Applications/RemoteShortcuts.app"
LAUNCH_AGENT="${HOME}/Library/LaunchAgents/${BUNDLE_ID}.plist"
BIN_LINK="${HOME}/.local/bin/remote-shortcuts"
CONFIG_DIR="${HOME}/.config/remote-shortcuts"
LOG_DIR="${HOME}/Library/Logs/remote-shortcuts"

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

info "Stopping the service"
launchctl bootout "gui/$(id -u)/${BUNDLE_ID}" 2>/dev/null || \
    launchctl unload -w "${LAUNCH_AGENT}" 2>/dev/null || true

rm -f "${LAUNCH_AGENT}"
rm -rf "${APP_DIR}"
[[ -L "${BIN_LINK}" ]] && rm -f "${BIN_LINK}"

info "Removed the app bundle, LaunchAgent and CLI symlink"

if (( PURGE == 1 )); then
    rm -rf "${CONFIG_DIR}" "${LOG_DIR}"
    info "Removed the config and logs"
else
    cat <<EOF

Kept:
  ${CONFIG_DIR}   (config and API token)
  ${LOG_DIR}      (logs)
Pass --purge to delete those too.
EOF
fi

cat <<EOF

macOS remembers the privacy grants separately. To revoke them, remove
"Remote Shortcuts" from:
  System Settings → Privacy & Security → Calendars / Reminders / Automation
EOF
