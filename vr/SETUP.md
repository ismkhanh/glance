# Glance VR: setup

Your Mac's windows float around you in a Meta Quest. Look at a window to highlight it, and use your hands:
click, open, scroll, move and zoom. No controller, no mouse, no keyboard.

**You need:** a Mac with Apple silicon (macOS 13 or newer), a Meta Quest 3, 3S or Pro, and a USB-C cable.
No accounts and no API keys.

## 1. Start the Mac app

1. Double-click **`Start Glance.command`**. The first time, right-click it → **Open** → **Open**.
2. macOS asks for permissions for **Terminal**. Allow all of them in System Settings → Privacy & Security:
   - **Screen & System Audio Recording**, so the windows can be shown in the headset
   - **Accessibility**, so Glance can click and scroll for you
3. Close the window and double-click `Start Glance.command` again. **Keep this window open.**

## 2. Install the headset app

**Option A, the invite link (easiest):** open the Glance VR invite link on your phone or in the Meta Horizon app,
and install Glance VR on your Quest.

**Option B, over the cable (developer mode needed):**
1. Plug the Quest into the Mac with the USB-C cable.
2. Double-click **`Install Glance VR.command`**. In the headset, accept **"Allow USB debugging"**.
   It installs the app, links it to your Mac over the cable, and opens it.
   (Needs adb. If it says "adb not found", run `brew install android-platform-tools` once.)

## 3. Use it

Open **Glance VR** in the headset (Library → Unknown sources, if you installed it over the cable).
It finds your Mac by itself, over the cable or on the same Wi-Fi.

| What you do | What happens |
|---|---|
| **Look** at a window | It lights up. Quest Pro follows your eyes; Quest 3 follows your head (the dot in the middle of your view) |
| **Left hand, short pinch** | Click where you look |
| **Left hand, two quick pinches** | Open, as a double-click (e.g. a file in Finder) |
| **Left hand, long pinch, move hand up or down** | Scroll the window |
| **Right hand, pinch and move your hand** | Move the window panel |
| **Both hands pinched, spread apart or bring together** | Zoom the window in or out |
| **Right pinch on empty space, hold 2 s** | Bring the windows back in front of you |

## If something doesn't work

- **"Looking for Glance on your Mac…" doesn't go away:** check that `Start Glance.command` is still open. On Wi-Fi,
  the Mac and Quest must be on the same network. Or use the cable and run `Install Glance VR.command` again.
- **Windows are black:** Screen Recording isn't allowed for Terminal yet (step 1.2). Allow it, then restart Glance.
- **Clicks or scrolls do nothing:** Accessibility isn't allowed for Terminal yet (step 1.2).
- **Security note:** on Wi-Fi, another device on the same network could connect to Glance. Use it on your own
  network, or set `GLANCE_QUEST_LAN=0` before starting so it only accepts the USB cable.

## Build from source (optional)

All code is in `source/`: the Mac app (Swift, `source/mac`) and the headset app (Godot 4.7, `source/headset`).
- **Mac app:** `cd source/mac && swift run -c release Glance` (needs Xcode).
- **Headset app:** open `source/headset` in Godot 4.7.2 with the Android export set up, or see `source/scripts/build.sh`.
- **Voice commands with Meta Muse** are switched off in this build. To turn them on, set `TALK_ENABLED := true` in
  `source/headset/gaze.gd`, and put a `MUSE_API_KEY` in `source/mac/.env`.
