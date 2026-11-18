#!/bin/zsh
# Builds both apps and makes dist/GlanceVR-<version>.zip to share: the Mac app, the Quest APK and a short README.
#   zsh package.sh          keeps the version name, raises the version code by 1
#   zsh package.sh 1.1      sets the version name to 1.1
# Needs Xcode, plus what quest/build.sh needs: Godot 4.7, the Android SDK and JDK 17.
# Put your release key in quest/signing/ (never committed) so the APK is release-signed.
set -e
cd "${0:A:h}"
PRESETS=quest/export_presets.cfg
VERSION="${1:-$(sed -n 's/^version\/name="\(.*\)"/\1/p' $PRESETS)}"
CODE=$(( $(sed -n 's/^version\/code=//p' $PRESETS) + 1 ))

echo "== Quest app: version $VERSION, version code $CODE =="
perl -pi -e "s/^version\/name=\".*\"/version\/name=\"$VERSION\"/" $PRESETS
zsh quest/build.sh $CODE
APK=quest/builds/GlanceVR.apk
[[ -f "$APK" ]] || { echo "The Quest build made no APK."; exit 1; }

echo "== Mac app: Apple silicon and Intel =="
if (cd mac && swift build -c release --arch arm64 --arch x86_64); then
  BIN="mac/.build/apple/Products/Release/GlanceVR"
else
  echo "Universal build failed, so building for this Mac only."
  (cd mac && swift build -c release)
  BIN="mac/.build/release/GlanceVR"
fi

OUT="dist/GlanceVR-$VERSION"
rm -rf "$OUT" "$OUT.zip"
mkdir -p "$OUT/Mac" "$OUT/Quest"
cp "$BIN" "$OUT/Mac/GlanceVR"
codesign --force -s - "$OUT/Mac/GlanceVR"      # ad-hoc signature, so it runs on Apple silicon
cp "$APK" "$OUT/Quest/GlanceVR.apk"

cat > "$OUT/Mac/Start Glance VR.command" <<'CMD'
#!/bin/zsh
cd "${0:A:h}"
exec ./GlanceVR
CMD

cat > "$OUT/Quest/Install on Quest.command" <<'CMD'
#!/bin/zsh
# Installs Glance VR on the plugged-in Quest, links it to this Mac over USB, and opens it.
cd "${0:A:h}"
ADB=adb
command -v adb >/dev/null || ADB="$HOME/Library/Android/sdk/platform-tools/adb"
if [[ "$ADB" != adb && ! -x "$ADB" ]]; then
  echo "adb not found. Install it with:  brew install --cask android-platform-tools"
  echo "Or drag GlanceVR.apk into SideQuest or Meta Quest Developer Hub."
  exit 1
fi
set -e
"$ADB" devices
"$ADB" install -r GlanceVR.apk
"$ADB" reverse tcp:47811 tcp:47811
"$ADB" shell monkey -p com.seniormobiledev.glancevr -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
echo "Installed and opened Glance VR. Put the headset on."
CMD
chmod +x "$OUT/Mac/GlanceVR" "$OUT/Mac/Start Glance VR.command" "$OUT/Quest/Install on Quest.command"

cat > "$OUT/README.txt" <<TXT
GLANCE VR $VERSION

Your Mac's windows float around you on Meta Quest.
Look at a spot: the Mac pointer moves there. Pinch to click.

Demo:  https://www.youtube.com/watch?v=RoXALA7M2vg
Code:  https://github.com/ismkhanh/GlanceVR


WHAT'S INSIDE
  Mac/Start Glance VR.command      double-click to start the Mac app
  Mac/GlanceVR                     the Mac app itself
  Quest/GlanceVR.apk               the Quest app
  Quest/Install on Quest.command   installs the APK over a USB cable

YOU NEED
  - a Mac with macOS 14 (Sonoma) or newer
  - a Meta Quest 3, 3S or Pro, with Developer Mode on
    (Meta Horizon app on your phone > your headset > Developer Mode)
  - the Mac and the Quest on the same Wi-Fi, or a USB-C cable


1. UNBLOCK THE FILES (once)
   macOS blocks apps downloaded from the internet. Open Terminal and run:

       xattr -dr com.apple.quarantine ~/Downloads/GlanceVR-$VERSION

   Change the path if you unzipped it somewhere else.

2. START THE MAC APP
   Double-click  Mac/Start Glance VR.command . A Terminal window opens.
   The first time, macOS asks for two permissions for Terminal.
   Allow both in System Settings > Privacy & Security:
     - Screen & System Audio Recording   (to show your windows)
     - Accessibility                     (to click and scroll)
   Then close the Terminal window and double-click the file again.
   Keep it open while you use the headset.

3. INSTALL THE QUEST APP (once). Pick one:
   a) Plug the Quest into the Mac and double-click  Quest/Install on Quest.command .
      In the headset, allow USB debugging if it asks.
      This needs adb:  brew install --cask android-platform-tools
   b) Or drag  Quest/GlanceVR.apk  into SideQuest or Meta Quest Developer Hub.

4. OPEN IT
   Option a) opens it for you. Otherwise, in the headset:
   App Library > filter (top right) > Unknown Sources > Glance VR.
   It finds your Mac by itself (cable or Wi-Fi), and your windows appear around you.


GESTURES
  Look at a spot                     the Mac pointer moves there
  Left pinch                         click
  Left pinch twice                   open (double-click)
  Point (index finger out) + swipe   scroll, like a phone. Moving back doesn't scroll,
                                     so swipe again and again. Flick to fling.
  Open your hand, then point again   change the scroll direction
  Left pinch, hold, move up/down     scroll both ways; let go to stop
  Right pinch + move your hand       move the panel
  Both hands pinch, spread / close   zoom in / out
  Right palm toward you + pinch      Quest menu > Quit, to close the app

TO STOP THE MAC APP
  Press Ctrl+C in its Terminal window, or close the window.

IF SOMETHING DOESN'T WORK
  Panels are black          allow Screen Recording for Terminal, then restart the Mac app
  Clicks do nothing         allow Accessibility for Terminal
  "Looking for Glance" stays
                            is the Mac app running? Same Wi-Fi? Some office and guest
                            Wi-Fi networks block devices from seeing each other:
                            use the USB cable (step 3a) instead.

SECURITY
  On Wi-Fi, other devices on the same network could connect to the Mac app.
  On shared Wi-Fi, use the cable and start the Mac app in Terminal with:
      GLANCE_QUEST_LAN=0 ./GlanceVR
TXT

(cd dist && ditto -c -k --keepParent "GlanceVR-$VERSION" "GlanceVR-$VERSION.zip")
echo "Mac app: $(lipo -archs "$OUT/Mac/GlanceVR")"
echo "Quest app: version $VERSION, version code $CODE"
echo "Done: $PWD/dist/GlanceVR-$VERSION.zip ($(du -h "dist/GlanceVR-$VERSION.zip" | cut -f1))"
