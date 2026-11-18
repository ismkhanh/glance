# Glance Quest Desk (Quest Pro)

Your Mac, floating in the room. A big panel streams your Mac screen. Under it, terminal panels
are real shells running on your Mac. Turn your head to face one, hold an index pinch and speak,
and let go: your words are transcribed on the Mac and run in that shell. A quick pinch tap on the
“+ New terminal” tile opens another shell. Your eyes still move the Mac pointer when you look at
the streamed screen, so the Glance glow follows.

Design and protocol: [docs/specs/0001-quest-desk.md](../../docs/specs/0001-quest-desk.md) and
[PROTOCOL.md](../../PROTOCOL.md) (Quest Desk section).

Built on Godot 4.7.2 and Godot OpenXR Vendors 5.1.0. Eye gaze comes from OpenXR
`XR_EXT_eye_gaze_interaction` (Quest Pro, eye tracking on). Hand pinch reads as the trigger value
with hand tracking; a controller trigger works the same way.

## Run it — two steps

1. **On the Mac: launch Glance.** Double-click `Glance.command` in the Glance folder (or run
   `swift run -c release Glance` there) and keep that window open. Same Wi-Fi as the headset.
   Allow Screen Recording, Accessibility and Microphone when macOS asks — that is the only
   setup. Voice uses `MUSE_API_KEY` in `.env` if present; without it, terminals, the screen
   and floating windows still work.
2. **On the Quest: open Glance Gaze** (Library → Unknown sources). It finds your Mac by itself
   and connects; allow eye tracking and the microphone when asked. Done.

### Only if you are building the Quest app yourself

The APK is already built for reviewers. To rebuild it: `zsh quest/build-apk.sh`, then
`adb install -r quest/builds/GlanceGaze.apk` with the headset plugged in. One-time build needs:
the Godot 4.7.2 editor in `quest/tools/godot/Godot.app` (or `GODOT=<path>`), its Android export
templates, Godot OpenXR Vendors 5.1.0 in `quest/glance-gaze/addons/godotopenxrvendors/`, the
Android SDK and JDK 17.

### Advanced (never needed for a review)

- Shared Wi-Fi you do not trust: a connection can open shells on the Mac, so set
  `GLANCE_QUEST_TOKEN=<a word>` when launching Glance and the same word as `quest_token` on the
  Main node in the Quest project, then rebuild the APK. Or `GLANCE_QUEST_LAN=0` for USB only
  (`adb reverse tcp:47811 tcp:47811`, and set `mac_address` to `127.0.0.1` on the Main node).
- `--no-quest` turns Quest Desk off; `--quest <port>` / `--gaze <port>` change ports;
  `mac_address` on the Main node skips discovery (development only).

## Use it

- A terminal opens by itself on connect. Face it until it lights up.
- Hold a pinch and speak the command as you would type it (for example “git status”).
  Let go to run it. Start with “type” to dictate text without running it.
- Say “control c”, “enter”, “tab”, or “escape” on their own to send that key.
- Quick tap (short pinch, under about a third of a second) on the “+ New terminal” tile: new shell.
- Look at the big screen panel: the violet dot is your eye point, and the Mac pointer follows it.
- Shells keep running on the Mac if the headset disconnects. Reconnecting shows recent output again.
- Floating windows (on automatically): each Mac window
  is its own panel where the window sits on the screen. Look at one: left pinch talks to it, right
  pinch clicks (hold it to drag inside it). Pinch the orange grip at its bottom-right corner and
  drag to zoom the panel in or out (its shape stays the window's; the Mac window does not resize),
  or pinch the bar at the bottom-centre and drag to move the panel in the room. Let go to set it.
  Dragged places and sizes stay yours — the Mac only changes a panel's shape after that.

## Limits today

- Panel text is plain: full screen apps such as vim or top render poorly. Line shells work well.
- Speech runs at once in the faced shell. Check the “Heard: …” line; it shows exactly what ran.
- The stream is JPEG at about 8 frames a second. Fine for reading, not for video.
- `gaze.gd` is the older passthrough only app (point at the real screen). `desk.gd` is the app
  in `main.tscn` now; the old script is kept for reference.
