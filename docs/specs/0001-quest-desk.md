# Quest Desk: your Mac, its terminals, and your voice, inside the headset

**Status**: Proposed
**Date**: 2026-11-05
**Mode**: ENHANCEMENT (Glance on the Mac plus Glance Gaze on Quest Pro)

## Summary

You put on the headset and see your Mac in front of you. Around it sit terminal panels. Each panel is a real shell running on your Mac. You turn your head to face one, hold an index finger and thumb pinch, speak a command, and let go. Your words become text on the Mac and run in that shell. You can open more terminals from inside the headset. Nothing runs on the headset except the view and the microphone. All work stays on the Mac.

This builds on what you already have. Glance on the Mac already listens, transcribes speech with Muse Voice Transcribe, and acts on windows. Glance Gaze on the Quest already sends your eye point to the Mac over Wi-Fi. Quest Desk adds one Mac service and grows the Quest app into a small desk.

## Requirements

AC-1. You can see your Mac screen as a panel floating in the headset, live, even when you face away from the real screen. Passthrough stays on around it.

AC-2. You can open a new terminal from inside the headset. It starts a fresh login shell on your Mac, in your home folder, with your normal shell setup.

AC-3. Each terminal panel shows the last screenful of that shell, updated as output arrives. A shell keeps running when the headset disconnects, and its recent output is shown again on reconnect.

AC-4. The terminal your head faces is clearly marked. Only that terminal receives your voice.

AC-5. While you hold a pinch, the headset microphone streams to the Mac. When you let go, the Mac transcribes the speech and sends the text to the faced terminal as if typed, followed by Return, so the command runs. Short spoken controls such as “control c”, “enter”, “tab”, and “escape” send that key instead of text.

AC-6. Your eye point still moves the Mac pointer when you look at the virtual Mac screen, so the existing Glance glow and talk flow keep working on the streamed screen.

AC-7. The link is local only. Mac and headset sit on the same Wi-Fi. An optional shared token can be required, set on both ends.

AC-8. If speech cannot be transcribed (no key, service error), the faced terminal receives nothing, and the headset shows the error. A failed command never lands in the wrong terminal: the target terminal id travels with the audio from start to finish.

## Decision

**Stack**: Godot 4 on Quest (existing project), Swift in the existing Glance app on the Mac. No new server process, no new language, no cloud relay.

**Transport**: One WebSocket from Quest to Mac on TCP port 47811, path free JSON text messages plus two binary kinds. Gaze stays on the existing UDP port 47810.

**Mac modules** (new files beside the code they extend):

| Module | Job |
| --- | --- |
| `QuestHub` | WebSocket server, first message check, routing, client list |
| `TermHub` | One pseudo terminal per terminal id, output memory, text in |
| `ScreenStream` | Main display capture, scaled JPEG frames, about 8 per second |
| `Glance.transcribe` (existing) | Speech to text through the existing `AudioFeed` and `VoiceSession` |

**Quest modules**:

| Module | Job |
| --- | --- |
| `desk.gd` | Scene, panels, head focus, pinch, virtual screen, eye point |
| `hub_client.gd` | WebSocket, microphone capture and resampling, message routing in the app |

**Data model**: A terminal is `id`, `title`, `cols`, `rows`, plus a bounded output memory (the last 600 lines after escape codes are removed). A voice take is `terminalId`, a stream of 24 kHz mono 16 bit audio chunks, then an end marker. A screen frame is one JPEG.

### How each piece works

**Virtual Mac screen**. On the Mac, ScreenCaptureKit (`SCStream`) captures the main display. Each frame is scaled to about 1152 pixels wide and encoded as JPEG. Frames go out as binary messages whose first byte is `S`. In the headset the JPEG becomes an `ImageTexture` on a quad. You asked to view your Mac “somehow”: a streamed copy was chosen over only looking through passthrough at the real screen, because you can then face any way and still work, and terminals can sit beside the screen. Passthrough remains the room around the panels. Cost: the stream needs Screen Recording permission and adds a little lag, so the real screen plus passthrough stays best for fine pointer work. This needs macOS 12.3 or later for `SCStream`; the package already targets macOS 13.

**Terminals**. `TermHub` opens a pseudo terminal pair with `openpty`, then starts `/bin/zsh` as a login and interactive shell on the slave side. Output is read from the master side, escape sequences are stripped for the headset view, and the last lines are kept. Input is written to the master side. These are actual Mac sessions: processes you start are Mac processes, visible in `ps`, using your files and network. The panel in the headset is only a view and a keyboard. A later step can also mirror a session into a Terminal.app window; it is not needed for control and is left out.

**Head focus**. Every frame, a ray from the camera forward is tested against each panel plane. The nearest hit wins and its frame lights up. Turning your head is the selector, as you asked; eye gaze keeps its old job of moving the Mac pointer, because eyes are fast and jumpy for choosing and the head is steady.

**Pinch to talk**. With hand tracking on, an index pinch reads as the trigger value on the hand controller (Meta hand interaction profile), and a real controller trigger works too. Pinch start opens the microphone path: an `AudioStreamMicrophone` player feeds a Record bus with an `AudioEffectCapture` effect. Frames are mixed to mono, resampled to 24 kHz, and sent as binary messages whose first byte is `A`. Pinch release sends `voice_end` with the terminal id captured at pinch start. On the Mac the audio fills an `AudioFeed`, the existing `Glance.transcribe` runs it through a `VoiceSession`, and the words are written into that terminal. Timing note: transcription pace follows the existing session rules, so a long take can take a few seconds after release.

**Opening a terminal**. A fixed “New terminal” tile sits at the end of the row. A quick pinch tap (under 300 ms, with no speech) while facing it asks the Mac for a new shell. A long pinch is always speech, never a tap, so the two never clash. The first terminal opens on its own when the headset connects.

### Message protocol (Quest Desk)

Text messages are one JSON object with `type`, extending the style of [PROTOCOL.md](/Users/ik/MetaAICompetition/Glance/PROTOCOL.md).

| From | Type | Fields |
| --- | --- | --- |
| Quest | `hello` | `token` (only when set), `app` |
| Quest | `term_create` | `title?` |
| Quest | `term_input` | `id`, `text` (typed text, may end with `\r`) |
| Quest | `term_close` | `id` |
| Quest | `voice_begin` | `id` (terminal id), `rate` |
| Quest | `voice_end` | `id` |
| Quest | `screen_want` | `on` |
| Mac | `hello` | `mac`, `version` |
| Mac | `term_list` | `terms`: list of `id`, `title` |
| Mac | `term_output` | `id`, `title`, `text` (last screenful), `focused` hint unused |
| Mac | `term_closed` | `id` |
| Mac | `heard` | `id`, `text` (what was transcribed and sent) |
| Mac | `voice_partial` | `id`, `text` |
| Mac | `error` | `text`, `id?` |

Binary: Quest to Mac is `A` plus 24 kHz PCM. Mac to Quest is `S` plus JPEG. First byte decides, so no framing work is needed on either side.

### Options considered

| Option | Why not, or why yes |
| --- | --- |
| Stream the Mac with WebRTC | Best lag, but needs a media stack and signalling on both sides. Godot has no built in WebRTC data path ready for this, and Swift would need a new dependency. JPEG over the WebSocket we already need is enough at panel size and frame rate. |
| Full remote desktop input (mouse and keys to the real Mac desktop) | Wider scope and wider risk. You asked for terminals and voice. The existing gaze pointer already covers pointing. |
| Terminals as Terminal.app windows, typed into with AppleScript or key events | Fragile focus juggling, and a spoken command could land in the wrong window. Owned pseudo terminals give each panel an exact target. |
| Speech to text on the headset | Quest has no suitable built in dictation for Godot. The Mac already has a working Muse voice path with pacing and partials. |
| One TCP stream for gaze too | Gaze at 60 packets a second suits UDP and already works. It stays. |

## Build plan

1. Tracer slice: `TermHub` plus `QuestHub` text routing, one terminal in the headset as a text panel, tap to create, typed test text in.
2. Voice slice: microphone capture on Quest, `AudioFeed` transcription on Mac, injection into the faced terminal, spoken controls.
3. Screen slice: `ScreenStream` JPEG frames, virtual Mac screen quad, eye point mapped through its corners.
4. Polish: reconnect output replay, token check, README steps, build script stays the same.

Slices 1 to 3 are in this change. Slice 4 is partly in (replay and token) and the headset run still needs a person in the loop.

## Consequences

Good: one process to run, real Mac shells, exact voice targeting, no cloud hop for terminal data (speech still uses the Muse service, as Glance already does).

Costs and risks:

* The WebSocket is plain `ws` on your own Wi-Fi. Anyone on that network could connect when no token is set. Set `GLANCE_QUEST_TOKEN` on the Mac and the same value in the Quest app when that matters.
* Speech becomes shell input and runs at once. That is what you asked for, and it means a misheard word can run a real command. The panel shows what was heard (`heard` message) after the fact. A confirm step for risky words is a follow up, not in this change.
* Pseudo terminals strip escape codes, so full screen apps (vim, top) render poorly in the panel. Line based shells work well. A real terminal emulator on the Quest is a follow up.
* Screen streaming needs Screen Recording permission for the terminal app that runs Glance.
* Hand pinch as trigger depends on hand tracking being on and on the Meta profile mapping pinch to trigger value. A controller trigger is the fallback and always works.

## Follow up

* Confirm step before running heard speech that looks destructive.
* ANSI aware terminal view, or a small VT parser, for full screen apps.
* Mirror a hub shell into a visible Terminal.app window on request.
* WebRTC screen stream if JPEG lag bothers real use.

## References

Checked 2026-11-05 via Context7 (`godotengine/godot-docs`) and the web. Basis names only, per project style:

* Context7, Godot docs: WebSocketPeer client pattern (poll in `_process`, text and binary packets)
* Context7, Godot docs: recording with microphone, AudioEffectCapture and AudioStreamMicrophone, `audio/driver/enable_input`
* Context7, Godot docs: OpenXRInterface eye gaze support checks
* Godot OpenXR Vendors and Meta XR feature settings in the existing export preset (passthrough, hand tracking, eye tracking)
* Apple ScreenCaptureKit: `SCStream` with `SCContentFilter` for display capture
* Existing code: `GazeInput` (UDP gaze), `VoiceSession` and `AudioFeed` (speech), `WindowCapture` (ScreenCaptureKit use)
