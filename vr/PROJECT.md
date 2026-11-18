# Glance VR: project brief

**In one line:** put on a Meta Quest, look at a window on your Mac, pinch, and say what you want. An AI agent (Meta Muse) does it in that window. No controller, no keyboard, no mouse.

**Entry:** Meta VR Start Developer Competition 2026. Productivity track, New Experience division.
**Deadline:** 18 Nov 2026, 12:00 PM PST (00:00 on 19 Nov in Dubai).

---

## 1. The problem

People who work with AI all day keep many windows open at once: coding agents in several terminals, a browser, music, documents. Talking to any one of them still starts with clicks. You find the window, click into it, click the right field, and only then type or dictate.

In a VR headset this is even harder, because you can't see your mouse and keyboard well.

## 2. What we want to achieve

- **Your Mac in the headset.** The Mac screen floats in front of you as a large panel, with passthrough around it so you still see your room.
- **Point by looking.** On Quest Pro and Meta VR Glasses you point with your eyes. On Quest 3 you point with your head, with a small dot in the middle of your view.
- **See your target.** The window you look at glows, so you always know which window you will talk to.
- **Pinch to talk.** Pinch your left thumb and index finger, say what you want, and let go. Glance does it in that window: it runs a command in a terminal, opens a browser tab, or pauses the music.
- **Hands only.** Everything works without a controller, which is a competition rule.

**Success tonight:**
- this loop works on a real Quest
- it's shown in a demo video under 3 minutes
- the APK is uploaded to the "Competition" release channel
- the Devpost form is submitted before the deadline

## 3. How it works

```
   QUEST HEADSET (Godot app)                 USB cable              MAC (Glance app)
 ┌──────────────────────────────┐     one WebSocket, port 47811    ┌───────────────────────────────┐
 │ Panel showing the Mac screen │ ◀── screen pictures (8 a second) │ ScreenStream: copies the      │
 │                              │                                  │ main display                  │
 │ Head / eye ray hits panel    │ ── point (x, y) + "talking" ──▶  │ GazeInput: moves the real     │
 │ → violet dot                 │                                  │ pointer there                 │
 │ Left pinch held → green dot  │                                  │ Glow on the window under it   │
 └──────────────────────────────┘                                  │ Muse Voice Transcribe: words  │
                                                                   │ Muse Spark: acts in window    │
                                                                   └───────────────────────────────┘
```

Step by step:

1. **A ray from your head.** The headset draws an invisible line from your head (or eyes) and finds where it hits the panel, for example "70% across, 53% down".
2. **Send the point.** That point goes to the Mac over the cable.
3. **The Mac knows the window.** It moves its real pointer to the same spot. The panel is an exact copy of the screen, so the pointer lands on the window you are looking at. Glance puts a glow around that window, and you see the glow in the headset too.
4. **Pinch and talk.** While you hold the left pinch, Glance listens through the Mac microphone. When you let go, Muse turns your words into actions in the glowing window.

**Key idea:** the headset never needs to know about windows. It only says *where* you look. The Mac already knows *what* is there.

## 4. What we reused and what is new

**Reused (built for the Meta Global AI Developer Hackathon, Oct–Nov 2026):**

| Part | What it does |
| --- | --- |
| Glance (Mac, Swift) | Talk to the window under the pointer. Muse Spark acts in the window, Muse Voice Transcribe hears you, and a glow shows the target. |
| Glance Gaze (Quest, Godot) | Passthrough, hand pinch, eye or head gaze, and the 3-corner calibration of a real screen. |
| Quest Desk, Mac side (Swift) | `ScreenStream` (screen pictures) and `QuestHub` (WebSocket server), from the 5 Nov spec. |

**New tonight:**
- Headset: the Mac screen as a floating panel, gaze on the panel, and the left-pinch talk key, steadied so short tracking gaps don't cut your sentence.
- One cable link for everything: screen, point and pinch over a single WebSocket, carried by `adb reverse`.
- Mac: the glow shows while you look, before you pinch. Glance also stops listening if the headset disconnects.
- Clear status messages in the headset: looking for the Mac, connected, Mac errors, listening.
- A release-signed build (`com.seniormobiledev.glancevr`), with `build.sh` and `cable.sh`.

## 5. Scope

**Tonight:**
- One panel that mirrors the Mac's main display
- One monitor
- USB cable
- Glance running on the Mac

**Next (say it in the video and on Devpost):**
- **One floating panel per window.** New apps open as new panels you can place around you.
- Multiple monitors.
- Wi-Fi with no setup.
- The headset microphone instead of the Mac microphone.
- On-device, open-weight models.
- A demo mode that works without a Mac.

## 6. Why we chose this design

| Choice | Why | What we gave up |
| --- | --- | --- |
| One mirrored panel, not one panel per window | Exact and already built. Per-window panels need one stream per window. Glance acts on the window under the Mac pointer, so a window hidden behind another on the Mac would get the wrong command. | Windows can't be placed around you yet |
| Cable instead of Wi-Fi | No network setup. `adb reverse` carries one connection for everything. | You stay plugged in (but the headset also charges) |
| Reuse the Godot app instead of a new Compose app | Working code beats a new stack with hours left | Kotlin/Compose would have been more familiar |
| The Mac does the window work | macOS already knows every window. The headset stays simple. | The Mac app must run |
| Mac microphone for voice | Already built and tested in Glance | You need to be near the Mac |

## 7. How it fits the judging

- **Hands-first:** pinch to talk, pinch to move the panel, no controller anywhere.
- **Seated, easy in and out:** open the app and your Mac is there, with no calibration.
- **Technical:** hand tracking, gaze interaction (eyes or head), passthrough around the panel, and a panel placed and tilted for your field of view.
- **Special awards to aim for:** Best Agentic Interaction (Muse acts in the window you look at), and Best Accessibility Forward Experience (hands-free computer control).

## 8. Known limits (say them honestly)

- It needs Glance running on the Mac, with a Muse key. A judge who has only the APK sees a clear message, so the video shows the full loop.
- Quest 3 points with your head. Quest Pro and Meta VR Glasses use your eyes.
- Text on the panel is a bit soft, because the stream is 1152 pixels wide.
- One monitor only, for now.

## 9. Tonight's plan (Dubai time)

| Time | Step |
| --- | --- |
| now → 20:30 | `zsh GlanceVR/build.sh`, `zsh GlanceVR/cable.sh install`, open the Glance app on the Mac, then test in the headset |
| by 21:00 | Upload with `metavr store dist upload … --channel Competition` and create the judges' invite URL |
| 21:00 → 22:15 | Record the demo video (under 3 min) and upload it to YouTube as public |
| 22:15 → 23:15 | Fill in the Devpost form |
| by 23:30 | Submit (30 min buffer before midnight) |

## 10. Where things are

- **Headset app:** `GlanceVR/headset/gaze.gd`. Build with `GlanceVR/build.sh`, connect with `GlanceVR/cable.sh`.
- **Mac changes:** `Glance/Sources/Glance/` → `GazeInput.swift`, `QuestHub.swift`, `GlanceCLI.swift`, `Overlay.swift`. Run `git diff` in `Glance` to see them.
- **How to run:** `GlanceVR/README.md`.
- **Signing key:** `GlanceVR/signing/`. Keep a backup and never share it.
