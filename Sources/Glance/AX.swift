import AppKit
import ApplicationServices

/// Small helpers over the macOS Accessibility API (the same API screen readers and Voice Control use).
enum AX {
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func attr(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        guard let s = attr(element, name) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attr(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let v = attr(element, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let v = attr(element, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    /// The accessibility window that matches a window-server window, by position and size.
    static func window(for target: TargetWindow) -> AXUIElement? {
        let app = AXUIElementCreateApplication(target.pid)
        // Electron apps only build their accessibility tree when asked.
        _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let windows = (attr(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        var best: (el: AXUIElement, d: CGFloat)?
        for w in windows {
            guard let p = point(w, kAXPositionAttribute), let s = size(w, kAXSizeAttribute) else { continue }
            let d = abs(p.x - target.bounds.minX) + abs(p.y - target.bounds.minY)
                + abs(s.width - target.bounds.width) + abs(s.height - target.bounds.height)
            if best == nil || d < best!.d { best = (el: w, d: d) }
        }
        if let b = best, b.d < 40 { return b.el }
        return windows.first
    }

    static func press(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    static func setText(_ element: AXUIElement, _ text: String) -> Bool {
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success
    }

    /// Brings the window and its app to the front (needed before sending key presses).
    static func raise(_ target: TargetWindow, window: AXUIElement?) {
        if let w = window { _ = AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
        NSRunningApplication(processIdentifier: target.pid)?.activate(options: [])
    }

    /// Presses a menu bar item by path, e.g. ["File", "Save"].
    static func chooseMenu(pid: pid_t, path: [String]) -> String {
        let app = AXUIElementCreateApplication(pid)
        guard let menuBar = attr(app, kAXMenuBarAttribute) else { return "This app has no menu bar I can reach." }
        var current = menuBar as! AXUIElement
        for (i, name) in path.enumerated() {
            var items = children(current)
            // Menu bar items and menu items hold their items inside an AXMenu child.
            if items.count == 1, string(items[0], kAXRoleAttribute) == "AXMenu" { items = children(items[0]) }
            guard let item = items.first(where: { (string($0, kAXTitleAttribute) ?? "").lowercased() == name.lowercased() })
                    ?? items.first(where: { (string($0, kAXTitleAttribute) ?? "").lowercased().hasPrefix(name.lowercased()) })
            else {
                let names = items.compactMap { string($0, kAXTitleAttribute) }.prefix(25).joined(separator: ", ")
                return "No menu item \"\(name)\". Items here: \(names)"
            }
            if i == path.count - 1 {
                return press(item) ? "Chose \(path.joined(separator: " > "))." : "Could not press \(name)."
            }
            current = item
        }
        return "Empty menu path."
    }
}

/// One item in a window's accessibility tree that Muse can read or act on.
struct UIItem {
    let id: Int
    let role: String
    let label: String
    let value: String?
    let element: AXUIElement

    var line: String {
        var s = "[\(id)] \(role.replacingOccurrences(of: "AX", with: "").lowercased()) \"\(label)\""
        if let v = value, !v.isEmpty, v != label { s += " value=\"\(v.prefix(80))\"" }
        return s
    }
}

enum UITree {
    static let actionable: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXLink",
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSlider", "AXTab", "AXDisclosureTriangle",
    ]

    /// Walks the window's tree and returns up to `limit` labelled items, plus visible text for reading.
    static func collect(window: AXUIElement, limit: Int = 150) -> (items: [UIItem], text: String) {
        var items: [UIItem] = []
        var texts: [String] = []
        var textLength = 0
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty && visited < 4000 {
            let (el, depth) = queue.removeFirst()
            visited += 1
            let role = AX.string(el, kAXRoleAttribute) ?? ""
            let title = AX.string(el, kAXTitleAttribute)
            let desc = AX.string(el, kAXDescriptionAttribute)
            let value = (AX.attr(el, kAXValueAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let help = AX.string(el, kAXHelpAttribute)

            if actionable.contains(role), items.count < limit {
                let label = title ?? desc ?? help ?? (role == "AXTextField" || role == "AXTextArea" ? "text field" : nil)
                if let label = label {
                    items.append(UIItem(id: items.count + 1, role: role, label: String(label.prefix(80)), value: value, element: el))
                }
            }
            if role == "AXStaticText" || role == "AXTextArea", let v = value ?? title, !v.isEmpty, textLength < 6000 {
                texts.append(String(v.prefix(500)))
                textLength += min(v.count, 500)
            }
            if depth < 25 {
                for child in AX.children(el) { queue.append((child, depth + 1)) }
            }
        }
        return (items, texts.joined(separator: "\n"))
    }
}

/// Key presses like "cmd+t", "space", "shift+cmd+n", "return".
/// A key combination as Glance reads it: "Command + Q", "cmd+q" and "q+cmd" are the same combination.
/// Keys.press and the confirmation rule both read combinations through this, so they cannot disagree.
struct KeyCombo: Equatable {
    var modifiers: Set<String> = []     // "cmd", "shift", "option", "ctrl"
    var key = ""

    private static let aliases = ["command": "cmd", "⌘": "cmd", "opt": "option", "alt": "option", "⌥": "option",
                                  "control": "ctrl", "⌃": "ctrl", "⇧": "shift", "enter": "return", "esc": "escape",
                                  "backspace": "delete"]

    init(_ combo: String) {
        for raw in combo.lowercased().split(separator: "+") {
            let part = raw.trimmingCharacters(in: .whitespaces)
            let name = KeyCombo.aliases[part] ?? part
            if ["cmd", "shift", "option", "ctrl"].contains(name) { modifiers.insert(name) } else if !name.isEmpty { key = name }
        }
    }
}

enum Keys {
    private static let codes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
        "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
        "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
        "p": 35, "l": 37, "j": 38, "k": 40, ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
        "left": 123, "right": 124, "down": 125, "up": 126, "pageup": 116, "pagedown": 121, "home": 115, "end": 119,
    ]

    static func press(_ combo: String) -> Bool {
        let parsed = KeyCombo(combo)
        var flags = CGEventFlags()
        if parsed.modifiers.contains("cmd") { flags.insert(.maskCommand) }
        if parsed.modifiers.contains("shift") { flags.insert(.maskShift) }
        if parsed.modifiers.contains("option") { flags.insert(.maskAlternate) }
        if parsed.modifiers.contains("ctrl") { flags.insert(.maskControl) }
        guard let code = codes[parsed.key],
              let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { return false }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
