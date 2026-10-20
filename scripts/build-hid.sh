#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$(uname -m)" in
    arm64) DEFAULT_RUNTIME=android-runtime ;;
    x86_64) DEFAULT_RUNTIME=android-runtime-x86_64 ;;
    *) echo "Unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
esac
SDK=${ANDROID_SDK_ROOT:-"$HOME/Library/Application Support/MBJFW/$DEFAULT_RUNTIME/android-sdk"}
BUILD="$ROOT/.build/guest-hid"
TARGET=${1:-all}
mkdir -p "$BUILD" "$ROOT/Sources/MBJFW/Resources"

build_one() {
    architecture=$1
    case "$architecture" in
        arm64)
            triple=aarch64-linux-android
            linker_machine=aarch64elf
            ;;
        x86_64)
            triple=x86_64-linux-android
            linker_machine=elf_x86_64
            ;;
        *) echo "Usage: $0 [arm64|x86_64|all]" >&2; exit 2 ;;
    esac
    output="$ROOT/Sources/MBJFW/Resources/mbjfw-hid-$architecture"
    xcrun clang -target "$triple" -O2 -ffreestanding -fno-stack-protector -fno-builtin \
        -c "$ROOT/Guest/HID/hid.c" -o "$BUILD/hid-$architecture.o"
    "$SDK/build-tools/35.0.0/lld-bin/lld" -flavor gnu -m "$linker_machine" -static \
        -e _start "$BUILD/hid-$architecture.o" -o "$output"
}

if [ "$TARGET" = all ]; then
    build_one arm64
    build_one x86_64
else
    build_one "$TARGET"
fi
