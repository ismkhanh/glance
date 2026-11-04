import AppKit

// The task side of Glance on screen: question tooltips where you pointed, short toasts, the mascot,
// and the task panel (pause / resume / edit / cancel / undo). All of it runs on the main thread,
// except QuestionTips.taskUnderPointer(), which the talk key calls from its own queue.

// AppKit subclasses here only override AppKit methods; they keep no state of their own. Their state lives in
// plain objects, so non-UI code never touches members of a main-thread class.

/// A borderless panel that can take clicks (and typing) without bringing Glance to the front.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

func floatingPanel(size: NSSize) -> FloatingPanel {
    let p = FloatingPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = true
    p.level = .statusBar
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    p.hidesOnDeactivate = false
    p.isReleasedWhenClosed = false
    p.becomesKeyOnlyIfNeeded = true
    return p
}

/// A button that works on the first click, even when Glance is not the front app.
final class ActionButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A button whose identifier carries "task id|value", read back with `buttonInfo`.
private func actionButton(_ title: String, taskId: String, value: String, target: AnyObject, action: Selector) -> NSButton {
    let b = ActionButton(title: title, target: target, action: action)
    b.identifier = NSUserInterfaceItemIdentifier("\(taskId)|\(value)")
    b.bezelStyle = .rounded
    return b
}

private func buttonInfo(_ sender: NSButton) -> (taskId: String, value: String) {
    let raw = sender.identifier?.rawValue ?? "|"
    guard let bar = raw.firstIndex(of: "|") else { return (raw, "") }
    return (String(raw[..<bar]), String(raw[raw.index(after: bar)...]))
}

private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor,
                   wrap: CGFloat? = nil) -> NSTextField {
    let field = wrap == nil ? NSTextField(labelWithString: text) : NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    if let width = wrap {
        field.preferredMaxLayoutWidth = width
        field.maximumNumberOfLines = 4
    } else {
        field.lineBreakMode = .byTruncatingTail
    }
    return field
}

private func card(_ content: NSView, inset: CGFloat = 12) -> NSVisualEffectView {
    let effect = NSVisualEffectView()
    effect.material = .popover
    effect.state = .active
    effect.blendingMode = .behindWindow
    effect.wantsLayer = true
    effect.layer?.cornerRadius = 12
    effect.layer?.masksToBounds = true
    content.translatesAutoresizingMaskIntoConstraints = false
    effect.addSubview(content)
    NSLayoutConstraint.activate([
        content.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: inset),
        content.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -inset),
        content.topAnchor.constraint(equalTo: effect.topAnchor, constant: inset),
        content.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -inset),
    ])
    return effect
}

/// Screen point (CoreGraphics, origin top-left) → AppKit point (origin bottom-left of the main screen).
private func cocoaPoint(_ p: CGPoint) -> NSPoint {
    NSPoint(x: p.x, y: (NSScreen.screens.first?.frame.height ?? 0) - p.y)
}

private func clamp(_ frame: NSRect, near point: NSPoint) -> NSRect {
    guard let screen = NSScreen.screens.first(where: { NSPointInRect(point, $0.frame) }) ?? NSScreen.main else { return frame }
    let v = screen.visibleFrame
    var f = frame
    f.origin.x = min(max(f.origin.x, v.minX + 8), v.maxX - f.width - 8)
    f.origin.y = min(max(f.origin.y, v.minY + 8), v.maxY - f.height - 8)
    return f
}

// MARK: - Question tooltips

/// A worker's question, next to where you pointed, with its options and its recommendation.
/// Click an option, or point at the tooltip, hold the talk key and say the answer.
final class QuestionTips: NSObject {
    var onAnswer: ((String, String) -> Void)?          // task id, answer
    private var panels: [String: FloatingPanel] = [:]
    private var lastAsk: [String: [String: Any]] = [:]
    private let lock = NSLock()
    private var frames: [String: CGRect] = [:]          // CoreGraphics coordinates, read from any thread

    func show(_ ask: [String: Any]) {
        guard let taskId = ask["taskId"] as? String else { return }
        hide(taskId)
        lastAsk[taskId] = ask
        let question = ask["question"] as? String ?? "Which one?"
        let options = (ask["options"] as? [String]) ?? []
        let recommended = ask["recommended"] as? String
        let reason = ask["reason"] as? String
        let title = ask["title"] as? String ?? ""

        var rows: [NSView] = []
        if !title.isEmpty { rows.append(label("Glance · \(title)", size: 11, color: .secondaryLabelColor)) }
        rows.append(label(question, size: 14, weight: .semibold, wrap: 300))
        if let r = recommended {
            let why = (reason ?? "").isEmpty ? "" : " — \(reason!)"
            rows.append(label("I recommend \(r)\(why)", size: 12, color: .secondaryLabelColor, wrap: 300))
        }
        var buttons: [NSView] = []
        for option in options {
            let b = actionButton(option == recommended ? "\(option) ★" : option, taskId: taskId, value: option,
                                 target: self, action: #selector(choose(_:)))
            if option == recommended { b.bezelColor = .controlAccentColor }
            buttons.append(b)
        }
        buttons.append(actionButton("Later", taskId: taskId, value: "", target: self, action: #selector(later(_:))))
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 6
        rows.append(buttonRow)
        rows.append(label("…or point here, hold the talk key and say it.", size: 11, color: .tertiaryLabelColor))

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let content = card(stack)
        let size = content.fittingSize
        let panel = floatingPanel(size: size)
        panel.contentView = content

        // Below and to the right of where you pointed; other open questions push it further down.
        let anchor = ask["anchor"] as? [String: Any]
        let at = CGPoint(x: (anchor?["x"] as? Double) ?? Double(WindowLocator.pointer().x),
                         y: (anchor?["y"] as? Double) ?? Double(WindowLocator.pointer().y))
        let p = cocoaPoint(at)
        var frame = clamp(NSRect(x: p.x + 16, y: p.y - 16 - size.height, width: size.width, height: size.height), near: p)
        for other in panels.values where other.frame.intersects(frame) {
            frame.origin.y = other.frame.minY - size.height - 8
        }
        frame = clamp(frame, near: p)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        panels[taskId] = panel

        let primary = NSScreen.screens.first?.frame.height ?? 0
        let onScreen = CGRect(x: frame.minX, y: primary - frame.maxY, width: frame.width, height: frame.height)
        lock.lock()
        frames[taskId] = onScreen
        lock.unlock()
        print(String(format: "\nQuestion: %@  (card at %.0f, %.0f)", question, onScreen.midX, onScreen.midY))
    }

    /// Shows a task's question again (from the task panel).
    func showAgain(_ taskId: String) {
        if let ask = lastAsk[taskId] { show(ask) }
    }

    func hide(_ taskId: String) {
        panels[taskId]?.orderOut(nil)
        panels[taskId] = nil
        lock.lock()
        frames[taskId] = nil
        lock.unlock()
    }

    func forget(_ taskId: String) {
        hide(taskId)
        lastAsk[taskId] = nil
    }

    /// The task whose tooltip is under the pointer. Safe from any thread.
    func taskUnderPointer() -> String? {
        let p = WindowLocator.pointer()
        lock.lock()
        defer { lock.unlock() }
        return frames.first { $0.value.insetBy(dx: -6, dy: -6).contains(p) }?.key
    }

    @objc private func choose(_ sender: NSButton) {
        let info = buttonInfo(sender)
        onAnswer?(info.taskId, info.value)
        hide(info.taskId)
    }

    @objc private func later(_ sender: NSButton) {
        hide(buttonInfo(sender).taskId)
    }
}

// MARK: - Toast

/// A short note where a task started: "✓ turn it red: Done." Goes away by itself.
final class Toast {
    private let panel = floatingPanel(size: NSSize(width: 200, height: 40))
    private let text = label("", size: 13, weight: .medium, wrap: 300)
    private var hideWork: DispatchWorkItem?

    init() {
        panel.ignoresMouseEvents = true
        panel.contentView = card(text, inset: 10)
    }

    func show(_ message: String, at anchor: CGPoint?) {
        text.stringValue = message
        let size = panel.contentView?.fittingSize ?? NSSize(width: 200, height: 40)
        let p = cocoaPoint(anchor ?? WindowLocator.pointer())
        panel.setFrame(clamp(NSRect(x: p.x + 16, y: p.y + 16, width: size.width, height: size.height), near: p), display: true)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

// MARK: - Mascot

/// Glance's mascot: a round friend with one big eye. The eye is closed while Glance is not listening, and opens and
/// glances at your pointer while it is (talk key held, or a hands-free session). Click it for the task list; drag it
/// anywhere. The badge counts running tasks (orange when one is waiting for your answer).
final class MascotModel {
    static let shared = MascotModel()
    var onClick: (() -> Void)?
    var look = CGPoint.zero              // -1…1 in each direction
    var running = 0
    var asking = false
    var connected = false
    var awake = false                    // Glance is listening
    var blinking = false
    var dragStart: NSPoint?
    var moved = false
}

final class MascotView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let m = MascotModel.shared
        let look = m.look
        let b = bounds.insetBy(dx: 6, dy: 6)
        let body = NSBezierPath(ovalIn: b)
        NSGradient(starting: NSColor(calibratedRed: 0.36, green: 0.36, blue: 0.97, alpha: 1),
                   ending: NSColor(calibratedRed: 0.62, green: 0.36, blue: 0.97, alpha: 1))?.draw(in: body, angle: -60)
        (m.connected ? NSColor.systemGreen : NSColor.systemGray).setStroke()
        body.lineWidth = 2
        body.stroke()

        let eyeCenter = NSPoint(x: b.midX, y: b.midY + b.height * 0.04)
        let eyeR = b.width * 0.30
        if !m.awake {
            // Asleep: a closed eye, curved like a smile.
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: eyeCenter.x - eyeR * 0.8, y: eyeCenter.y + eyeR * 0.1))
            lid.curve(to: NSPoint(x: eyeCenter.x + eyeR * 0.8, y: eyeCenter.y + eyeR * 0.1),
                      controlPoint1: NSPoint(x: eyeCenter.x - eyeR * 0.4, y: eyeCenter.y - eyeR * 0.45),
                      controlPoint2: NSPoint(x: eyeCenter.x + eyeR * 0.4, y: eyeCenter.y - eyeR * 0.45))
            lid.lineWidth = 3
            lid.lineCapStyle = .round
            NSColor.white.setStroke()
            lid.stroke()
        } else if m.blinking {
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: eyeCenter.x - eyeR, y: eyeCenter.y))
            lid.line(to: NSPoint(x: eyeCenter.x + eyeR, y: eyeCenter.y))
            lid.lineWidth = 3
            lid.lineCapStyle = .round
            NSColor.white.setStroke()
            lid.stroke()
        } else {
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: eyeCenter.x - eyeR, y: eyeCenter.y - eyeR, width: eyeR * 2, height: eyeR * 2)).fill()
            let pupilR = eyeR * 0.45
            let pupil = NSPoint(x: eyeCenter.x + look.x * eyeR * 0.45, y: eyeCenter.y + look.y * eyeR * 0.45)
            NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: pupil.x - pupilR, y: pupil.y - pupilR, width: pupilR * 2, height: pupilR * 2)).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: pupil.x + pupilR * 0.2, y: pupil.y + pupilR * 0.25, width: pupilR * 0.5, height: pupilR * 0.5)).fill()
        }

        if m.running > 0 {
            let badge = NSRect(x: bounds.maxX - 22, y: bounds.maxY - 22, width: 20, height: 20)
            (m.asking ? NSColor.systemOrange : NSColor.systemBlue).setFill()
            NSBezierPath(ovalIn: badge).fill()
            let text = "\(min(m.running, 9))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2), withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        MascotModel.shared.dragStart = event.locationInWindow
        MascotModel.shared.moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        let m = MascotModel.shared
        guard let start = m.dragStart, let window = window else { return }
        let now = event.locationInWindow
        let dx = now.x - start.x
        let dy = now.y - start.y
        if abs(dx) + abs(dy) > 2 { m.moved = true }
        window.setFrameOrigin(NSPoint(x: window.frame.origin.x + dx, y: window.frame.origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        let m = MascotModel.shared
        if !m.moved { m.onClick?() }
        m.dragStart = nil
    }
}

final class Mascot: NSObject {
    let panel = floatingPanel(size: NSSize(width: 64, height: 64))
    let view = MascotView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    private var timer: Timer?
    private var nextBlink = Date().addingTimeInterval(3)

    func show() {
        panel.contentView = view
        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: v.maxX - 84, y: v.minY + 24))
        }
        panel.orderFrontRegardless()
        let t = Timer(timeInterval: 1.0 / 20.0, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc private func tick() {
        let mouse = NSEvent.mouseLocation
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let dx = mouse.x - c.x
        let dy = mouse.y - c.y
        let d = max(1, hypot(dx, dy))
        let reach = min(1, d / 250)
        let m = MascotModel.shared
        m.look = CGPoint(x: dx / d * reach, y: dy / d * reach)
        let now = Date()
        if now >= nextBlink {
            m.blinking = true
            nextBlink = now.addingTimeInterval(Double.random(in: 2.5...5.5))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) { [weak self] in
                MascotModel.shared.blinking = false
                self?.view.needsDisplay = true
            }
        }
        view.needsDisplay = true
    }
}

// MARK: - Task panel

/// The list of tasks, newest first, with buttons for each. Opens above the mascot.
final class TaskPanel: NSObject {
    var onControl: ((String, String) -> Void)?        // task id, pause | resume | cancel | undo | retry
    var onEdit: ((String, String) -> Void)?           // task id, new words
    var onShowQuestion: ((String) -> Void)?
    var onToggleSpeech: (() -> Void)?
    var speaking = false {
        didSet { if isShown { rebuild() } }
    }
    private let panel = floatingPanel(size: NSSize(width: 380, height: 120))
    private var tasks: [[String: Any]] = []
    private var status = "Starting…"
    private var editing: String?
    private var editField: NSTextField?
    private weak var anchor: NSWindow?
    private(set) var isShown = false
    private let width: CGFloat = 380

    func toggle(above window: NSWindow) {
        anchor = window
        isShown.toggle()
        if isShown {
            rebuild()
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
            editing = nil
        }
    }

    func update(_ tasks: [[String: Any]]) {
        self.tasks = tasks
        if isShown { rebuild() }
    }

    func setStatus(_ text: String) {
        status = text
        if isShown { rebuild() }
    }

    private static func statusText(_ s: String) -> (String, NSColor) {
        switch s {
        case "queued": return ("Waiting", .secondaryLabelColor)
        case "running": return ("Working", .systemBlue)
        case "asking": return ("Needs your answer", .systemOrange)
        case "paused": return ("Paused", .systemGray)
        case "verifying": return ("Checking", .systemPurple)
        case "done": return ("Done", .systemGreen)
        case "failed": return ("Failed", .systemRed)
        case "cancelled": return ("Cancelled", .tertiaryLabelColor)
        case "reverted": return ("Undone", .tertiaryLabelColor)
        default: return (s, .secondaryLabelColor)
        }
    }

    private func button(_ title: String, _ taskId: String, _ value: String) -> NSButton {
        let b = actionButton(title, taskId: taskId, value: value, target: self, action: #selector(tapped(_:)))
        b.controlSize = .small
        b.font = .systemFont(ofSize: 11)
        return b
    }

    private func row(_ t: [String: Any]) -> NSView {
        let id = t["id"] as? String ?? ""
        let state = t["status"] as? String ?? ""
        let (stateText, color) = TaskPanel.statusText(state)
        let target = (t["target"] as? [String: Any])?["name"] as? String

        let dot = label("●", size: 12, color: color)
        let title = label(t["title"] as? String ?? "", size: 13, weight: .semibold)
        let head = NSStackView(views: [dot, title])
        head.spacing = 6
        var lines: [NSView] = [head]
        lines.append(label([stateText, target].compactMap { $0 }.joined(separator: " · "), size: 11, color: color))

        if editing == id {
            let field = NSTextField(string: t["instruction"] as? String ?? "")
            field.font = .systemFont(ofSize: 12)
            field.target = self
            field.action = #selector(saveEdit(_:))
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: width - 40).isActive = true
            editField = field
            lines.append(field)
            let save = button("Save", id, "save")
            let discard = button("Don't change", id, "discard")
            let buttons = NSStackView(views: [save, discard])
            buttons.spacing = 6
            lines.append(buttons)
        } else {
            if let detail = t["detail"] as? String, !detail.isEmpty {
                lines.append(label(detail, size: 11, color: .secondaryLabelColor, wrap: width - 40))
            }
            if let updates = t["updates"] as? [String], !updates.isEmpty {
                lines.append(label("Also: " + updates.map { "“\($0)”" }.joined(separator: ", "), size: 11, color: .secondaryLabelColor, wrap: width - 40))
            }
            if let review = t["review"] as? [String: Any], let rs = review["status"] as? String {
                let notes = (review["notes"] as? [String]) ?? []
                let mark = rs == "passed" ? "✓ Checked" : rs == "warning" ? "⚠︎ Checked with a note" : "✗ Check failed"
                let text = notes.isEmpty ? mark : "\(mark): \(notes[0])"
                lines.append(label(text, size: 11, color: rs == "passed" ? .systemGreen : rs == "warning" ? .systemOrange : .systemRed,
                                   wrap: width - 40))
            }
            var buttons: [NSView] = []
            // Terminal and browser tasks act at once (typing, opening tabs): nothing to pause or undo.
            let local = t["local"] as? Bool ?? false
            switch local ? "" : state {
            case "queued", "running", "verifying":
                buttons = [button("Pause", id, "pause"), button("Edit", id, "edit"), button("Cancel", id, "cancel")]
            case "asking":
                buttons = [button("Answer", id, "answer"), button("Pause", id, "pause"), button("Edit", id, "edit"), button("Cancel", id, "cancel")]
            case "paused":
                buttons = [button("Resume", id, "resume"), button("Edit", id, "edit"), button("Cancel", id, "cancel")]
            case "done":
                buttons = [button("Undo", id, "undo"), button("Edit", id, "edit")]
            case "failed":
                buttons = [button("Retry", id, "retry"), button("Undo", id, "undo"), button("Edit", id, "edit")]
            case "cancelled", "reverted":
                buttons = [button("Retry", id, "retry"), button("Edit", id, "edit")]
            default:
                break
            }
            if !buttons.isEmpty {
                let row = NSStackView(views: buttons)
                row.spacing = 6
                lines.append(row)
            }
        }
        let stack = NSStackView(views: lines)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        return stack
    }

    private func rebuild() {
        editField = nil
        var rows: [NSView] = []
        let speech = button(speaking ? "🔊 Reading results" : "🔇 Muted", "", "speech")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [label("Glance tasks", size: 14, weight: .bold), label(status, size: 11, color: .secondaryLabelColor),
                                         spacer, speech])
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        header.widthAnchor.constraint(equalToConstant: width - 28).isActive = true
        rows.append(header)
        if tasks.isEmpty {
            rows.append(label("Point at a window or a Figma layer, hold the talk key and speak. Commands run side by side.",
                              size: 12, color: .secondaryLabelColor, wrap: width - 30))
        }
        for t in tasks.prefix(6) {
            let separator = NSBox()
            separator.boxType = .separator
            separator.translatesAutoresizingMaskIntoConstraints = false
            separator.widthAnchor.constraint(equalToConstant: width - 28).isActive = true
            rows.append(separator)
            rows.append(row(t))
        }
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        let content = card(stack, inset: 14)
        stack.widthAnchor.constraint(equalToConstant: width - 28).isActive = true
        panel.contentView = content
        let size = content.fittingSize

        // Grows upwards from just above the mascot.
        let base = anchor?.frame ?? NSRect(x: 200, y: 100, width: 64, height: 64)
        let frame = NSRect(x: base.maxX - width, y: base.maxY + 8, width: width, height: size.height)
        panel.setFrame(clamp(frame, near: NSPoint(x: base.midX, y: base.maxY)), display: true)
        if let field = editField {
            NSApp.activate(ignoringOtherApps: true)     // typing needs Glance in front for a moment
            panel.makeKey()
            panel.makeFirstResponder(field)
        }
    }

    @objc private func tapped(_ sender: NSButton) {
        let info = buttonInfo(sender)
        switch info.value {
        case "edit":
            editing = info.taskId
            rebuild()
        case "save":
            if let field = editField { saveEdit(field) }
        case "discard":
            editing = nil
            rebuild()
        case "answer":
            onShowQuestion?(info.taskId)
        case "speech":
            onToggleSpeech?()
        default:
            onControl?(info.taskId, info.value)
        }
    }

    @objc private func saveEdit(_ sender: NSTextField) {
        guard let id = editing else { return }
        let text = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        if !text.isEmpty { onEdit?(id, text) }
        rebuild()
    }
}

// MARK: - All of it together

/// Turns brain messages into tooltips, toasts, the mascot badge and the task panel.
final class TasksUI: NSObject {
    let tips = QuestionTips()
    private let toast = Toast()
    private let mascot = Mascot()
    private let panel = TaskPanel()
    private var brainUp = false
    private var figmaUp = false
    private var brainTasks: [[String: Any]] = []
    private var localTasks: [[String: Any]] = []
    /// Spoken feedback (the app's `say`), when --say is on.
    var speak: ((String) -> Void)?

    func start(send: @escaping ([String: Any]) -> Void) {
        tips.onAnswer = { taskId, text in send(["type": "answer", "taskId": taskId, "text": text]) }
        panel.onControl = { taskId, action in send(["type": "control", "taskId": taskId, "action": action]) }
        panel.onEdit = { taskId, text in send(["type": "edit", "taskId": taskId, "text": text]) }
        panel.onShowQuestion = { [weak self] taskId in self?.tips.showAgain(taskId) }
        panel.onToggleSpeech = { SpeechSwitch.shared.on.toggle() }
        MascotModel.shared.onClick = { [weak self] in
            guard let self = self else { return }
            self.panel.toggle(above: self.mascot.panel)
        }
        mascot.show()
        refreshStatus()
    }

    func brainConnection(_ up: Bool) {
        brainUp = up
        if !up { figmaUp = false }
        refreshStatus()
    }

    private func refreshStatus() {
        MascotModel.shared.connected = brainUp && figmaUp
        mascot.view.needsDisplay = true
        panel.setStatus(brainUp && figmaUp ? "Figma connected" : "")
    }

    /// Terminal, browser and other window tasks from the app itself.
    func updateLocal(_ tasks: [[String: Any]]) {
        localTasks = tasks
        showTasks()
    }

    func speechChanged(_ on: Bool) {
        panel.speaking = on
    }

    private func showTasks() {
        let all = (localTasks + brainTasks).sorted { ($0["createdAt"] as? Double ?? 0) > ($1["createdAt"] as? Double ?? 0) }
        panel.update(all)
        let active: Set<String> = ["queued", "running", "asking", "paused", "verifying"]
        let running = all.filter { active.contains($0["status"] as? String ?? "") }.count
        if running == 0 && MascotModel.shared.running > 0 { print("\n(all tasks finished)") }
        MascotModel.shared.running = running
        MascotModel.shared.asking = all.contains { ($0["status"] as? String) == "asking" }
        mascot.view.needsDisplay = true
    }

    func handle(_ msg: [String: Any]) {
        switch msg["type"] as? String {
        case "hello", "status":
            figmaUp = msg["figma"] as? Bool ?? false
            refreshStatus()
        case "tasks":
            let tasks = msg["tasks"] as? [[String: Any]] ?? []
            brainTasks = tasks
            showTasks()
            let active: Set<String> = ["queued", "running", "asking", "paused", "verifying"]
            for t in tasks where !active.contains(t["status"] as? String ?? "") {
                if let id = t["id"] as? String { tips.forget(id) }
            }
        case "ask":
            tips.show(msg)
            if let q = msg["question"] as? String { speak?(q) }
        case "askDone":
            if let id = msg["taskId"] as? String { tips.hide(id) }
        case "toast":
            let text = msg["text"] as? String ?? ""
            let anchor = msg["anchor"] as? [String: Any]
            var at: CGPoint?
            if let x = anchor?["x"] as? Double, let y = anchor?["y"] as? Double { at = CGPoint(x: x, y: y) }
            toast.show(text, at: at)
            if (msg["kind"] as? String) != "info" {
                speak?(text.replacingOccurrences(of: "✓ ", with: "").replacingOccurrences(of: "✗ ", with: ""))
            }
        default:
            break
        }
    }
}
