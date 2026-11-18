# Glance VR

Use your Mac's windows on Meta Quest. Each window floats as its own panel in passthrough.

**Your gaze is the mouse pointer.** Look at a spot in any window, and the Mac's real pointer moves there.
Pinch to click. No controller, no mouse, no trackpad.

```
 you look at a button  ──▶  a dot shows where you look  ──▶  the Mac pointer moves there  ──▶  pinch = click
```

Gaze uses your eyes on headsets with eye tracking (Quest Pro). On Quest 3 and 3S it uses where your head points.

**▶ [Demo video, with voice-over](https://drive.google.com/file/d/1191OzuXehWlh-NBVggnMJ2hClgezLVX5/view?usp=sharing)** · [First demo (YouTube Short)](https://www.youtube.com/watch?v=RoXALA7M2vg) · [Devpost](https://devpost.com/software/glance-vr) · Meta VR Start Developer Competition 2026

**⬇ [Download Glance VR 1.1](https://drive.google.com/file/d/1KMEfrkouewF5pCpsz-SzJb7hdMNLOSG3/view?usp=sharing)**: the Mac app and the Quest APK in one zip, with a `README.txt` that walks you through it. No build tools needed.

## Project layout

```
GlanceVR/
├── mac/          Mac app (Swift): streams windows to the headset, runs clicks and scrolls
├── quest/        Quest app (Godot 4.7 + OpenXR): panels, gaze, hand gestures
└── PROTOCOL.md   every message between the two apps
```

## How it works

```
          MAC  (mac/)                                     QUEST  (quest/)
 ┌─────────────────────────┐   window list + JPEG   ┌──────────────────────────┐
 │ WindowRegistry          │ ─────────────────────▶ │ one floating panel per   │
 │ WindowStreamPool        │                        │ window                   │
 │                         │                        │                          │
 │ GazeInput               │ ◀───────────────────── │ gaze = where to point    │
 │ moves the real pointer, │  gaze: 30 times a sec  │ hand = what to do        │
 │ then clicks / scrolls   │  click, scroll, drag   │                          │
 │                         │  (window ID + x, y)    │                          │
 └─────────────────────────┘                        └──────────────────────────┘
              WebSocket on port 47811 (USB cable, or the same Wi-Fi)
```

1. **Mac → Quest:** the Mac sends the list of open windows and a picture of each one. The window you look at streams live, about 8 frames a second. The others refresh as stills.
2. **Quest:** shows each window as a panel, and finds the panel and the spot you look at.
3. **Quest → Mac, gaze:** about 30 times a second, the Quest sends where you look, e.g. `{"type":"gaze","window":42,"x":0.4,"y":0.7}`. That is the window ID and the point inside it, from 0 to 1. The Mac moves its real pointer to that spot. It smooths the movement so the pointer doesn't shake.
4. **Quest → Mac, gesture:** a pinch sends `{"type":"click","window":42,"x":0.4,"y":0.7}`. The Mac brings window 42 to the front and clicks at that spot.

### Main files

| Mac (`mac/Sources/GlanceVR/`) | Job |
|---|---|
| `QuestHub.swift` | WebSocket server (port 47811) and Wi-Fi discovery (UDP 47812) |
| `WindowRegistry.swift` | Keeps the list of open windows, up to 8 |
| `WindowStreamPool.swift` | Captures windows with ScreenCaptureKit |
| `GazeInput.swift` | Moves the real pointer to where you look, and posts clicks, double-clicks, scrolls and drags |

| Quest (`quest/`) | Job |
|---|---|
| `gaze.gd` | All app logic: connection, panels, gaze ray, hand gestures |
| `addons/` | Godot OpenXR Vendors plugin (passthrough, hands, eye tracking) |

## Gestures

| Gesture | Action |
|---|---|
| Look at a spot | The Mac pointer moves there, and the panel is selected |
| Left pinch | Click |
| Left pinch twice | Open (double-click) |
| Point (index finger out) + swipe up or down | Scroll, like a phone. Moving back doesn't scroll, so you can swipe again and again. Flick to fling. The hand turns green while it scrolls |
| Open your hand, then point again | Change the scroll direction |
| Left pinch, hold, move up/down | Scroll both ways, like dragging the page. Let go to stop |
| Right pinch + move hand | Move the panel |
| Both hands pinch, spread / close | Zoom in / out |
| Right pinch on empty space, hold 2 s | Recenter the panels |

## Setup and run

**Quickest way:** download [GlanceVR-1.1.zip](https://drive.google.com/file/d/1KMEfrkouewF5pCpsz-SzJb7hdMNLOSG3/view?usp=sharing), unzip it, and follow `README.txt` inside. You double-click two files.

**From source:**

**You need:**
- a Mac with macOS 14 or newer and Xcode 16+
- a Meta Quest 3, 3S or Pro with developer mode on
- a USB-C cable

**1. Start the Mac app**
```
cd mac
swift run -c release GlanceVR
```
- The first time, macOS asks for **Screen Recording** and **Accessibility** for your terminal app.
- Allow both, then run the command again.

**2. Install the Quest app** (headset plugged in)
```
cd quest
APK=path/to/GlanceVR.apk zsh cable.sh install
```
- Get the APK from [GlanceVR-1.1.zip](https://drive.google.com/file/d/1KMEfrkouewF5pCpsz-SzJb7hdMNLOSG3/view?usp=sharing) (`Quest/GlanceVR.apk`).
- Or build it yourself: `zsh build.sh` (needs Godot 4.7.2, the Android SDK and JDK 17).

**3. Put the headset on.** `cable.sh` opens Glance VR for you, and your windows appear around you.
- To open it again later, run `zsh cable.sh`.
- Or in the headset: **App Library → filter (top right) → Unknown Sources → Glance VR**.

**Make a zip to share** (builds both apps, plus a README for the person you send it to):
```
zsh package.sh 1.1      # → dist/GlanceVR-1.1.zip
```

**If something goes wrong:**
- **Black panels:** allow Screen Recording.
- **Clicks do nothing:** allow Accessibility.
- **Stuck on "Looking for Glance":** check the Mac app is running, then run `zsh quest/cable.sh` again.

> **Security:** on shared Wi-Fi, start the Mac app with `GLANCE_QUEST_LAN=0`. It then accepts the USB cable only.

## License

MIT
