#!/bin/zsh
# Builds Glance Gaze for Quest Pro: quest/builds/GlanceGaze.apk (debug-signed).
#   zsh quest/build-apk.sh            then, with the headset plugged in:   adb install -r quest/builds/GlanceGaze.apk
set -e
cd "${0:A:h}"
GODOT="${GODOT:-$PWD/tools/godot/Godot.app/Contents/MacOS/Godot}"   # Godot 4.7.2 with its Android export templates
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
export JAVA_HOME="${JAVA_HOME:-$HOME/Library/Java/JavaVirtualMachines/jbr-17.0.14/Contents/Home}"   # JDK 17
export GODOT_ANDROID_KEYSTORE_DEBUG_PATH="$HOME/.android/debug.keystore"
export GODOT_ANDROID_KEYSTORE_DEBUG_USER=androiddebugkey
export GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD=android
mkdir -p builds
cd glance-gaze
"$GODOT" --headless --import
"$GODOT" --headless --install-android-build-template --export-debug "Quest Pro" ../builds/GlanceGaze.apk
ls -la ../builds/GlanceGaze.apk
