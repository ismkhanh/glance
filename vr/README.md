# Glance VR

Your Mac screen floats in front of you in the headset. Look at a window, pinch your left thumb and finger, say what you
want, let go. Glance on the Mac runs it with Muse in that window. No controller, no keyboard.
(No stream? It falls back to your real screen through passthrough, after pinching its 3 corners once.)

Built for the Meta VR Start Developer Competition 2026 (Productivity track, New Experience), on top of
Glance (Meta Global AI Developer Hackathon) and Glance Gaze (`../quest/glance-gaze`).

```
 Quest (Godot + OpenXR)                              Mac (Glance app)
 virtual Mac screen panel   ◀── JPEG frames ──      ScreenStream: main display
 eye gaze (Quest Pro)       ── gaze + talk ──▶      GazeInput: pointer follows your gaze
 or head gaze (Quest 3/3S)   one WebSocket          Muse Voice Transcribe + Muse Spark act in that window
 left pinch = talk           (found automatically)  left pinch = talk key
```

## Install (two apps, no setup)

1. **Mac:** open the **Glance** app. That's it — it listens for the headset by itself.
   (From source: double-click `Glance.command`, or `swift run -c release Glance`.)
   macOS will ask once for Screen Recording, Microphone, Accessibility and Input Monitoring.
2. **Quest:** install **Glance VR** and open it (Library → Unknown sources):
   - from the store / your release channel, or
   - from this repo: `zsh build.sh` once, then plug in the headset and `zsh cable.sh install`.

Then put the headset on. Your Mac screen floats in front of you — the headset finds the Mac
by itself on the same Wi-Fi, or over the USB cable if you plugged one in. Look at a window:
the Mac pointer follows your gaze. Pinch your left thumb and finger and hold, talk, let go.
The dot turns green while Glance listens. Right pinch and hold 2 s: bring the screen in front of you again.

There are no addresses to type, no tokens to set, and nothing baked into the app: it contains
no Mac address, so the same APK works on any Mac and any network.

## Optional extras (not needed for normal use)

- **Shared/public Wi-Fi:** start Glance with `GLANCE_QUEST_TOKEN=<a word>` and set the same word as
  `quest_token` on the headset app's root node in Godot before building. Without a token, anyone on
  the Wi-Fi who connects could open shells on the Mac — use a token there, or the USB cable.
- **Discovery blocked by the router:** set `mac_address` on the headset app's root node in Godot
  to your Mac's address before building. (USB always works without this.)
- **USB only:** start Glance with `GLANCE_QUEST_LAN=0`, and run `zsh cable.sh` after plugging in.
  It routes the headset's `127.0.0.1:47811` to this Mac with `adb reverse`.

## Upload for the competition

Developer Dashboard → your app → release channel named **Competition** → upload `builds/GlanceVR.apk` →
create an invite URL for the judges. Every new upload needs a higher version code: `zsh build.sh 2`.

## Signing key

`signing/glancevr-release.keystore` and its password in `signing/keystore.env`. Keep a backup: future updates of
`com.seniormobiledev.glancevr` must be signed with the same key. Never commit or share them.
