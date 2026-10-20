#!/bin/sh
set -eu

# This probe opens a renderer-owned AppKit window using the existing guest.
# It does not erase guest data, register a capture callback, or request gRPC.
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 /absolute/path/to/profile/android-avd" >&2
    exit 2
fi
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$(uname -m)" in
    arm64) DEFAULT_RUNTIME=android-runtime ;;
    x86_64) DEFAULT_RUNTIME=android-runtime-x86_64 ;;
    *) echo "Unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
esac
RUNTIME="${MBJFW_RUNTIME_ROOT:-$HOME/Library/Application Support/MBJFW/$DEFAULT_RUNTIME}"
PROBE_DIR="${MBJFW_NATIVE_PROBE_DIR:-$ROOT/.build/native-host-probe}"
mkdir -p "$PROBE_DIR"
clang++ -std=c++17 -fobjc-arc -dynamiclib -framework AppKit \
    "$ROOT/NativeGameHost/Probes/NativeWindowProbe.mm" \
    -o "$PROBE_DIR/libNativeWindowProbe.dylib"

MBJFW_NATIVE_PROBE=1 \
DYLD_INSERT_LIBRARIES="$PROBE_DIR/libNativeWindowProbe.dylib" \
ANDROID_HOME="$RUNTIME/android-sdk" \
ANDROID_AVD_HOME="$RUNTIME/avd" \
"$RUNTIME/android-sdk/emulator/emulator" \
    -avd MBJFW -datadir "$1" -port "${MBJFW_NATIVE_PROBE_PORT:-5580}" \
    -gpu host -feature Vulkan,GuestAngle,VirtioInput,VirtioMouse,VirtioDualModeMouse \
    -qt-hide-window -no-boot-anim -no-snapshot-load -no-snapshot-save -no-metrics \
    -memory 4096 -cores 4
