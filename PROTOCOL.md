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
