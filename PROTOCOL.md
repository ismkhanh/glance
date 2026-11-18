# Glance VR protocol: headset ↔ Mac

## Headset ↔ Glance app (WebSocket :47811)

Separate from the brain. The Glance app listens on `ws://127.0.0.1:47811` when started with `--quest`: this Mac only, so the headset
connects over USB with `adb reverse tcp:47811 tcp:47811`. `GLANCE_QUEST_LAN=1` opens it to the Wi-Fi (then set
`GLANCE_QUEST_TOKEN` on the Mac and the same token in the Quest app, because a connection can open shells).
Eye gaze stays on UDP 47810 (`--gaze`). Full design: [docs/specs/0001-quest-desk.md](docs/specs/0001-quest-desk.md).

Text messages are JSON with `type`. Binary packets are tagged by first byte: `A` (0x41) is
24 kHz mono 16-bit voice audio from the headset; `S` (0x53) is a Mac screen JPEG frame to it;
`W` (0x57) plus a 4-byte big-endian window id is one floating-window panel JPEG (protocol 2, below).

| direction | type | fields |
| --- | --- | --- |
| Quest → app | `hello` | `app`, `token?` (must match when a token is set; first message) |
| Quest → app | `term_create` | `title?` |
| Quest → app | `term_input` | `id`, `text` |
| Quest → app | `term_close` | `id` |
| Quest → app | `voice_begin` / `voice_end` / `voice_cancel` | `id` (terminal the audio belongs to) |
| Quest → app | `screen_want` | `on` |
| Quest → app | `gaze` | `x?`, `y?` (0…1 on the main display, top-left origin), `talk?` (bool: left pinch held). Glance VR sends these here over USB instead of UDP 47810; the talk state is repeated in every message, and Glance stops listening when the headset disconnects |
| Quest → app | `gaze.window` | with floating windows, `gaze` also carries `window`: the panel's window id, and `x`/`y` are 0…1 inside that window. Glance points and talks to that window, even behind others |
| Quest → app | `windows_want` | `on` (protocol 2: start/stop floating windows; needs a token, see `hello`) |
| Quest → app | `highlight` | `window` (window id the user is looking at; switches its panel to a live stream) |
| app → Quest | `hello` | `mac`, `version`, `windows` (bool: floating windows on for this connection) |
| Quest → app | `click` / `drag_start` / `drag_move` / `drag_end` / `drag_cancel` | `window`, `x`, `y` (0…1 inside that window). Glance raises the window, warps the real pointer there, and posts real mouse events |
| app → Quest | `windows` | `windows`: list of `{id, app, title, w, h, z, bx, by, bw, bh}` (frontmost first, at most 8), `more` (how many did not fit), `display {w, h}`. Bounds let the headset place panels on the real screen |
| app → Quest | `W…` binary | window id + JPEG for one floating panel (highlighted window live at ~8 fps, others stills) |
| app → Quest | `term_list` | `terms`: list of `id`, `title` |
| app → Quest | `term_output` | `id`, `title`, `text` (last screenful, escape codes stripped) |
| app → Quest | `term_closed` | `id` |
| app → Quest | `voice_partial` | `id`, `text` |
| app → Quest | `heard` | `id`, `text` (transcribed words that were sent to the terminal) |
| app → Quest | `error` | `text`, `id?` |

Discovery: the Quest app broadcasts `GLANCE_DISCOVER` on UDP 47812; Glance replies
`{"type":"glance_mac","port":47811}` and the app connects to the reply's sender. No address
or token is typed anywhere; a token is only checked when `GLANCE_QUEST_TOKEN` is set on the Mac.

Panel placement is Quest-local and never sent to the Mac: pinch-dragging a panel's bottom-right
corner resizes (zooms) it with its aspect locked, and pinch-dragging its bottom-centre bar moves
it in the room. The Mac window itself is not resized or moved by either gesture.

Terminals are real `/bin/zsh` login shells on pseudo terminals on the Mac (`TermHub`).
Spoken words are transcribed with the existing Muse voice path and written into the named
terminal (`QuestSpeech`: a lone “control c” / “enter” / “tab” / “escape” sends that key,
“type …” types without Return, anything else runs as a command).

