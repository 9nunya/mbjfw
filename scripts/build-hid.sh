#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK=${ANDROID_SDK_ROOT:-"$HOME/Library/Application Support/MBJFW/android-runtime/android-sdk"}
BUILD="$ROOT/.build/guest-hid"
mkdir -p "$BUILD" "$ROOT/Sources/MBJFW/Resources"
xcrun clang -target aarch64-linux-android -O2 -ffreestanding -fno-stack-protector -fno-builtin -c "$ROOT/Guest/HID/hid.c" -o "$BUILD/hid.o"
"$SDK/build-tools/35.0.0/lld-bin/lld" -flavor gnu -m aarch64elf -static -e _start "$BUILD/hid.o" -o "$ROOT/Sources/MBJFW/Resources/mbjfw-hid"
