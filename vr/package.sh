#!/bin/zsh
# Puts everything for Glance VR into ONE folder, ready to share: ~/MetaAICompetition/GlanceVR-Release (+ .zip).
#   zsh GlanceVR/package.sh        (run after the final build.sh, so the newest APK goes in)
# Inside: the Mac app (ready to run), the headset APK, two double-click starters, SETUP.md, and all source code.
# Never copied: your Muse key (.env), the signing key (signing/), build caches, demo videos.
set -e
cd "${0:A:h}"
# The Mac app is the Swift package one level up (this repo), or ../Glance next to a separate GlanceVR folder.
MAC="$PWD/.."; [[ -f "$MAC/Package.swift" ]] || MAC="$PWD/../Glance"
ROOT="$PWD/release"
mkdir -p "$ROOT"
OUT="$ROOT/GlanceVR-Release"
[[ -f builds/GlanceVR.apk ]] || { echo "No APK yet: run zsh GlanceVR/build.sh first"; exit 1; }

echo "Building the Mac app (release)…"
(cd "$MAC" && swift build -c release)
BIN="$(cd "$MAC" && swift build -c release --show-bin-path)/Glance"
[[ -x "$BIN" ]] || { echo "Mac app not found at $BIN"; exit 1; }

mkdir -p "$OUT/mac" "$OUT/source/mac" "$OUT/source/headset" "$OUT/source/scripts"
cp "$BIN" "$OUT/mac/Glance"
cp builds/GlanceVR.apk "$OUT/GlanceVR.apk"
cp SETUP.md "$OUT/SETUP.md"
cp PROJECT.md "$OUT/PROJECT.md"
rsync -a --exclude .build --exclude .git --exclude .env --exclude demo --exclude quest --exclude results \
  --exclude node_modules --exclude .DS_Store --exclude '*.command' --exclude vr "$MAC/" "$OUT/source/mac/"
rsync -a --exclude .godot --exclude android --exclude .DS_Store headset/ "$OUT/source/headset/"
cp build.sh build-common.sh cable.sh README.md "$OUT/source/scripts/" 2>/dev/null || true

cat > "$OUT/Start Glance.command" <<'CMD'
#!/bin/zsh
# Starts Glance on this Mac. Keep this window open while you use Glance VR.
cd "$(dirname "$0")/mac"
xattr -d com.apple.quarantine ./Glance 2>/dev/null || true
./Glance
CMD
cat > "$OUT/Install Glance VR.command" <<'CMD'
#!/bin/zsh
# With the Quest plugged in (developer mode on): installs Glance VR, links it to this Mac over the cable, opens it.
cd "$(dirname "$0")"
ADB=adb
command -v adb >/dev/null || ADB="$HOME/Library/Android/sdk/platform-tools/adb"
command -v "$ADB" >/dev/null || [[ -x "$ADB" ]] || { echo "adb not found. Install it: brew install android-platform-tools"; read; exit 1; }
"$ADB" start-server >/dev/null 2>&1
for i in {1..20}; do
  "$ADB" get-state 2>/dev/null | grep -q device && break
  echo "Waiting for the headset: put it on and accept 'Allow USB debugging' ($i/20)…"; sleep 3
done
"$ADB" get-state 2>/dev/null | grep -q device || { echo "No headset found. Re-plug the cable and try again."; read; exit 1; }
"$ADB" install -r GlanceVR.apk
"$ADB" reverse tcp:47811 tcp:47811
ACT=$("$ADB" shell cmd package resolve-activity --brief com.seniormobiledev.glancevr | tail -1 | tr -d '\r')
"$ADB" shell am start -n "$ACT" >/dev/null
echo "Glance VR is open on the headset. Put it on."
read
CMD
chmod +x "$OUT/Start Glance.command" "$OUT/Install Glance VR.command" "$OUT/mac/Glance"

(cd "$ROOT" && rm -f GlanceVR-Release.zip && zip -qry GlanceVR-Release.zip GlanceVR-Release)
echo
echo "Done: $OUT"
echo "      $ROOT/GlanceVR-Release.zip ($(du -h "$ROOT/GlanceVR-Release.zip" | cut -f1))"
grep -rl "MUSE_API_KEY=" "$OUT" 2>/dev/null | grep -v example && echo "WARNING: a file above contains a Muse key line" || true
