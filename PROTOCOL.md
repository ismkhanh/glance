# Glance protocol: app ↔ brain ↔ Figma

```
Glance app (Swift)                 Glance brain (Node)                    Figma desktop
pointer, talk key, glow,   ws /app   orchestrator, workers,     ws /figma  Glance Bridge plugin
tooltips, mascot panel  <────────>   reviewer, Muse calls    <──────────>  (ui.html relays to code.js)
```

The brain listens on `ws://localhost:47800` (both 127.0.0.1 and ::1, never on the network).

- `/app?token=…`: the Glance app. When the app starts the brain, it passes `GLANCE_TOKEN`, and only that
  token is accepted. A brain started by hand (no token) accepts the app without one.
- `/figma`: the plugin's UI. Only accepted when the request comes with no website origin (`null`, empty or
  `https://www.figma.com`), so a web page in your browser cannot connect.

Every message is one JSON object with a `type`.

## Quest Desk (headset ↔ Glance app)

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

## App → brain

| type | fields | when |
| --- | --- | --- |
| `hello` | `app`, `version` | after connecting |
| `point` | `id`, `at {x,y}` (screen, top-left origin), `window {id, app, bundleID, title, bounds {x,y,w,h}}` | talk key down. For Figma the app has just Cmd+clicked at the pointer, so Figma selects the deepest layer there |
| `command` | `id` (same as `point`), `text`, `answerTo?` (task id, when the pointer was on a question tooltip) | talk key up, or typed |
| `answer` | `taskId`, `text` | an option clicked in a tooltip |
| `control` | `taskId`, `action`: `pause` `resume` `cancel` `undo` `retry` | task panel buttons |
| `edit` | `taskId`, `text` | task panel "Edit" |

## Brain → app

| type | fields |
| --- | --- |
| `hello` | `brain`, `figma` (bool: plugin connected) |
| `status` | `figma` (bool), `muse` (bool) |
| `ack` | `id`, `taskId`, `kind`: `new` `update` `answer` `undo` `none`, `text` |
| `tasks` | `tasks`: list of task views (below), sent after every change |
| `ask` | `taskId`, `question`, `options` [string], `recommended?`, `reason?`, `anchor {x,y}` |
| `askDone` | `taskId` |
| `toast` | `taskId?`, `text`, `kind`: `info` `done` `error`, `anchor?` |

Task view: `id`, `title`, `instruction`, `target {id,name,type}|null`, `status`
(`queued` `running` `asking` `paused` `verifying` `done` `failed` `cancelled` `reverted`), `detail`,
`question?`, `result?`, `review? {status: passed|warning|failed, notes[]}`, `updates[]`, `metrics`, `createdAt`, `updatedAt`.

`metrics`: what the task cost so far: `museCalls`, `museMs`, `museErrors`, `inputTokens`, `outputTokens`,
`reasoningTokens`, `imageCalls`, `imageMs`, `toolCalls`, `toolErrors`, `tools {name: count}`, `asks`, `passes`,
`reviewRetries`.

## Brain ↔ plugin

| direction | type | fields |
| --- | --- | --- |
| plugin → brain | `hello` | `plugin`, `file`, `page` |
| plugin → brain | `selection` | `nodes` [node summary] |
| brain → plugin | `call` | `rid`, `op`, `args` |
| plugin → brain | `result` | `rid`, `ok`, `value` or `error` |

Plugin ops: `getSelection`, `getNode {id}`, `findNodes {query, scopeId?}`, `snapshot {id}`, `restore {snapshot}`,
`setFill {id, color, opacity?}`, `setStroke {id, color, weight?}`, `setCornerRadius {id, radius}`,
`setOpacity {id, opacity}`, `setText {id, text}`, `setFontSize {id, size}`, `resize {id, width, height}`,
`setAutoLayout {id, direction, spacing?, padding?}`, `setScroll {id, direction}`, `rename {id, name}`,
`notify {text}`.

## Routing a spoken command (orchestrator)

0. The whole utterance asks to undo ("undo that", "put it back", "revert") → **undo** the task on the layer pointed at,
   else the task changed last (within 10 minutes). The layers come back from the saved copy; no Muse call.
1. `answerTo` set and that task is asking → **answer**.
2. Pointing at a layer that has an unfinished task → **answer** if that task is asking and the words fit its
   question, else **update** (merged into the running task).
3. Pointing at a layer whose task finished in the last 10 minutes → **update** (the task runs again).
4. Pointing at nothing, exactly one task asking, and the words fit its question → **answer**.
5. Otherwise → **new** task. New tasks run in parallel.
