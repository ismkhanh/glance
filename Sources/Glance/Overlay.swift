import AppKit
import ApplicationServices

/// An element on screen that the app shares through accessibility.
struct PointedElement {
    let role: String
    let label: String
    let frame: CGRect          // global, origin top-left (same space as window bounds)
    let element: AXUIElement
    /// True when the pointer is near it, not on it, and Glance snapped to it.
    var snapped = false

    var isActionable: Bool { UITree.actionable.contains(role) }

    /// "AXPopUpButton" → "pop up button", "AXStaticText" → "text".
    var kind: String {
        if role == "AXStaticText" { return "text" }
        var words = ""
        for ch in role.hasPrefix("AX") ? String(role.dropFirst(2)) : role {
            if ch.isUppercase && !words.isEmpty { words.append(" ") }
            words.append(ch)
        }
        return words.isEmpty ? "element" : words.lowercased()
    }

    var summary: String {
        label.isEmpty ? kind : "\(kind) \"\(label.prefix(100))\""
    }

    /// Short text for the tag shown next to the highlight.
    var tagText: String {
        let short = label.replacingOccurrences(of: "\n", with: " ")
        let text = short.isEmpty ? kind : (short.count > 48 ? "\(kind): \(short.prefix(45))…" : "\(kind): \(short)")
        return snapped ? "↪ " + text : text
    }

    /// Same element on screen (same kind and place).
    static func same(_ a: PointedElement?, _ b: PointedElement?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.role == y.role && x.frame == y.frame
        default: return false
        }
    }
}

/// What the user is pointing at right now.
struct Attention {
    var window: TargetWindow?
    var element: PointedElement?
    /// Clickables near the pointer, numbered 1… on screen while you talk. The highlighted one comes first.
    var nearby: [PointedElement] = []
}

/// The latest attention, written by the highlighter (main thread) and read by the talk key (background).
final class AttentionBox: @unchecked Sendable {
    static let shared = AttentionBox()
    private let lock = NSLock()
    private var value = Attention()

    func set(_ value: Attention) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Attention {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum ElementLocator {
    private static let worthHighlighting: Set<String> = UITree.actionable.union([
        "AXStaticText", "AXImage", "AXHeading", "AXCell", "AXRow", "AXMenuItem", "AXMenuBarItem", "AXListItem",
    ])
    private static var prepared = Set<pid_t>()   // only used on the highlight queue
    private static let quick: Float = 0.15        // seconds; a slow app never stalls the highlight for long

    /// The most useful element exactly at a point: a button or link if the point is inside one, else text or an image.
    /// Call it from a background queue: it asks the app over accessibility.
    static func element(at point: CGPoint, in window: TargetWindow) -> PointedElement? {
        let app = AXUIElementCreateApplication(window.pid)
        _ = AXUIElementSetMessagingTimeout(app, quick)
        if !prepared.contains(window.pid) {
            prepared.insert(window.pid)
            _ = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        }
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              let first = hit else { return nil }

        // Walk up a few levels: prefer something you can press, else the first readable thing.
        var chain: [(AXUIElement, String)] = []
        var current: AXUIElement? = first
        while let el = current, chain.count < 7 {
            _ = AXUIElementSetMessagingTimeout(el, quick)
            chain.append((el, AX.string(el, kAXRoleAttribute) ?? ""))
            current = AX.attr(el, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        guard let pick = chain.first(where: { UITree.actionable.contains($0.1) })
                ?? chain.first(where: { worthHighlighting.contains($0.1) }) else { return nil }
        let (el, role) = pick
        defer {
            // Pressing it later must wait as long as it needs, or a slow press looks like a failure.
            _ = AXUIElementSetMessagingTimeout(el, 0)
        }

        guard let pos = AX.point(el, kAXPositionAttribute), let size = AX.size(el, kAXSizeAttribute),
              size.width >= 4, size.height >= 4 else { return nil }
        let frame = CGRect(origin: pos, size: size)
        // Something as big as the window is not a specific element.
        if frame.width * frame.height > 0.6 * window.bounds.width * window.bounds.height { return nil }

        let value = (AX.attr(el, kAXValueAttribute) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = AX.string(el, kAXTitleAttribute)
            ?? AX.string(el, kAXDescriptionAttribute)
            ?? value.flatMap { $0.isEmpty ? nil : String($0.prefix(160)) }
            ?? AX.string(el, kAXHelpAttribute)
            ?? ""
        return PointedElement(role: role, label: label, frame: frame, element: el)
    }
}

enum Screens {
    /// Global CoreGraphics rect (origin top-left) → AppKit rect (origin bottom-left of the main screen).
    static func cocoa(_ cg: CGRect) -> NSRect {
        let height = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: cg.minX, y: height - cg.maxY, width: cg.width, height: cg.height)
    }

    /// A borderless window above everything, that clicks pass through.
    static func overlayWindow(shadow: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = shadow
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        return window
    }
}

/// A glowing frame around a window or an element.
final class Glow {
    private let window = Screens.overlayWindow(shadow: false)
    private let box = NSView()
    private let lineWidth: CGFloat
    private let pad: CGFloat = 12
    private var lastFrame = CGRect.null
    private var lastColor: NSColor?

    init(lineWidth: CGFloat, radius: CGFloat) {
        self.lineWidth = lineWidth
        let content = NSView()
        content.wantsLayer = true
        window.contentView = content
        box.wantsLayer = true
        box.layer?.borderWidth = lineWidth
        box.layer?.cornerRadius = radius
        box.layer?.shadowOpacity = 0.9
        box.layer?.shadowRadius = 7
        box.layer?.shadowOffset = .zero
        content.addSubview(box)
    }

    func show(_ cgFrame: CGRect, color: NSColor) {
        if cgFrame == lastFrame && color == lastColor && window.isVisible { return }
        lastFrame = cgFrame
        lastColor = color
        let r = Screens.cocoa(cgFrame)
        window.setFrame(r.insetBy(dx: -pad, dy: -pad), display: false)
        box.frame = NSRect(x: pad - lineWidth, y: pad - lineWidth,
                           width: r.width + 2 * lineWidth, height: r.height + 2 * lineWidth)
        box.layer?.borderColor = color.cgColor
        box.layer?.shadowColor = color.cgColor
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
        lastFrame = .null
    }
}

/// A small coloured name tag just above the highlighted element: what "this" means right now.
final class Tag {
    private let window = Screens.overlayWindow(shadow: true)
    private let label = NSTextField(labelWithString: "")
    private var lastText = ""
    private var lastFrame = CGRect.null
    private var lastColor: NSColor?

    init() {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 5
        window.contentView = content
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        content.addSubview(label)
    }

    func show(_ text: String, above cgFrame: CGRect, color: NSColor) {
        if text == lastText && cgFrame == lastFrame && color == lastColor && window.isVisible { return }
        lastText = text
        lastFrame = cgFrame
        lastColor = color
        label.stringValue = text
        let fit = label.intrinsicContentSize
        let width = min(320, ceil(fit.width) + 14)
        let height = ceil(fit.height) + 6
        label.frame = NSRect(x: 7, y: 3, width: width - 14, height: ceil(fit.height))

        let r = Screens.cocoa(cgFrame)
        var origin = NSPoint(x: r.minX - 2, y: r.maxY + 6)          // just above the element
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(r) }) ?? NSScreen.main {
            let v = screen.frame
            if origin.y + height > v.maxY - 2 { origin.y = r.minY - height - 6 }   // no room above: go below
            origin.x = min(max(origin.x, v.minX + 4), v.maxX - width - 4)
            origin.y = max(origin.y, v.minY + 4)
        }
        window.contentView?.layer?.backgroundColor = color.withAlphaComponent(0.92).cgColor
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        if !window.isVisible { window.orderFrontRegardless() }
    }

    func hide() {
        if window.isVisible { window.orderOut(nil) }
        lastFrame = .null
    }
}

/// Round number badges (1, 2, 3…) left of the clickables near the pointer, shown while you talk,
/// so "click two" or "the one on the left" can pick between close buttons.
final class Badges {
    private var pool: [(NSWindow, NSTextField)] = []
    private let size: CGFloat = 18

    func show(_ elements: [PointedElement], color: NSColor) {
        while pool.count < elements.count { pool.append(makeBadge()) }
        for (i, (window, label)) in pool.enumerated() {
            guard i < elements.count else {
                window.orderOut(nil)
                continue
            }
            let r = Screens.cocoa(elements[i].frame)
            var origin = NSPoint(x: r.minX - size - 3, y: r.midY - size / 2)
            if let screen = NSScreen.screens.first(where: { $0.frame.intersects(r) }) ?? NSScreen.main {
                let v = screen.frame
                origin.x = min(max(origin.x, v.minX + 2), v.maxX - size - 2)
                origin.y = min(max(origin.y, v.minY + 2), v.maxY - size - 2)
            }
            label.stringValue = "\(i + 1)"
            window.contentView?.layer?.backgroundColor = color.cgColor
            window.setFrame(NSRect(origin: origin, size: NSSize(width: size, height: size)), display: true)
            window.orderFrontRegardless()
        }
    }

    func hide() {
        for (window, _) in pool { window.orderOut(nil) }
    }

    private func makeBadge() -> (NSWindow, NSTextField) {
        let window = Screens.overlayWindow(shadow: true)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        content.wantsLayer = true
        content.layer?.cornerRadius = size / 2
        window.contentView = content
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 11, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: (size - 15) / 2, width: size, height: 15)
        content.addSubview(label)
        return (window, label)
    }
}

/// A small dark bubble in the corner of the target window: what Glance heard, is doing, or answers.
final class Bubble {
    private let window = Screens.overlayWindow(shadow: true)
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideWork: DispatchWorkItem?
    private let maxWidth: CGFloat = 380

    init() {
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        window.contentView = effect
        label.textColor = .white
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.maximumNumberOfLines = 8
        effect.addSubview(label)
    }

    func show(_ text: String, near cgFrame: CGRect, hideAfter seconds: Double? = nil) {
        label.stringValue = text
        label.preferredMaxLayoutWidth = maxWidth - 28
        let fit = label.sizeThatFits(NSSize(width: maxWidth - 28, height: 600))
        let width = min(maxWidth, max(180, fit.width + 28))
        let height = fit.height + 22
        label.frame = NSRect(x: 14, y: 11, width: width - 28, height: fit.height)

        let r = Screens.cocoa(cgFrame)
        var origin = NSPoint(x: r.maxX - width - 18, y: r.maxY - height - 18)   // top-right, inside the window
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(r) }) ?? NSScreen.main {
            let v = screen.visibleFrame
            origin.x = min(max(origin.x, v.minX + 8), v.maxX - width - 8)
            origin.y = min(max(origin.y, v.minY + 8), v.maxY - height - 8)
        }
        window.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: true)
        window.orderFrontRegardless()

        hideWork?.cancel()
        hideWork = nil
        if let s = seconds {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: work)
        }
    }

    func hide() {
        window.orderOut(nil)
    }
}

/// One card per command, at the top-right of the window it is for: what you said, then Muse's question or reply.
/// Commands run side by side, so several windows can show their own card at once. Main thread only.
final class TaskCards {
    private var cards: [String: Bubble] = [:]

    func show(_ id: String, _ text: String, near frame: CGRect, hideAfter seconds: Double? = nil) {
        let bubble = cards[id] ?? Bubble()
        cards[id] = bubble
        bubble.show(text, near: frame, hideAfter: seconds)
    }
}

/// Point → find → snap → confirm, drawn live. Follows the pointer (mouse, or your head with macOS Head pointer):
/// a glow on the window under it, and a smaller glow with a name tag on the clickable it is on or near (snap).
/// While you talk, the clickables around it get numbers. Main thread only.
///
/// Two background lookups keep the glow smooth: the exact element under the pointer (fast, often), and the list
/// of all clickables in the window (one tree walk, refreshed now and then). A new choice must hold for a moment
/// before the glow moves, so Head pointer's small shake does not make it jump between neighbours.
final class Highlighter: NSObject {
    enum Mode {
        case following, listening, working, asking
    }

    var enabled = true
    private(set) var mode: Mode = .following
    private let windowGlow = Glow(lineWidth: 3, radius: 12)
    private let elementGlow = Glow(lineWidth: 2, radius: 6)
    private let tag = Tag()
    private let badges = Badges()
    private let bubble = Bubble()
    private let probes = DispatchQueue(label: "glance.highlight.probe")
    private let walks = DispatchQueue(label: "glance.highlight.walk")
    private let dwell = 0.12          // seconds a new choice must hold before the glow moves
    private var timer: Timer?

    private var lastPointer = CGPoint(x: -10_000, y: -10_000)
    private var lastMoveAt = 0.0
    private var lastWindowCheck = 0.0
    private var current: TargetWindow?

    private var probe: PointedElement?          // exact element under the pointer, from the last probe
    private var probing = false
    private var lastProbeAt = 0.0
    private var clickables: [PointedElement] = []
    private var clickablesWindow: CGWindowID?
    private var clickablesAt = 0.0
    private var walking = false
    private var walkStartedAt = 0.0

    private var currentElement: PointedElement?
    private var candidate: PointedElement?
    private var candidateSince = 0.0
    private var hasCandidate = false

    private var locked: TargetWindow?
    private var lockedElement: PointedElement?
    private var lockedNearby: [PointedElement] = []

    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    func start() {
        let t = Timer(timeInterval: 1.0 / 30.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        if let w = locked {
            draw(w, lockedElement)
            return
        }
        let p = WindowLocator.pointer()
        let now = Highlighter.now
        let moved = hypot(p.x - lastPointer.x, p.y - lastPointer.y) > 1
        if moved { lastMoveAt = now }
        lastPointer = p
        if moved || now - lastWindowCheck > 0.5 {
            let w = WindowLocator.windowUnderPointer()
            if w?.windowID != current?.windowID {
                probe = nil
                currentElement = nil
                hasCandidate = false
                clickables = []
                clickablesWindow = nil
            }
            current = w
            lastWindowCheck = now
        }
        guard enabled else {
            windowGlow.hide()
            elementGlow.hide()
            tag.hide()
            AttentionBox.shared.set(Attention(window: current))
            return
        }
        guard let w = current else {
            draw(nil, nil)
            AttentionBox.shared.set(Attention())
            return
        }
        if FigmaPointer.isFigma(w) {
            // Figma draws its own outline on the layer under the pointer, and the talk key asks Figma which
            // layer that is. Glance only glows around the window here.
            currentElement = nil
            hasCandidate = false
            AttentionBox.shared.set(Attention(window: w))
            draw(w, nil)
            return
        }

        // Find, part 1: the exact element under the pointer.
        if !probing, now - lastProbeAt > 0.05, moved || hasCandidate || now - lastProbeAt > 0.5 {
            probing = true
            lastProbeAt = now
            probes.async { [weak self] in
                let found = ElementLocator.element(at: p, in: w)
                DispatchQueue.main.async { [weak self] in self?.probed(found, in: w) }
            }
        }
        // Find, part 2: every clickable in the window, for snapping to the nearest one.
        let stale = clickablesWindow != w.windowID || (now - clickablesAt > 1.5 && now - lastMoveAt < 1.0)
        if !walking, stale, now - walkStartedAt > 0.3 {
            walking = true
            walkStartedAt = now
            walks.async { [weak self] in
                let list = Clickables.collect(in: w)
                DispatchQueue.main.async { [weak self] in self?.walked(list, in: w) }
            }
        }

        // Snap, with a short hold so the glow does not flicker between neighbours.
        let choice = Snap.choose(at: p, probe: probe, clickables: clickables)
        if PointedElement.same(choice, currentElement) {
            currentElement = choice          // same element; keeps the newest label and snap state
            hasCandidate = false
        } else if hasCandidate && PointedElement.same(choice, candidate) {
            if now - candidateSince >= dwell {
                currentElement = choice
                hasCandidate = false
            }
        } else {
            candidate = choice
            candidateSince = now
            hasCandidate = true
        }

        let nearby = Snap.nearby(at: p, chosen: currentElement, clickables: clickables)
        AttentionBox.shared.set(Attention(window: w, element: currentElement, nearby: nearby))
        draw(w, currentElement)
    }

    private func probed(_ found: PointedElement?, in window: TargetWindow) {
        probing = false
        guard window.windowID == current?.windowID else { return }
        probe = found
        // A clickable the list does not know yet means the window changed (new page, scrolled): read it again soon.
        if let f = found, f.isActionable, !clickables.contains(where: { PointedElement.same($0, f) }) {
            clickablesAt = 0
        }
    }

    private func walked(_ list: [PointedElement], in window: TargetWindow) {
        walking = false
        guard window.windowID == current?.windowID else { return }
        clickables = list
        clickablesWindow = window.windowID
        clickablesAt = Highlighter.now
    }

    private var color: NSColor {
        switch mode {
        case .following: return .systemBlue
        case .listening: return .systemGreen
        case .working: return .systemPurple
        case .asking: return .systemOrange
        }
    }

    private func draw(_ window: TargetWindow?, _ element: PointedElement?) {
        if let w = window {
            windowGlow.show(w.bounds, color: color)
        } else {
            windowGlow.hide()
        }
        if let e = element {
            elementGlow.show(e.frame, color: color)
            tag.show(e.tagText, above: e.frame, color: color)
        } else {
            elementGlow.hide()
            tag.hide()
        }
    }

    private func showBadges() {
        if lockedNearby.count >= 2 {
            badges.show(lockedNearby, color: color)
        } else {
            badges.hide()
        }
    }

    // MARK: - Called by Glance (on the main thread)

    func lock(_ target: TargetWindow, _ element: PointedElement?, _ nearby: [PointedElement] = []) {
        locked = target
        lockedElement = element
        lockedNearby = nearby
        mode = .listening
        showBadges()
        var text = element.map { "Listening… (this = \($0.summary))" } ?? "Listening…"
        if nearby.count >= 2 { text += "\nSay a number to pick another one." }
        bubble.show(text, near: target.bounds)
    }

    /// Muse picked another numbered element: the glow moves there before anything is clicked.
    func pick(_ element: PointedElement) {
        guard locked != nil else { return }
        lockedElement = element
    }

    func listeningForAnswer() {
        mode = .listening
        showBadges()
        if let w = locked { bubble.show("Listening for yes or no…", near: w.bounds) }
    }

    func heard(_ text: String) {
        if let w = locked { bubble.show("“\(text)”", near: w.bounds) }
    }

    func working(_ text: String) {
        mode = .working
        showBadges()
        if let w = locked { bubble.show(text, near: w.bounds) }
    }

    func asking(_ question: String) {
        mode = .asking
        showBadges()
        if let w = locked {
            bubble.show("\(question)\nHold the talk key and say yes or no.", near: w.bounds)
        }
    }

    func finish(_ reply: String?) {
        mode = .following
        if let w = locked, let r = reply {
            bubble.show(r, near: w.bounds, hideAfter: 6)
        } else {
            bubble.hide()
        }
        badges.hide()
        locked = nil
        lockedElement = nil
        lockedNearby = []
        lastWindowCheck = 0
        lastProbeAt = 0
        clickablesAt = 0          // the command may have changed the window: read its clickables again
        lastMoveAt = Highlighter.now
        hasCandidate = false
    }
}
