# Glance VR protocol: Quest ↔ Mac

## Finding the Mac

On Wi-Fi, the Quest app sends the text `GLANCE_DISCOVER` as a UDP broadcast to port **47812**. The Mac app replies
`{"type":"glance_mac","port":47811}`, and the headset connects to the address the reply came from. Over USB there is
nothing to find: `adb reverse tcp:47811 tcp:47811` makes `127.0.0.1:47811` on the headset reach the Mac.

## The link

One WebSocket on port **47811**.
- **Text messages** are JSON objects with a `type`.
- **Binary messages** only go from the Mac to the Quest, and their first byte says what they are:
  - `W` (0x57) + a 4-byte big-endian window id + a JPEG: one window's picture, for its floating panel
  - `S` (0x53) + a JPEG: the whole main display, used for the single-screen fallback

The first message from the Quest must be `hello`.
- **Token:** if the Mac sets `GLANCE_QUEST_TOKEN`, the hello must carry the same `token`. A connection that sends no
  token over USB still gets the whole-screen mirror, but without windows or actions.
- **USB only:** `GLANCE_QUEST_LAN=0` makes the Mac accept connections only from USB (`127.0.0.1`).

## Quest → Mac

| type | fields | meaning |
| --- | --- | --- |
| `hello` | `app`, `proto` (2 = floating windows), `token?` | first message |
| `windows_want` | `on` | start / stop the window list and window pictures |
| `highlight` | `window` (id, or -1 for none) | the window you look at: its panel switches to a live stream |
| `gaze` | `window?`, `x`, `y` (0…1 inside that window, or on the main display without `window`) | where you look |
| `click` | `window`, `x`, `y` | short left pinch (or short right pinch): click there |
| `double_click` | `window`, `x`, `y` | two quick left pinches: double-click there (opens a file in Finder) |
| `scroll` | `window`, `x`, `y`, `dy` | point pose or long left pinch moved up/down, and the fling after it. `dy` in pixels: hand up = positive = content moves up |
| `drag_start` / `drag_move` / `drag_end` / `drag_cancel` | `window`, `x`, `y` | right pinch held while your gaze moves across a window |
| `screen_want` | `on` | fallback: stream the whole main display as one panel |

Before every click, double-click, scroll or drag, the Mac brings **that window** to the front. It then posts real mouse
or scroll events at the point, so the action always lands in the window you looked at, even if another window was
covering it. When the headset disconnects, the Mac lets go of any mouse button a drag left down.

## Mac → Quest

| type | fields |
| --- | --- |
| `hello` | `mac` (name), `version`, `windows` (true when floating windows are on for this connection) |
| `windows` | `windows`: list of `{id, app, title, w, h, z, bx, by, bw, bh}` (frontmost first, at most 8), `more` (how many did not fit), `display {w, h}` |
| `error` | `text` (shown in the headset, e.g. a missing Screen Recording permission) |
| binary `W…` | one window's picture: the highlighted window about 8 times a second, the others as stills |
| binary `S…` | the whole main display (fallback mode) |
