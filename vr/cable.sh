#!/bin/zsh
# Installs Glance VR on a plugged-in headset. Wi-Fi needs no cable at all (the headset finds
# the Mac by itself); the cable route is the fallback and also charges the headset.
#   zsh cable.sh install    install the latest build, then set up the USB route
#   zsh cable.sh            just set up the USB route again (after re-plugging)
set -e
cd "${0:A:h}"
ADB=adb
command -v adb >/dev/null || ADB="$HOME/Library/Android/sdk/platform-tools/adb"
"$ADB" devices
if [[ "$1" == "install" ]]; then
  [[ -f builds/GlanceVR.apk ]] || { echo "No build yet: run zsh build.sh first"; exit 1; }
  "$ADB" install -r builds/GlanceVR.apk
fi
"$ADB" reverse tcp:47811 tcp:47811
"$ADB" reverse --list
echo "Next: open the Glance app on the Mac, then open Glance VR in the headset (Library > Unknown sources)."
