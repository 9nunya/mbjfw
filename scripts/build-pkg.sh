#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
APP=${MBJFW_APP_OUTPUT:-"$ROOT/dist/MBJFW.app"}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/AppInfo.plist")
HOST_ARCH=$(uname -m)
PACKAGE_ARCH=${MBJFW_PACKAGE_ARCH:-$HOST_ARCH}
case "$PACKAGE_ARCH" in
    arm64|x86_64) ;;
    *) echo "Unsupported macOS package architecture: $PACKAGE_ARCH" >&2; exit 2 ;;
esac
if [ "$PACKAGE_ARCH" != "$HOST_ARCH" ]; then
    case "${MBJFW_SWIFT_TRIPLE:-}" in
        "$PACKAGE_ARCH"-apple-macos*) ;;
        *) echo "Cross-packaging for $PACKAGE_ARCH requires MBJFW_SWIFT_TRIPLE=$PACKAGE_ARCH-apple-macosx<version>." >&2; exit 2 ;;
    esac
fi
OUTPUT=${MBJFW_PKG_OUTPUT:-"$ROOT/dist/MBJFW-$VERSION-macos-$PACKAGE_ARCH.pkg"}
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
ACTUAL_ARCH=$(/usr/bin/lipo -archs "$APP/Contents/MacOS/MBJFW")
if [ "$ACTUAL_ARCH" != "$PACKAGE_ARCH" ]; then
    echo "Expected a $PACKAGE_ARCH app bundle, found $ACTUAL_ARCH." >&2
    exit 1
fi
STAGED_APP="$WORK/MBJFW.app"
/usr/bin/ditto --norsrc --noextattr --noqtn "$APP" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

# Put the app in a root-based payload and disable Installer's bundle relocation
# and version checks. Component-mode packaging can follow a matching bundle
# into a developer checkout, and its default version check skips older builds.
STAGING_ROOT="$WORK/root"
COMPONENTS="$WORK/components.plist"
/bin/mkdir -p "$STAGING_ROOT/Applications"
/usr/bin/ditto --norsrc --noextattr --noqtn "$STAGED_APP" "$STAGING_ROOT/Applications/MBJFW.app"
/usr/bin/pkgbuild --analyze --root "$STAGING_ROOT" "$COMPONENTS"
set_component_value() {
    KEY=$1
    TYPE=$2
    VALUE=$3
    if /usr/libexec/PlistBuddy -c "Print :0:$KEY" "$COMPONENTS" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :0:$KEY $VALUE" "$COMPONENTS"
    else
        /usr/libexec/PlistBuddy -c "Add :0:$KEY $TYPE $VALUE" "$COMPONENTS"
    fi
}
set_component_value BundleIsRelocatable bool false
set_component_value BundleIsVersionChecked bool false
set_component_value BundleOverwriteAction string upgrade
set -- --root "$STAGING_ROOT" \
    --component-plist "$COMPONENTS" \
    --identifier dev.mbjfw.launcher.pkg \
    --version "$VERSION" \
    --install-location /
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
