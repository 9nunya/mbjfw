#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
APP="$ROOT/dist/MBJFW.app"
OPEN_APP=1
BUILD_NUMBER=${MBJFW_BUILD_NUMBER:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/AppInfo.plist")}
case "$BUILD_NUMBER" in
    ''|*[!0-9]*) echo "MBJFW_BUILD_NUMBER must be a positive integer." >&2; exit 2 ;;
esac
if [ "${1:-}" = "--no-open" ]; then OPEN_APP=0; fi
if /bin/ps -ax -o comm= | /usr/bin/grep -Fxq "$APP/Contents/MacOS/MBJFW"; then
    echo 'Quit the running launcher before packaging so the next launch uses this build.' >&2
    exit 1
fi
swift build -c release
BIN=$(swift build -c release --show-bin-path)
"$ROOT/scripts/make-icons.sh"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp -R "$BIN/MBJFW_MBJFW.bundle" "$APP/Contents/Resources/"
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
