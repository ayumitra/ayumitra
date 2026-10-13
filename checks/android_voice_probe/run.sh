#!/bin/sh
# Requires an installed Ayumitra debug APK and an Android API33+ emulator.
# Does not grant microphone permission, capture audio, or read the vault.
set -eu
ayu_sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}}
ayu_java=${JAVA_HOME:-'/Applications/Android Studio.app/Contents/jbr/Contents/Home'}
ayu_device=${1:-emulator-5554}
ayu_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ayu_temp=$(mktemp -d)
trap 'rm -rf "$ayu_temp"' EXIT
mkdir -p "$ayu_temp/classes"
"$ayu_java/bin/javac" -source 17 -target 17 -classpath "$ayu_sdk/platforms/android-36/android.jar" -d "$ayu_temp/classes" "$ayu_source/VoiceProbe.java"
JAVA_HOME="$ayu_java" "$ayu_sdk/build-tools/36.0.0/d8" --output "$ayu_temp" --lib "$ayu_sdk/platforms/android-36/android.jar" "$ayu_temp/classes/app/ayumitra/voiceprobe/"*.class
"$ayu_sdk/build-tools/36.0.0/aapt2" link -o "$ayu_temp/probe.apk" --manifest "$ayu_source/AndroidManifest.xml" -I "$ayu_sdk/platforms/android-36/android.jar"
(cd "$ayu_temp" && zip -q probe.apk classes.dex)
JAVA_HOME="$ayu_java" "$ayu_sdk/build-tools/36.0.0/apksigner" sign --ks "$HOME/.android/debug.keystore" --ks-pass pass:android --key-pass pass:android "$ayu_temp/probe.apk"
"$ayu_sdk/platform-tools/adb" -s "$ayu_device" install -t "$ayu_temp/probe.apk"
"$ayu_sdk/platform-tools/adb" -s "$ayu_device" shell am instrument -w app.ayumitra.voiceprobe/app.ayumitra.voiceprobe.VoiceProbe > "$ayu_temp/result.log"
cat "$ayu_temp/result.log"
"$ayu_sdk/platform-tools/adb" -s "$ayu_device" uninstall app.ayumitra.voiceprobe
# Instrumentation prints a result even when a native assertion fails.
rg -q 'INSTRUMENTATION_RESULT: result=ALL_PASS' "$ayu_temp/result.log"
