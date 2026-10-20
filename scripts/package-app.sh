#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
APP=${MBJFW_APP_OUTPUT:-"$ROOT/dist/MBJFW.app"}
OPEN_APP=1
BUILD_NUMBER=${MBJFW_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/AppInfo.plist")}
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/AppInfo.plist")
case "$BUILD_NUMBER" in
    ''|*[!0-9]*) echo "MBJFW_BUILD_NUMBER must be a positive integer." >&2; exit 2 ;;
esac
if [ "${1:-}" = "--no-open" ]; then OPEN_APP=0; fi
if /bin/ps -ax -o comm= | /usr/bin/grep -Fxq "$APP/Contents/MacOS/MBJFW"; then
    echo 'Quit the running launcher before packaging so the next launch uses this build.' >&2
    exit 1
fi
if [ -n "${MBJFW_SWIFT_TRIPLE:-}" ]; then
    swift build -c release --triple "$MBJFW_SWIFT_TRIPLE"
    BIN=$(swift build -c release --triple "$MBJFW_SWIFT_TRIPLE" --show-bin-path)
else
    swift build -c release
    BIN=$(swift build -c release --show-bin-path)
fi
"$ROOT/scripts/make-icons.sh"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
RESOURCE_BUNDLE="$APP/Contents/Resources/MBJFW_MBJFW.bundle"
rm -rf "$RESOURCE_BUNDLE"
cp -R "$BIN/MBJFW_MBJFW.bundle" "$RESOURCE_BUNDLE"
# Some Swift toolchains emit a flat .bundle directory without bundle metadata.
# Foundation's Bundle(url:) rejects that layout, and SwiftPM's generated
# Bundle.module accessor then traps. Normalize either toolchain layout into a
# standard macOS resource bundle before signing the app.
mkdir -p "$RESOURCE_BUNDLE/Contents/Resources"
if [ ! -f "$RESOURCE_BUNDLE/Contents/Info.plist" ]; then
    cat > "$RESOURCE_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>dev.mbjfw.launcher.resources</string>
    <key>CFBundleName</key>
    <string>MBJFW Resources</string>
    <key>CFBundlePackageType</key>
    <string>BNDL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
</dict>
</plist>
PLIST
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$RESOURCE_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$RESOURCE_BUNDLE/Contents/Info.plist"
fi
for RESOURCE in "$RESOURCE_BUNDLE"/*; do
    [ -e "$RESOURCE" ] || continue
    [ "$RESOURCE" = "$RESOURCE_BUNDLE/Contents" ] && continue
    mv "$RESOURCE" "$RESOURCE_BUNDLE/Contents/Resources/"
done
plutil -lint "$RESOURCE_BUNDLE/Contents/Info.plist"
test -s "$RESOURCE_BUNDLE/Contents/Resources/appliance.apk"
test -x "$RESOURCE_BUNDLE/Contents/Resources/mbjfw-hid-arm64"
test -x "$RESOURCE_BUNDLE/Contents/Resources/mbjfw-hid-x86_64"
cp "$BIN/MBJFW" "$APP/Contents/MacOS/MBJFW.next"
mv "$APP/Contents/MacOS/MBJFW.next" "$APP/Contents/MacOS/MBJFW"
cp "$BIN/libMBJFWFrameBridge.dylib" "$APP/Contents/Frameworks/libMBJFWFrameBridge.dylib.next"
mv "$APP/Contents/Frameworks/libMBJFWFrameBridge.dylib.next" "$APP/Contents/Frameworks/libMBJFWFrameBridge.dylib"
cp "$ROOT/assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp AppInfo.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
/usr/bin/xattr -cr "$APP"
if [ "${MBJFW_APP_SIGNING_IDENTITY:--}" = "-" ]; then
    /usr/bin/codesign --force --deep --sign - "$APP"
else
    /usr/bin/codesign --force --deep --options runtime --timestamp \
        --entitlements "$ROOT/scripts/MBJFW.entitlements" \
        --sign "$MBJFW_APP_SIGNING_IDENTITY" "$APP"
fi
/usr/bin/codesign --verify --deep --strict "$APP"
if [ "$OPEN_APP" -eq 1 ] && [ "${MBJFW_NO_OPEN:-0}" != "1" ]; then open "$APP"; fi
