#!/bin/bash
#
# Builds the distributable app bundle and tarball.
#
# Used by the release workflow, and runnable by hand so anyone can rebuild a
# published artefact and compare checksums. Same inputs, same outputs — the
# only thing CI adds is a provenance attestation.
#
# Usage: scripts/package.sh [version]   (version defaults to the git describe)

set -euo pipefail

readonly BUNDLE_ID="com.remoteshortcuts.server"
readonly APP_NAME="RemoteShortcuts"
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${REPO_ROOT}"

VERSION="${1:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
VERSION="${VERSION#v}"

DIST="${REPO_ROOT}/dist"
STAGE="${DIST}/stage"
APP_DIR="${STAGE}/${APP_NAME}.app"

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "Packaging requires macOS."

rm -rf "${DIST}"
mkdir -p "${STAGE}"

# Universal so one artefact covers Apple silicon and Intel Macs.
info "Building universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64
BIN_PATH="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/remote-shortcuts"
[[ -x "${BIN_PATH}" ]] || die "Build finished but ${BIN_PATH} is missing."

info "Assembling ${APP_NAME}.app"
mkdir -p "${APP_DIR}/Contents/MacOS"
cp "${REPO_ROOT}/Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/remote-shortcuts"
chmod 755 "${APP_DIR}/Contents/MacOS/remote-shortcuts"

# Ad-hoc signature: enough for macOS to attribute privacy permissions to a
# stable bundle identifier. Not a Developer ID — see the release notes.
info "Signing ad-hoc"
codesign --force --sign - --identifier "${BUNDLE_ID}" "${APP_DIR}"
codesign --verify --verbose=2 "${APP_DIR}" 2>&1 | sed 's/^/    /'

# Ship the scripts and docs the app needs to be installed and understood.
cp "${REPO_ROOT}/scripts/install-release.sh" "${STAGE}/install.sh"
cp "${REPO_ROOT}/scripts/uninstall.sh" "${STAGE}/uninstall.sh"
cp "${REPO_ROOT}/README.md" "${REPO_ROOT}/SECURITY.md" "${REPO_ROOT}/LICENSE" "${STAGE}/"
chmod 755 "${STAGE}/install.sh" "${STAGE}/uninstall.sh"

TARBALL="${DIST}/remote-shortcuts-${VERSION}-macos-universal.tar.gz"
info "Creating $(basename "${TARBALL}")"
# COPYFILE_DISABLE keeps AppleDouble (._*) entries out of the archive, so the
# checksum does not depend on extended attributes of the build machine. It is
# preferred over tar's --no-mac-metadata because an unrecognised flag would
# abort the release after the build and signing have already succeeded.
COPYFILE_DISABLE=1 tar -czf "${TARBALL}" -C "${STAGE}" .

info "Writing checksums"
(cd "${DIST}" && shasum -a 256 "$(basename "${TARBALL}")" > SHA256SUMS)

lipo -archs "${APP_DIR}/Contents/MacOS/remote-shortcuts" | sed 's/^/    architectures: /'
cat "${DIST}/SHA256SUMS"

info "Artefacts in ${DIST}"
