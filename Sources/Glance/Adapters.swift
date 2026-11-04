import AppKit
import Foundation

/// Knows how to read and act on one kind of window. Muse decides WHAT to do; the adapter knows HOW.
protocol WindowAdapter {
    var kind: String { get }
    /// Facts sent with every command: what the window is and what it shows.
    func describe() -> String
    /// Tools offered to Muse for this window (Responses API function tools).
    var tools: [[String: Any]] { get }
    /// True when a tool call changes things the user may not want, so we ask first.
    func needsConfirmation(_ name: String, _ args: [String: Any]) -> Bool
    func execute(_ name: String, _ args: [String: Any]) -> String
    /// Set when the window does not share its text, so Muse gets a picture of it instead.
    var screenshotWindowID: CGWindowID? { get }
}

extension WindowAdapter {
    var screenshotWindowID: CGWindowID? { nil }
}

func functionTool(_ name: String, _ description: String,
                  _ properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
    let parameters: [String: Any] = [
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": false,
    ]
    return ["type": "function", "name": name, "description": description, "parameters": parameters]
}

enum Adapters {
    static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary",
        "com.brave.Browser", "com.microsoft.edgemac",
    ]

    /// Terminal apps whose text Glance cannot read directly: Muse gets a picture of the window.
    static let screenTerminals: Set<String> = [
        "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper",
    ]

    /// Picks the most exact way to talk to this window; the accessibility tree is the fallback for any app.
    static func make(for target: TargetWindow) -> WindowAdapter {
        let id = target.bundleID
        if id == "com.apple.Terminal", let a = TerminalAdapter(target) { return a }
        if chromium.contains(id), let a = ChromiumAdapter(target) { return a }
        if id == "com.apple.Music" || id == "com.spotify.client" { return MusicAppAdapter(target) }
        if screenTerminals.contains(id) { return ScreenTerminalAdapter(target) }
        return GenericAdapter(target)
    }
}

// MARK: - Shared pieces

// Words at the start of a word only: "Delete", "Deleted", "Order now"; not "Border", "Display" or "Information".
private let riskyWords = try? NSRegularExpression(
    pattern: "\\b(delete|remove|trash|erase|discard|send|submit|buy|pay|purchase|order|quit|close|sign out|log out|unsubscribe|format)",
    options: [.caseInsensitive])

func looksRisky(_ text: String) -> Bool {
    guard let re = riskyWords else { return false }
    return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
}

/// Hides things that look like API keys or tokens before window text is sent to Muse.
func maskSecrets(_ text: String) -> String {
    let patterns = [
        "(sk|pk|rk|ghp|gho|ghs|glpat|xox[abprs])[-_][A-Za-z0-9_\\-]{10,}",
        "AKIA[0-9A-Z]{16}",
        "[A-Za-z0-9_\\-]{40,}",
    ]
    var out = text
    for p in patterns {
        guard let re = try? NSRegularExpression(pattern: p) else { continue }
        out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: "[hidden]")
    }
    return out
}

let pressKeysTool = functionTool(
    "press_keys",
    "Bring this window to the front and press a key combination, e.g. \"cmd+t\", \"space\", \"ctrl+c\", \"return\".",
    ["combo": ["type": "string"]], required: ["combo"])

func runPressKeys(_ target: TargetWindow, _ args: [String: Any]) -> String {
    let combo = args["combo"] as? String ?? ""
    let ok = sendToWindow(target) { Keys.press(combo) }
    return ok ? "Pressed \(combo)." : "Unknown key combination: \(combo)."
}

let typeTextTool = functionTool(
    "type_text",
    "Bring this window to the front and type text, as if from the keyboard. Set press_return to press Return after it.",
    ["text": ["type": "string"], "press_return": ["type": "boolean"]], required: ["text", "press_return"])

func runTypeText(_ target: TargetWindow, _ args: [String: Any]) -> String {
    let text = args["text"] as? String ?? ""
    let enter = args["press_return"] as? Bool ?? false
    let ok = sendToWindow(target) {
        let typed = Typing.type(text)
        return enter ? typed && Keys.press("return") : typed
    }
    return ok ? "Typed \"\(text)\"\(enter ? " and pressed Return" : "")." : "Could not type."
}

/// Keys that quit or close something, delete files, or interrupt or end what runs in a terminal, however written.
func keysAreRisky(_ args: [String: Any]) -> Bool {
    let c = KeyCombo(args["combo"] as? String ?? "")
    let cmd = c.modifiers.contains("cmd")
    if cmd && ["q", "w", "delete"].contains(c.key) { return true }                 // quit, close, move to Trash
    if cmd && c.modifiers.contains("option") && c.key == "escape" { return true }  // Force Quit
    if c.modifiers.contains("ctrl") && ["c", "d", "z", "\\"].contains(c.key) { return true }  // interrupt, end, stop
    return false
}

// MARK: - Terminal.app

final class TerminalAdapter: WindowAdapter {
    let kind = "terminal"
    private let target: TargetWindow
    private let windowID: Int

    init?(_ target: TargetWindow) {
        let list = """
        tell application "Terminal"
            set out to ""
            repeat with w in windows
                set b to bounds of w
                set out to out & (id of w as text) & "|" & (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text) & linefeed
            end repeat
            return out
        end tell
        """
        guard let id = matchScriptWindow(listScript: list, target: target) else { return nil }
        self.target = target
        self.windowID = id
    }

    private func visibleText(lines: Int) -> String {
        let script = "tell application \"Terminal\" to get contents of selected tab of window id \(windowID)"
        guard let all = try? AppleScript.run(script) else { return "(could not read this terminal)" }
        var rows = all.components(separatedBy: "\n")
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty { rows.removeLast() }
        return maskSecrets(rows.suffix(lines).joined(separator: "\n"))
    }

    func describe() -> String {
        let name = (try? AppleScript.run("tell application \"Terminal\" to get name of window id \(windowID)")) ?? target.title
        return "App: Terminal. Window: \(name)\nLast lines on screen (secrets hidden):\n<<<\n\(visibleText(lines: 80))\n>>>"
    }

    static let toolList: [[String: Any]] = [
        functionTool("type_in_terminal",
                     "Type a line into this terminal and press Return: a shell command, or an answer to a prompt shown on screen (like y or 1).",
                     ["text": ["type": "string"]], required: ["text"]),
        pressKeysTool,
    ]

    var tools: [[String: Any]] { TerminalAdapter.toolList }

    /// Every line typed into a terminal runs, so it is always confirmed; so are keys that quit or interrupt.
    static func needsConfirmation(_ name: String, _ args: [String: Any]) -> Bool {
        name == "type_in_terminal" || (name == "press_keys" && keysAreRisky(args))
    }

    func needsConfirmation(_ name: String, _ args: [String: Any]) -> Bool {
        TerminalAdapter.needsConfirmation(name, args)
    }

    func execute(_ name: String, _ args: [String: Any]) -> String {
        switch name {
        case "type_in_terminal":
            let text = args["text"] as? String ?? ""
            let script = "tell application \"Terminal\" to do script \(AppleScript.quote(text)) in selected tab of window id \(windowID)"
            do {
                try AppleScript.run(script)
                return "Typed: \(text)"
            } catch {
                return "Could not type into the terminal: \(error)"
            }
        case "press_keys":
            return runPressKeys(target, args)
        default:
            return "Unknown tool \(name)."
        }
    }
}

// MARK: - Terminal apps that do not share their text (Ghostty, iTerm2, ...)

final class ScreenTerminalAdapter: WindowAdapter {
    let kind = "terminal"
    private let target: TargetWindow

    init(_ target: TargetWindow) {
        self.target = target
    }

    var screenshotWindowID: CGWindowID? { target.windowID }

    func describe() -> String {
        """
        App: \(target.appName), a terminal. Its screen is in the attached picture.
        If an AI coding agent in it is waiting for an answer, read the question and the options in the picture.
        In those menus the highlighted option is chosen with Return; other options with the arrow keys and Return,
        or by typing their number. Say which option you are choosing.
        """
    }

    var tools: [[String: Any]] { [typeTextTool, pressKeysTool] }

    /// Anything typed into a terminal can run a command or approve an agent's action, so always ask first.
    func needsConfirmation(_ name: String, _ args: [String: Any]) -> Bool { true }

    func execute(_ name: String, _ args: [String: Any]) -> String {
        switch name {
        case "type_text": return runTypeText(target, args)
        case "press_keys": return runPressKeys(target, args)
        default: return "Unknown tool \(name)."
        }
    }
}

// MARK: - Chrome, Brave, Edge

/// A Swift string as a JavaScript string literal (quotes and escapes included).
func jsString(_ s: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed),
          let text = String(data: data, encoding: .utf8) else { return "''" }
    return text
}

/// One browser tab, numbered across all windows so Muse can name it.
struct BrowserTab {
    let number: Int
    let windowID: Int
    let index: Int          // 1-based position in its window
    let title: String
    let url: String
    let media: String       // "playing", "paused", "no player", or "" when it is not a media site
    let showing: Bool       // the tab showing in its window
    let inTarget: Bool      // in the window under the pointer

    var ref: String { "tab \(index) of window id \(windowID)" }
}

/// Full control of a Chromium browser: every tab in every window, pages, media and forms.
final class ChromiumAdapter: WindowAdapter {
    let kind = "browser"
    private let target: TargetWindow
    private let app: String
    private let windowID: Int
    private var tabs: [BrowserTab] = []
    private var scriptsBlocked = false

    private static let mediaSites = ["music.youtube.com", "youtube.com/watch", "open.spotify.com", "soundcloud.com", "music.apple.com"]

    init?(_ target: TargetWindow) {
        let app = "application id \"\(target.bundleID)\""
        let list = """
        tell \(app)
            set out to ""
            repeat with w in windows
                set b to bounds of w
                set out to out & (id of w as text) & "|" & (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text) & linefeed
            end repeat
            return out
        end tell
        """
        guard let id = matchScriptWindow(listScript: list, target: target) else { return nil }
        self.target = target
        self.app = app
        self.windowID = id
        loadTabs()
    }

    /// One AppleScript call lists every tab and asks media sites whether they are playing.
    private func loadTabs() {
        let isMedia = ChromiumAdapter.mediaSites.map { "u contains \"\($0)\"" }.joined(separator: " or ")
        let probe = "(()=>{const v=document.querySelector('video,audio');return v?(v.paused?'paused':'playing'):'no player'})()"
        let script = """
        set sep to character id 9
        tell \(app)
            set out to ""
            repeat with w in windows
                set wid to id of w
                set ai to active tab index of w
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    set u to URL of t
                    set m to ""
                    if \(isMedia) then
                        try
                            set m to execute t javascript \(AppleScript.quote(probe))
                        on error
                            set m to "blocked"
                        end try
                    end if
                    set out to out & (wid as text) & sep & (i as text) & sep & (ai as text) & sep & (title of t) & sep & u & sep & m & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        guard let text = try? AppleScript.run(script) else { return }
        var found: [BrowserTab] = []
        for line in text.components(separatedBy: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 6, let wid = Int(f[0]), let index = Int(f[1]), let shown = Int(f[2]) else { continue }
            var media = f[5].trimmingCharacters(in: .whitespaces)
            if media == "blocked" {
                scriptsBlocked = true
                media = "unknown"
            }
            found.append(BrowserTab(number: 0, windowID: wid, index: index, title: f[3], url: f[4], media: media,
                                    showing: index == shown, inTarget: wid == windowID))
        }
        let ordered = found.filter { $0.inTarget } + found.filter { !$0.inTarget }   // this window first
        tabs = ordered.prefix(80).enumerated().map { i, t in
            BrowserTab(number: i + 1, windowID: t.windowID, index: t.index, title: t.title, url: t.url,
                       media: t.media, showing: t.showing, inTarget: t.inTarget)
        }
    }

    private func short(_ url: String) -> String {
        var u = url.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        if u.hasPrefix("www.") { u.removeFirst(4) }
        return String(u.prefix(60))
    }

    private func line(_ t: BrowserTab) -> String {
        var s = "  [\(t.number)] \(t.title.prefix(70)) (\(short(t.url)))"
        if t.showing { s += " (showing)" }
        if !t.media.isEmpty { s += " — media: \(t.media)" }
        return s + "\n"
    }

    func describe() -> String {
        var s = "App: \(target.appName). Every open tab, numbered:\nThis window (the one the user is looking at):\n"
        for t in tabs where t.inTarget { s += line(t) }
        let others = tabs.filter { !$0.inTarget }
        if !others.isEmpty {
            s += "Other \(target.appName) windows:\n"
            for t in others { s += line(t) }
        }
        s += "Act on the tab the user means (for example the music tab), not only the one showing. Use read_page to see a page."
        if scriptsBlocked {
            s += "\nPage scripts are blocked, so media, read_page, click, type_into and scroll fail until the user turns on View > Developer > Allow JavaScript from Apple Events."
        }
        return s
    }

    private static let tabProperty: [String: Any] = [
        "type": "integer",
        "description": "Tab number from the list. Leave it out to use the tab showing in this window.",
    ]

    var tools: [[String: Any]] {
        let tab = ChromiumAdapter.tabProperty
        return [
            functionTool("switch_tab", "Show a tab (brings its window forward if it is another window).",
                         ["tab": tab], required: ["tab"]),
            functionTool("open_tab", "Open a new tab in this window, with a URL or with words to search the web for.",
                         ["url_or_search": ["type": "string"]], required: ["url_or_search"]),
            functionTool("close_tab", "Close a tab.", ["tab": tab], required: ["tab"]),
            functionTool("go_to", "Load a URL, or a web search for some words, in an existing tab.",
                         ["url_or_search": ["type": "string"], "tab": tab], required: ["url_or_search"]),
            functionTool("navigate", "Go back, go forward or reload in a tab.",
                         ["action": ["type": "string", "enum": ["back", "forward", "reload"]] as [String: Any], "tab": tab],
                         required: ["action"]),
            functionTool("media", "Play, pause, next or previous for the song or video in a tab. Leave out tab to use the media tab.",
                         ["action": ["type": "string", "enum": ["play", "pause", "next", "previous"]] as [String: Any], "tab": tab],
                         required: ["action"]),
            functionTool("set_media_volume", "Set the volume of the song or video in a tab, 0 to 100.",
                         ["percent": ["type": "integer", "minimum": 0, "maximum": 100] as [String: Any], "tab": tab],
                         required: ["percent"]),
            functionTool("read_page", "Read the text of a tab's page, to answer questions about it.", ["tab": tab]),
            functionTool("click", "Click a link or button on a tab's page, found by its visible text.",
                         ["text": ["type": "string"], "tab": tab], required: ["text"]),
            functionTool("type_into", "Type into a text field on a tab's page. field: words from its label or placeholder, or empty for the main field. submit: press Enter after.",
                         ["field": ["type": "string"], "text": ["type": "string"], "submit": ["type": "boolean"], "tab": tab],
                         required: ["field", "text", "submit"]),
            functionTool("scroll", "Scroll a tab's page.",
                         ["direction": ["type": "string", "enum": ["up", "down", "top", "bottom"]] as [String: Any], "tab": tab],
                         required: ["direction"]),
            pressKeysTool,
        ]
    }

    /// The tab a tool call means: the given number, else (for media) a media tab, else the tab showing here.
    private func tab(_ args: [String: Any], preferMedia: Bool = false) -> BrowserTab? {
        let number = (args["tab"] as? Int) ?? (args["tab"] as? Double).map { Int($0) }
        if let n = number, let t = tabs.first(where: { $0.number == n }) { return t }
        if preferMedia {
            let pick = tabs.first(where: { $0.inTarget && $0.media == "playing" })
                ?? tabs.first(where: { $0.media == "playing" })
                ?? tabs.first(where: { $0.inTarget && !$0.media.isEmpty })
                ?? tabs.first(where: { !$0.media.isEmpty })
            if let t = pick { return t }
        }
        return tabs.first(where: { $0.inTarget && $0.showing })
    }

    func needsConfirmation(_ name: String, _ args: [String: Any]) -> Bool {
        switch name {
        case "close_tab":
            return true
        case "click":
            return looksRisky(args["text"] as? String ?? "")
        case "type_into":
            let context = (args["field"] as? String ?? "") + " " + (tab(args)?.url ?? "")
            return (args["submit"] as? Bool) == true && looksRisky(context)
        case "press_keys":
            return keysAreRisky(args)
        default:
            return false
        }
    }

    private static func address(_ input: String) -> String {
        let s = input.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        if !s.contains(" "), s.contains("."), !s.hasSuffix(".") { return "https://" + s }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        return "https://www.google.com/search?q=" + (s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s)
    }

    private func script(_ source: String, done: String) -> String {
        do {
            try AppleScript.run(source)
            return done
        } catch {
            return "Could not do it: \(error)"
        }
    }

    private func javascript(_ code: String, in t: BrowserTab) -> String {
        let oneLine = code.replacingOccurrences(of: "\n", with: " ")
        do {
            return try AppleScript.run("tell \(app) to execute \(t.ref) javascript \(AppleScript.quote(oneLine))")
        } catch {
            let message = "\(error)"
            if message.lowercased().contains("turned off") || message.contains("Apple Events") {
                return "The browser blocked the script. Turn on View > Developer > Allow JavaScript from Apple Events, then try again."
            }
            return "Script failed: \(message)"
        }
    }

    func execute(_ name: String, _ args: [String: Any]) -> String {
        switch name {
        case "open_tab":
            let address = ChromiumAdapter.address(args["url_or_search"] as? String ?? "")
            return script("""
            tell \(app)
                tell window id \(windowID)
                    make new tab at end of tabs with properties {URL:\(AppleScript.quote(address))}
                    set active tab index to (count of tabs)
                end tell
            end tell
            """, done: "Opened \(address)")
        case "press_keys":
            return runPressKeys(target, args)
        default:
            break
        }

        guard let t = tab(args, preferMedia: name == "media" || name == "set_media_volume") else {
            return "No tab with that number."
        }
        switch name {
        case "switch_tab":
            return script("""
            tell \(app)
                set active tab index of window id \(t.windowID) to \(t.index)
                set index of window id \(t.windowID) to 1
            end tell
            """, done: "Showing tab \(t.number): \(t.title)")
        case "close_tab":
            return script("tell \(app) to close \(t.ref)", done: "Closed tab \(t.number): \(t.title)")
        case "go_to":
            let address = ChromiumAdapter.address(args["url_or_search"] as? String ?? "")
            return script("tell \(app) to set URL of \(t.ref) to \(AppleScript.quote(address))",
                          done: "Loading \(address) in tab \(t.number)")
        case "navigate":
            let action = args["action"] as? String ?? "reload"
            let verb = ["back": "go back", "forward": "go forward", "reload": "reload"][action] ?? "reload"
            return script("tell \(app) to tell \(t.ref) to \(verb)", done: "Did \(action) in tab \(t.number)")
        case "media":
            let action = (args["action"] as? String ?? "pause").filter { $0.isLetter }
            return javascript("""
            (() => {
              const a = '\(action)';
              const v = document.querySelector('video, audio');
              const toggle = document.querySelector('#play-pause-button, .play-pause-button, .ytp-play-button, [data-testid=control-button-playpause]');
              if (a === 'play' && v && v.paused) { if (toggle) toggle.click(); else v.play(); }
              if (a === 'pause' && v && !v.paused) { if (toggle) toggle.click(); else v.pause(); }
              if (a === 'next') { const b = document.querySelector('.next-button, .ytp-next-button, [data-testid=control-button-skip-forward]'); if (b) b.click(); }
              if (a === 'previous') { const b = document.querySelector('.previous-button, .ytp-prev-button, [data-testid=control-button-skip-back]'); if (b) b.click(); }
              return v ? a + ' done in tab \(t.number): ' + document.title : 'no video or song found in tab \(t.number)';
            })()
            """, in: t)
        case "set_media_volume":
            let percent = max(0, min(100, (args["percent"] as? Int) ?? Int((args["percent"] as? Double) ?? 50)))
            return javascript("""
            (() => {
              const v = document.querySelector('video, audio');
              if (!v) return 'no video or song found in tab \(t.number)';
              v.volume = \(percent) / 100;
              return 'volume ' + Math.round(v.volume * 100) + '% in tab \(t.number)';
            })()
            """, in: t)
        case "read_page":
            return maskSecrets(javascript("document.title + '\\n' + document.body.innerText.slice(0, 6000)", in: t))
        case "click":
            let text = jsString(args["text"] as? String ?? "")
            return javascript("""
            (() => {
              const want = \(text).toLowerCase();
              const visible = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
              const name = e => (e.innerText || e.value || e.getAttribute('aria-label') || e.title || '').trim();
              const all = [...document.querySelectorAll('a, button, [role=button], [role=link], [role=tab], [role=menuitem], [role=option], input[type=submit], input[type=button], summary, label')];
              const hits = all.filter(visible).map(e => [e, name(e).toLowerCase()]).filter(([e, n]) => n && n.includes(want));
              if (!hits.length) return 'Nothing to click matches that text in tab \(t.number)';
              hits.sort((a, b) => ((a[1] === want ? 0 : 1) - (b[1] === want ? 0 : 1)) || (a[1].length - b[1].length));
              const el = hits[0][0];
              el.scrollIntoView({block: 'center'});
              el.click();
              return 'Clicked "' + name(el).slice(0, 80) + '" in tab \(t.number)';
            })()
            """, in: t)
        case "type_into":
            let field = jsString(args["field"] as? String ?? "")
            let text = jsString(args["text"] as? String ?? "")
            let submit = (args["submit"] as? Bool) == true ? "true" : "false"
            return javascript("""
            (() => {
              const want = \(field).toLowerCase();
              const visible = e => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
              const fields = [...document.querySelectorAll('input:not([type=hidden]):not([type=password]):not([type=submit]):not([type=button]):not([type=checkbox]):not([type=radio]), textarea, [contenteditable=true]')].filter(visible);
              const label = e => [e.getAttribute('aria-label'), e.placeholder, e.name, e.id, e.labels && e.labels[0] && e.labels[0].innerText, e.title].filter(Boolean).join(' ').toLowerCase();
              let el = want ? fields.find(e => label(e).includes(want)) : null;
              if (!el) el = fields.includes(document.activeElement) ? document.activeElement : fields[0];
              if (!el) return 'No text field on this page (tab \(t.number))';
              el.focus();
              if (el.isContentEditable) {
                el.textContent = \(text);
                el.dispatchEvent(new InputEvent('input', {bubbles: true}));
              } else {
                const proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
                Object.getOwnPropertyDescriptor(proto, 'value').set.call(el, \(text));
                el.dispatchEvent(new Event('input', {bubbles: true}));
                el.dispatchEvent(new Event('change', {bubbles: true}));
              }
              if (\(submit)) {
                if (el.form && el.form.requestSubmit) el.form.requestSubmit();
                else el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', keyCode: 13, bubbles: true}));
              }
              return 'Typed into ' + (label(el).slice(0, 60) || el.tagName.toLowerCase()) + (\(submit) ? ' and submitted' : '') + ' in tab \(t.number)';
            })()
            """, in: t)
        case "scroll":
            let direction = (args["direction"] as? String ?? "down").filter { $0.isLetter }
            return javascript("""
            (() => {
              const d = '\(direction)';
              if (d === 'top') window.scrollTo(0, 0);
              else if (d === 'bottom') window.scrollTo(0, document.body.scrollHeight);
              else window.scrollBy(0, (d === 'up' ? -1 : 1) * window.innerHeight * 0.8);
              return 'Scrolled ' + d + ' in tab \(t.number)';
            })()
            """, in: t)
        default:
            return "Unknown tool \(name)."
        }
    }
}

// MARK: - Music and Spotify apps

final class MusicAppAdapter: WindowAdapter {
    let kind = "music player"
    private let target: TargetWindow
    private let app: String

    init(_ target: TargetWindow) {
        self.target = target
        self.app = "application id \"\(target.bundleID)\""
    }

    private func state() -> String {
        let script = """
        tell \(app)
            set s to (player state as text)
            try
                set t to (name of current track) & " by " & (artist of current track)
            on error
                set t to "no track"
            end try
            return s & ", " & t & ", volume " & (sound volume as text)
        end tell
        """
        return (try? AppleScript.run(script)) ?? "unknown"
    }

    func describe() -> String {
        "App: \(target.appName). Now: \(state())."
    }

    var tools: [[String: Any]] {
        [
            functionTool("media", "Control playback in this music app.",
                         ["action": ["type": "string", "enum": ["play", "pause", "next", "previous"]] as [String: Any]],
                         required: ["action"]),
            functionTool("set_volume", "Set this app's volume, 0 to 100.",
                         ["percent": ["type": "integer", "minimum": 0, "maximum": 100] as [String: Any]], required: ["percent"]),
        ]
    }

    func needsConfirmation(_ name: String, _ args: [String: Any]) -> Bool { false }

    func execute(_ name: String, _ args: [String: Any]) -> String {
        let verbs = ["play": "play", "pause": "pause", "next": "next track", "previous": "previous track"]
        do {
            switch name {
            case "media":
                let verb = verbs[args["action"] as? String ?? ""] ?? "playpause"
                try AppleScript.run("tell \(app) to \(verb)")
            case "set_volume":
                let percent = max(0, min(100, (args["percent"] as? Int) ?? Int((args["percent"] as? Double) ?? 50)))
                try AppleScript.run("tell \(app) to set sound volume to \(percent)")
            default:
                return "Unknown tool \(name)."
            }
            return "Now: \(state())"
        } catch {
            return "The app refused: \(error)"
        }
    }
}

// MARK: - Any other app, through the accessibility tree

final class GenericAdapter: WindowAdapter {
    let kind = "app"
    private let target: TargetWindow
    private let window: AXUIElement?
    private let items: [UIItem]
    private let text: String
    private let title: String

    init(_ target: TargetWindow) {
        self.target = target
        let w = AX.window(for: target)
        self.window = w
        if let w = w {
            let collected = UITree.collect(window: w)
            items = collected.items
            text = collected.text
        } else {
            items = []
            text = ""
        }
        title = w.flatMap { AX.string($0, kAXTitleAttribute) } ?? target.title
    }

    /// Too little in the accessibility tree to understand the window: send a picture too.
    private var isSparse: Bool { items.count < 3 && text.count < 200 }

    var screenshotWindowID: CGWindowID? { isSparse ? target.windowID : nil }

    func describe() -> String {
        var s = "App: \(target.appName). Window title: \(title.isEmpty ? "(none)" : title)."
        if items.isEmpty {
            s += "\nThis app does not list its controls; use the attached picture, the menu bar, typing or key presses."
        } else {
            s += "\nThings in the window you can act on:\n" + items.map { $0.line }.joined(separator: "\n")
        }
        if !text.isEmpty {
            s += "\nText in the window (first part):\n<<<\n\(maskSecrets(String(text.prefix(3000))))\n>>>"
        }
        return s
    }

    var tools: [[String: Any]] {
        [
            functionTool("press", "Press a button, link, checkbox or tab in this window, by its [id].",
                         ["id": ["type": "integer"]], required: ["id"]),
            functionTool("set_text", "Put text into a text field in this window, by its [id].",
                         ["id": ["type": "integer"], "text": ["type": "string"]], required: ["id", "text"]),
            functionTool("choose_menu", "Choose a menu bar item of this app, e.g. [\"File\", \"New Window\"].",
                         ["path": ["type": "array", "items": ["type": "string"]] as [String: Any]], required: ["path"]),
            typeTextTool,
            pressKeysTool,
        ]
    }

    private func item(_ args: [String: Any]) -> UIItem? {
        let id = (args["id"] as? Int) ?? Int((args["id"] as? Double) ?? -1)
        return items.first { $0.id == id }
    }

    func needsConfirmation(_ name: String, _ args: [String: Any]) -> Bool {
        switch name {
        case "press": return looksRisky(item(args)?.label ?? "")
        case "choose_menu": return looksRisky((args["path"] as? [String] ?? []).joined(separator: " "))
        case "press_keys": return keysAreRisky(args)
        case "type_text": return (args["press_return"] as? Bool) == true
        default: return false
        }
    }

    func execute(_ name: String, _ args: [String: Any]) -> String {
        switch name {
        case "press":
            guard let it = item(args) else { return "No item with that id." }
            return AX.press(it.element) ? "Pressed \"\(it.label)\"." : "Could not press \"\(it.label)\"."
        case "set_text":
            guard let it = item(args) else { return "No item with that id." }
            let value = args["text"] as? String ?? ""
            return AX.setText(it.element, value) ? "Typed into \"\(it.label)\"." : "Could not type into \"\(it.label)\"."
        case "choose_menu":
            return AX.chooseMenu(pid: target.pid, path: args["path"] as? [String] ?? [])
        case "type_text":
            return runTypeText(target, args)
        case "press_keys":
            return runPressKeys(target, args)
        default:
            return "Unknown tool \(name)."
        }
    }
}
