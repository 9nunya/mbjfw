#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
case "$(uname -m)" in
    arm64) DEFAULT_RUNTIME=android-runtime ;;
    x86_64) DEFAULT_RUNTIME=android-runtime-x86_64 ;;
    *) echo "Unsupported host architecture: $(uname -m)" >&2; exit 2 ;;
esac
RUNTIME=${MBJFW_RUNTIME_ROOT:-"$HOME/Library/Application Support/MBJFW/$DEFAULT_RUNTIME"}
SDK=${ANDROID_SDK_ROOT:-"$RUNTIME/android-sdk"}
if [ -n "${JAVA_HOME:-}" ]; then
    JAVA=$JAVA_HOME
else
    JAVA=$(/usr/bin/find "$RUNTIME/jre" -type f -path '*/Contents/Home/bin/java' -perm -111 -print -quit | sed 's#/bin/java$##')
fi
if [ -z "$JAVA" ] || [ ! -x "$JAVA/bin/java" ]; then
    echo "No installed Java runtime found under $RUNTIME/jre" >&2
    exit 1
fi
TOOLS="$SDK/build-tools/35.0.0"
BUILD="$ROOT/.build/guest-appliance"
COMPILER=${ECJ_JAR:-"$ROOT/.build/toolchain/ecj-3.39.0.jar"}
if [ ! -f "$COMPILER" ]; then
    mkdir -p "$(dirname "$COMPILER")"
    curl -fL --retry 3 https://repo.maven.apache.org/maven2/org/eclipse/jdt/ecj/3.39.0/ecj-3.39.0.jar -o "$COMPILER"
fi
COMPILER_HASH=$(shasum -a 256 "$COMPILER" | cut -d ' ' -f 1)
[ "$COMPILER_HASH" = '01f5a92ac19bb2b3bf85e295a68f2c73c264369109158b566ce9b490af982948' ] || exit 1
mkdir -p "$BUILD/classes" "$BUILD/dex" "$ROOT/Sources/MBJFW/Resources"
"$JAVA/bin/java" -jar "$COMPILER" -source 8 -target 8 -bootclasspath "$SDK/platforms/android-35/android.jar" -d "$BUILD/classes" "$ROOT"/Guest/Appliance/src/dev/mbjfw/appliance/*.java
JAVA_HOME="$JAVA" "$TOOLS/d8" --min-api 28 --lib "$SDK/platforms/android-35/android.jar" --output "$BUILD/dex" "$BUILD"/classes/dev/mbjfw/appliance/*.class
"$TOOLS/aapt2" compile --dir "$ROOT/Guest/Appliance/res" -o "$BUILD/resources.zip"
"$TOOLS/aapt2" link -o "$BUILD/unsigned.apk" --manifest "$ROOT/Guest/Appliance/AndroidManifest.xml" -I "$SDK/platforms/android-35/android.jar" "$BUILD/resources.zip"
(cd "$BUILD/dex" && zip -q -u "$BUILD/unsigned.apk" classes.dex)
KEY="$ROOT/Guest/Appliance/development.keystore"
if [ ! -f "$KEY" ]; then
    "$JAVA/bin/keytool" -genkeypair -keystore "$KEY" -storepass android -keypass android -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 -dname 'CN=Android Debug,O=Android,C=US'
fi
JAVA_HOME="$JAVA" "$TOOLS/apksigner" sign --v4-signing-enabled false --ks "$KEY" --ks-pass pass:android --out "$ROOT/Sources/MBJFW/Resources/appliance.apk" "$BUILD/unsigned.apk"
