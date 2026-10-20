#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
APP="$ROOT/dist/MBJFW.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/AppInfo.plist")
OUTPUT=${MBJFW_PKG_OUTPUT:-"$ROOT/dist/MBJFW-$VERSION-macos-arm64.pkg"}
OUTPUT_DIR=$(dirname -- "$OUTPUT")
OUTPUT_NAME=$(basename -- "$OUTPUT")
mkdir -p "$OUTPUT_DIR"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/mbjfw-pkg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT HUP INT TERM

if [ "${MBJFW_NOTARIZE:-0}" = "1" ]; then
    : "${MBJFW_APP_SIGNING_IDENTITY:?Set MBJFW_APP_SIGNING_IDENTITY to a Developer ID Application identity}"
    : "${MBJFW_INSTALLER_SIGNING_IDENTITY:?Set MBJFW_INSTALLER_SIGNING_IDENTITY to a Developer ID Installer identity}"
    : "${MBJFW_NOTARY_PROFILE:?Store notarytool credentials and set MBJFW_NOTARY_PROFILE}"
fi

MBJFW_NO_OPEN=1 "$ROOT/scripts/package-app.sh" --no-open
STAGED_APP="$WORK/MBJFW.app"
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
set -- --component "$STAGED_APP" \
    --identifier dev.mbjfw.launcher.pkg \
    --version "$VERSION" \
    --install-location /Applications
if [ -n "${MBJFW_INSTALLER_SIGNING_IDENTITY:-}" ]; then
    set -- "$@" --sign "$MBJFW_INSTALLER_SIGNING_IDENTITY"
fi
set -- "$@" "$OUTPUT"
/usr/bin/pkgbuild "$@"

if [ "${MBJFW_NOTARIZE:-0}" = "1" ]; then
    xcrun notarytool submit "$OUTPUT" --keychain-profile "$MBJFW_NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUTPUT"
fi

(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$OUTPUT_NAME" > "$OUTPUT_NAME.sha256"
)
echo "Created $OUTPUT"
echo "Created $OUTPUT_DIR/$OUTPUT_NAME.sha256"
if [ -z "${MBJFW_INSTALLER_SIGNING_IDENTITY:-}" ]; then
    echo "Package is unsigned for local testing; public distribution needs Developer ID signing and notarization."
fi
