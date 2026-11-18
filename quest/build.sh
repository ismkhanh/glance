#!/bin/zsh
# Builds the Glance VR Quest app: quest/builds/GlanceVR.apk
#   zsh build.sh        (or: zsh build.sh 4   to set the version code; every Dashboard upload needs a higher one)
# Finds Godot 4.7, the Android SDK and JDK 17 by itself; override with GODOT=… ANDROID_HOME=… JAVA_HOME=…
# With your own release key in quest/signing/ (never committed) the APK is release-signed for the Meta Developer
# Dashboard; without it you get a debug-signed APK that installs on your own headset.
set -e
setopt nullglob
cd "${0:A:h}"

candidates=("$GODOT" "$(command -v godot 2>/dev/null || true)"
  "/Applications/Godot.app/Contents/MacOS/Godot" "$HOME/Applications/Godot.app/Contents/MacOS/Godot")
GODOT=""
for c in $candidates; do [[ -n "$c" && -x "$c" ]] && { GODOT="$c"; break; }; done
[[ -n "$GODOT" ]] || { echo "Godot 4.7 not found. Install it, or run: GODOT=/path/to/Godot zsh build.sh"; exit 1; }

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
[[ -d "$ANDROID_HOME" ]] || { echo "Android SDK not found at $ANDROID_HOME (set ANDROID_HOME)."; exit 1; }
if [[ -z "$JAVA_HOME" || ! -x "$JAVA_HOME/bin/java" ]]; then
  jbrs=("$HOME"/Library/Java/JavaVirtualMachines/*/Contents/Home "/Applications/Android Studio.app/Contents/jbr/Contents/Home")
  JAVA_HOME=""
  for j in $jbrs; do [[ -x "$j/bin/java" ]] && { JAVA_HOME="$j"; break; }; done
  [[ -n "$JAVA_HOME" ]] || JAVA_HOME="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
fi
export JAVA_HOME
[[ -x "$JAVA_HOME/bin/java" ]] || { echo "JDK 17 not found (set JAVA_HOME, e.g. to Android Studio's JBR)."; exit 1; }

EXPORT_MODE=--export-debug
if [[ -f signing/keystore.env && -f signing/glancevr-release.keystore ]]; then
  source signing/keystore.env
  export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$PWD/signing/glancevr-release.keystore"
  export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$GLANCEVR_KEY_ALIAS"
  export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$GLANCEVR_KEYSTORE_PASSWORD"
  EXPORT_MODE=--export-release
  touch signing/.gdignore
else
  echo "No release key in quest/signing/: building a debug-signed APK (fine for your own headset)."
fi
export GODOT_ANDROID_KEYSTORE_DEBUG_PATH="$HOME/.android/debug.keystore"
export GODOT_ANDROID_KEYSTORE_DEBUG_USER=androiddebugkey
export GODOT_ANDROID_KEYSTORE_DEBUG_PASSWORD=android

if [[ -n "$1" ]]; then
  perl -pi -e "s/^version\/code=\d+/version\/code=$1/" export_presets.cfg
  grep -q "^version/code=$1\$" export_presets.cfg || { echo "Could not set version code $1"; exit 1; }
fi
echo "Version code: $(grep '^version/code=' export_presets.cfg | cut -d= -f2)"
mkdir -p builds && touch builds/.gdignore
"$GODOT" --headless --path . --import || echo "(Godot import exited with an error; continuing to the export)"
"$GODOT" --headless --path . --install-android-build-template $EXPORT_MODE "Glance VR" "$PWD/builds/GlanceVR.apk"
ls -la builds/GlanceVR.apk
