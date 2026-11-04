# Glance Gaze (Quest Pro)

Your eyes point at your Mac's screen (seen through passthrough), and the point you look at goes to Glance on the Mac
over Wi-Fi, where it moves the pointer. Glance's glow, "this" and the talk key then follow your eyes.

Built on Godot 4.7.2 and Godot OpenXR Vendors 5.1.0 (Meta's passthrough sample was the starting point). Eye gaze comes
from OpenXR `XR_EXT_eye_gaze_interaction`, which Quest Pro supports with eye tracking on.

1. On the Mac: `swift run -c release Glance --gaze 47810` (from the Glance folder). Set `mac_address` in `gaze.gd` to the
   Mac's Wi-Fi address (`ipconfig getifaddr en0`); both must be on the same network.
2. Build: `zsh quest/build-apk.sh`. It needs, once:
   - the Godot 4.7.2 editor in `quest/tools/godot/Godot.app` (or `GODOT=<path to the Godot binary>`), with its Android
     export templates installed;
   - Godot OpenXR Vendors 5.1.0 unzipped into `quest/glance-gaze/addons/godotopenxrvendors/` (from its GitHub releases
     or the Asset Library);
   - the Android SDK and JDK 17 from Android Studio (`ANDROID_HOME`, `JAVA_HOME`), and the Android debug keystore.

   It writes `quest/builds/GlanceGaze.apk` (debug-signed, arm64, Quest 2/3/3S/Pro).
   Install with the headset in developer mode and plugged in: `adb install -r quest/builds/GlanceGaze.apk`, then open
   it from Library → Unknown sources.
3. In the headset: allow eye tracking when asked. Touch the right controller's tip (green dot) to the screen's top-left,
   top-right and bottom-left corners, pulling the trigger at each. The violet dot shows where you look.
