# Glance VR: your Mac's windows, floating around you on Meta Quest

Every open window on your Mac becomes its own floating panel in your Quest, with passthrough so you still see your
room. Look at a panel to select it, then use your hands: pinch to click, pinch twice to open, point to scroll, grab to
move, pinch with both hands to zoom. No controller, no mouse, no keyboard.

Built for the **Meta VR Start Developer Competition 2026** (Productivity track, New Experience).
**Demo video:** [youtube.com/watch?v=RoXALA7M2vg](https://www.youtube.com/watch?v=RoXALA7M2vg) ·
**Devpost:** [devpost.com/software/glance-vr](https://devpost.com/software/glance-vr)

```
 QUEST (Godot app, this folder)                        MAC (Glance, the Swift app in this repo)
 one floating panel per Mac window   ◀── window pictures ───   WindowRegistry + WindowStreamPool
 gaze (eyes or head) highlights one  ── window id + point ──▶   (ScreenCaptureKit, per window)
 pinch / point / grab / zoom         ── click, scroll, ... ─▶   GazeInput: brings that exact window
                                       one WebSocket :47811        forward, then real mouse and
                                       (USB cable or Wi-Fi)        scroll events land in it
```

## What you need

- A Mac with Apple silicon, macOS 13 or newer
- A Meta Quest 3, 3S or Pro (Quest Pro and Meta VR Glasses use your eyes; Quest 3 uses your head)
- A USB-C cable (or the same Wi-Fi for Mac and Quest)
- No accounts and no API keys

## Quick start

### 1. Run the Mac app

From the root of this repo (needs Xcode 16+):

```
swift run -c release Glance
```

Or double-click `Glance.command` in the repo root, or `vr/1 Start Glance on Mac.command` (USB only).
The first time, macOS asks for permissions for your terminal app. Allow them in
System Settings → Privacy & Security, then start Glance again:

- **Screen & System Audio Recording**, so the windows can be shown in the headset
- **Accessibility**, so Glance can click and scroll for you

Keep the window open while you use Glance VR.

### 2. Install the Quest app

- **Easiest:** download `GlanceVR.apk` from this repo's **Releases** page.
- **Or build it:** see [Build from source](#build-from-source) below.

Turn on developer mode for your Quest (Meta Horizon phone app → your headset → Developer mode). Then plug the Quest
into the Mac and run:

```
cd vr && zsh cable.sh install
```

This installs the app and links it to the Mac over the cable. If you have `GlanceVR.apk` somewhere else, use
`adb install -r GlanceVR.apk`. When the headset asks, accept "Allow USB debugging".

### 3. Use it

Open **Glance VR** in the headset (Library → Unknown sources). It finds your Mac by itself, over the cable or on the
same Wi-Fi, and your windows appear around you.

| Gesture | What it does |
|---|---|
| **Look** at a window | Highlights it and shows its name |
| **Left hand, short pinch** (thumb + index) | Click where you look |
| **Left hand, two quick pinches** | Open, as a double-click (e.g. a file in Finder) |
| **Point** (fist, index finger out), move up/down | Scroll the window. Flick and let go to fling |
| **Left hand, long pinch**, move up/down | Scroll too |
| **Right hand, pinch and move your hand** | Move the panel. It stays where you put it |
| **Both hands pinched**, spread apart / bring together | Zoom the window in / out |
| **Right pinch on empty space, hold 2 s** | Bring the panels back in front of you |

A small legend with these gestures shows for 12 s when the windows appear. Glowing dots on your hands show what the
headset tracks.

## Build from source

The Quest app is a Godot 4.7.2 project in [`headset/`](headset/). All its logic is in `headset/gaze.gd`.

You need:
- Godot 4.7.2, with the Android export templates
- The Android SDK
- JDK 17 (the one inside Android Studio works)

`build.sh` finds them by itself. You can also set them yourself with `GODOT=…`, `ANDROID_HOME=…` and `JAVA_HOME=…`.

```
cd vr
zsh build.sh          # → builds/GlanceVR.apk
zsh cable.sh install  # install on the plugged-in Quest
```

- **Signing:** without a key, `build.sh` makes a debug-signed APK, which works on your own headset. To upload to the
  Meta Developer Dashboard, you need a release-signed APK. Put your own key in `vr/signing/`
  (`glancevr-release.keystore` plus `keystore.env` with `GLANCEVR_KEYSTORE_PASSWORD` and `GLANCEVR_KEY_ALIAS`).
  `signing/` is in `.gitignore`. Never commit it.
- **Dashboard rules:** the Dashboard accepts target SDK 34 or lower, which `headset/export_presets.cfg` sets. Every
  new upload needs a higher version code: `zsh build.sh 4`.
- **Upload with the Meta VR CLI:**
  ```
  metavr auth login
  metavr store dist upload --app-id <your app id> --channel Competition --apk builds/GlanceVR.apk --notes "…"
  ```
- **Share one folder:** `zsh package.sh` puts the ready-to-run Mac app, the APK, [SETUP.md](SETUP.md) and all source
  into `vr/release/GlanceVR-Release.zip`. Your keys and `.env` are never copied into it.

## How it works

- **Window list:** `WindowRegistry` lists the Mac's normal windows (app, title, size, order).
- **Window pictures:** `WindowStreamPool` captures each window with ScreenCaptureKit. The window you look at streams
  live, and the others update as thumbnails, which keeps decoding on the headset within budget.
- **Panels:** the headset builds one panel per window and lets you place it. Gaze (eyes, or head on Quest 3) picks
  the panel, with a short hold so the highlight doesn't flicker.
- **Targeting:** every action carries the **window ID** and the point on it, not a mouse position. So a click or
  scroll always lands in the window you looked at, even if another window covers it on the Mac. The Mac brings that
  window forward first (`GazeInput.swift`).
- **Connection:** one WebSocket on port 47811 (`QuestHub.swift`). Over USB, `adb reverse` carries it. On Wi-Fi, the
  headset finds the Mac by broadcast. The message formats are in [../PROTOCOL.md](../PROTOCOL.md).
- **Fallback:** if a Mac doesn't send window panels, the app falls back to one panel mirroring the whole screen.

## If something doesn't work

- **"Looking for Glance on your Mac…" doesn't go away:** check that Glance is still running on the Mac. With the
  cable, run `zsh cable.sh` again after re-plugging. On Wi-Fi, both devices must be on the same network.
- **Windows are black:** Screen Recording isn't allowed for your terminal app yet. Allow it, then restart Glance.
- **Clicks or scrolls do nothing:** Accessibility isn't allowed yet.
- **Watch the headset log:** `adb logcat -s godot`

## Security

On Wi-Fi, another device on the same network could connect to Glance. Use it on your own network, or start Glance with
`GLANCE_QUEST_LAN=0` so it only accepts the USB cable. For shared networks, set a `GLANCE_QUEST_TOKEN` on both ends.

## Voice commands (optional)

Glance on the Mac can also act on what you say, with Meta Muse. That's switched off in this headset build. To turn it
on:
1. Set `TALK_ENABLED := true` in `headset/gaze.gd`. A long left pinch then becomes the talk key instead of scroll.
2. Put a `MUSE_API_KEY` in `.env` at the repo root.
