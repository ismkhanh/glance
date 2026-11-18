#!/bin/zsh
# Double-click with the headset plugged in: installs the latest Glance VR build, connects it to this Mac over the
# cable, opens it on the headset, then shows its log. Keep this window open.
cd "$(dirname "$0")"
ADB=adb
command -v adb >/dev/null || ADB="$HOME/Library/Android/sdk/platform-tools/adb"
APK="${APK:-builds/GlanceVR.apk}"
"$ADB" start-server >/dev/null 2>&1
for i in {1..20}; do
  "$ADB" get-state 2>/dev/null | grep -q device && break
  echo "Waiting for the headset: put it on and accept 'Allow USB debugging' ($i/20)…"
  sleep 3
done
"$ADB" get-state 2>/dev/null | grep -q device || { echo "No headset found. Re-plug the cable, then double-click this again."; read; exit 1; }
echo "Installing $APK…"
"$ADB" install -r "$APK" || { echo "Install failed (see above)."; read; exit 1; }
"$ADB" reverse tcp:47811 tcp:47811
ACT=$("$ADB" shell cmd package resolve-activity --brief com.seniormobiledev.glancevr | tail -1 | tr -d '\r')
"$ADB" shell am force-stop com.seniormobiledev.glancevr
"$ADB" shell am start -n "$ACT"
echo
echo "Glance VR is open on the headset. Put it on. Its log follows (close this window to stop watching):"
"$ADB" logcat -c
"$ADB" logcat -s godot
