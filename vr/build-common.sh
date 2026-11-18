#!/bin/zsh
# Shared build setup for build.sh / build-mirror.sh: finds Godot, JDK 17 and the Android SDK
# wherever they are installed. Nothing machine-specific is written into the app: the Quest
# app finds the Mac by itself at runtime, and normal use needs no token (see README).
# Overrides if auto-detection guesses wrong: GODOT=/path/to/Godot JAVA_HOME=/path/to/jdk zsh build.sh
set -e
setopt nullglob
cd "${0:A:h}"

# --- Godot ---
candidates=(
  "$GODOT"
  "$(command -v godot 2>/dev/null || true)"
  "$PWD/../quest/tools/godot/Godot.app/Contents/MacOS/Godot"
  "$PWD/../../quest/tools/godot/Godot.app/Contents/MacOS/Godot"
  "/Applications/Godot.app/Contents/MacOS/Godot"
  "$HOME/Applications/Godot.app/Contents/MacOS/Godot"
)
GODOT=""
for c in $candidates; do [[ -n "$c" && -x "$c" ]] && { GODOT="$c"; break; }; done
[[ -n "$GODOT" ]] || { echo "Godot not found. Install Godot 4.x, or run: GODOT=/path/to/Godot zsh build.sh"; exit 1; }

# --- Android SDK + JDK 17 ---
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
[[ -d "$ANDROID_HOME" ]] || { echo "Android SDK not found at $ANDROID_HOME (set ANDROID_HOME)."; exit 1; }
if [[ -z "$JAVA_HOME" || ! -x "$JAVA_HOME/bin/java" ]]; then
  jbrs=("$HOME"/Library/Java/JavaVirtualMachines/*/Contents/Home "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
  JAVA_HOME=""
  for j in $jbrs; do [[ -x "$j/bin/java" ]] && { JAVA_HOME="$j"; break; }; done
  [[ -n "$JAVA_HOME" ]] || JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
fi
export JAVA_HOME
[[ -x "$JAVA_HOME/bin/java" ]] || { echo "JDK 17 not found (set JAVA_HOME to your Android Studio JBR)."; exit 1; }

# --- Signing ---
# With your own release key in signing/ (glancevr-release.keystore + keystore.env, never committed) the APK is
# release-signed for the Meta Developer Dashboard. Without it, you get a debug-signed APK for your own headset.
EXPORT_MODE=--export-debug
if [[ -f signing/keystore.env && -f signing/glancevr-release.keystore ]]; then
  source signing/keystore.env
  export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$PWD/signing/glancevr-release.keystore"
  export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$GLANCEVR_KEY_ALIAS"
  export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$GLANCEVR_KEYSTORE_PASSWORD"
  EXPORT_MODE=--export-release
else
  echo "No release key in signing/: building a debug-signed APK (fine for your own headset, not for the Dashboard)."
fi
export GODOT_ANDROID_KEYSTORE_DEBUG_PATH="$HOME/.android/debug.keystore"
export GODOT_ANDROID_KEYSTORE_DEBUG_USER=androiddebugkey
export GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD=android

# build_apk <project_dir> <output_apk> [version_code]
build_apk() {
  local project="$1" out="$2"
  if [[ -n "$3" ]]; then
    perl -pi -e "s/^version\/code=\d+/version\/code=$3/" "$project/export_presets.cfg"
    grep -q "^version/code=$3\$" "$project/export_presets.cfg" || { echo "Could not set version code $3"; exit 1; }
  fi
  echo "Version code: $(grep '^version/code=' "$project/export_presets.cfg" | cut -d= -f2)"
  mkdir -p builds
  ( cd "$project"
    "$GODOT" --headless --import || echo "(Godot import exited with an error; continuing to the export)"
    "$GODOT" --headless --install-android-build-template $EXPORT_MODE "Glance VR" "../$out" )
  ls -la "$out"
  local signers=($ANDROID_HOME/build-tools/*/apksigner)
  if (( ${#signers} )); then "${signers[-1]}" verify --print-certs "$out" | grep -m1 "certificate DN" || true; fi
}
