import CoreGraphics
import Foundation
import Network

/// Eye gaze from a headset (Quest Pro running the Glance Gaze app) moves the pointer, so everything that follows the
/// pointer (glow, "this", the talk key) follows your eyes instead.
///
/// The headset sends small UDP packets to this Mac: `{"x": 0.42, "y": 0.18}`, the point you look at on the screen,
/// 0…1 from the top-left corner (`"c": true` while it is calibrating, which only shows the point). Points are smoothed,
/// and the pointer only moves when the gaze settles somewhere new, so the normal tremble of the eyes does not shake it.
///   swift run -c release Glance --gaze 47810
final class GazeInput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "glance.gaze")
    private var listener: NWListener?
    private var smooth: CGPoint?
    private var lastMoved = CGPoint(x: -1, y: -1)
    private(set) var lastPacketAt = Date.distantPast
    /// When a headset last pointed somewhere (any GazeInput). While it does, Glance shows the glow on the window you
    /// look at even before you talk, so you can see in the headset which window a pinch will talk to.
    static var lastPointedAt = Date.distantPast
    /// Glance VR: the headset's left-hand pinch is a talk key. Called with true when the pinch starts and false when it
    /// ends, only on a change (the same state comes in every gaze packet, and twice when it is also broadcast).
    var onTalk: ((Bool) -> Void)?
    private var talkDown = false
    /// Floating windows: resolves a panel's window id to the Mac window it stands for. Set by the app when
    /// Quest Desk runs; nil in plain gaze mode, where points map onto the whole display as before.
    var windowResolver: ((UInt32) -> TargetWindow?)?
    private var watchdogGeneration = 0
    private var draggingWindow = false
    private var scrollWindow: UInt32?      // the window a left-hand scroll last raised (raise once, not per tick)
    private var dragPending = false        // mouse-down scheduled (raise delay) but not yet posted
    private var lastDragPoint = CGPoint.zero
    private var dragWatchdogGeneration = 0

    static func portFromArguments() -> UInt16? {
        let args = CommandLine.arguments
        if args.contains("--no-gaze") { return nil }
        guard let i = args.firstIndex(of: "--gaze") else { return 47810 }
        return i + 1 < args.count ? UInt16(args[i + 1]) ?? 47810 : 47810
    }

    func start(port: UInt16) {
        do {
            let l = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] connection in
                connection.start(queue: self?.queue ?? .main)
                self?.receive(on: connection)
            }
            l.stateUpdateHandler = { state in
                if case .ready = state { print("Eye gaze: listening on UDP port \(port) (start Glance Gaze on the headset).") }
                if case .failed(let error) = state { print("Eye gaze: could not listen on port \(port): \(error)") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            print("Eye gaze: could not listen on port \(port): \(error)")
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data = data { self?.handle(data) }
            if error == nil { self?.receive(on: connection) }
        }
    }

    private func handle(_ data: Data) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        apply(json)
    }

    /// The same gaze/talk message when it comes over the Quest Desk WebSocket instead of UDP
    /// (Glance VR over a USB cable: `adb reverse tcp:47811 tcp:47811`).
    func handle(json: [String: Any]) {
        queue.async { [weak self] in self?.apply(json) }
    }

    private func apply(_ json: [String: Any]) {
        // Floating windows: a panel point is inside one window, not the whole display. Resolve it first so the
        // talk key and the pointer both land on that window, even if it is behind another on the Mac.
        var panelWindow: TargetWindow?
        if let raw = json["window"] as? Int, let windowID = UInt32(exactly: raw), let resolver = windowResolver {
            panelWindow = resolver(windowID)
        }
        if let talk = json["talk"] as? Bool {
            lastPacketAt = Date()
            if talk != talkDown {
                talkDown = talk
                if talk, let target = panelWindow {
                    AX.raise(target, window: AX.window(for: target))
                }
                onTalk?(talk)
            }
            if talk { armWatchdog() }
        }
        guard let x = json["x"] as? Double, let y = json["y"] as? Double,
              (-0.05...1.05).contains(x), (-0.05...1.05).contains(y) else { return }
        lastPacketAt = Date()
        GazeInput.lastPointedAt = lastPacketAt
        let frame = panelWindow?.bounds ?? CGDisplayBounds(CGMainDisplayID())
        let target = CGPoint(x: frame.minX + min(max(x, 0), 1) * frame.width, y: frame.minY + min(max(y, 0), 1) * frame.height)
        // Exponential smoothing: about 150 ms to follow a jump at 60 packets a second.
        let s = smooth.map { CGPoint(x: $0.x + (target.x - $0.x) * 0.25, y: $0.y + (target.y - $0.y) * 0.25) } ?? target
        smooth = s
        // Move only when the gaze has settled 24 pt or more away from where the pointer was put last.
        guard hypot(s.x - lastMoved.x, s.y - lastMoved.y) >= 24 else { return }
        lastMoved = s
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: s, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    /// Floating-window actions from the headset: a short right pinch is a click in that window; a pinch held
    /// while looking across it is a drag. Points are 0…1 inside the named window.
    func handleAction(json: [String: Any]) {
        queue.async { [weak self] in self?.applyAction(json) }
    }

    private func applyAction(_ json: [String: Any]) {
        guard let type = json["type"] as? String else { return }
        // A cancel needs no window or point: it just lets go of the mouse, wherever a drag left it.
        if type == "drag_cancel" || type == "drag_end" {
            let wasActive = draggingWindow || dragPending
            draggingWindow = false
            dragPending = false
            dragWatchdogGeneration += 1
            if wasActive { postMouse(.leftMouseUp, at: lastDragPoint) }
            if type == "drag_cancel" { return }
        }
        guard let raw = json["window"] as? Int, let windowID = UInt32(exactly: raw),
              let resolver = windowResolver, let target = resolver(windowID),
              let x = json["x"] as? Double, let y = json["y"] as? Double,
              (-0.05...1.05).contains(x), (-0.05...1.05).contains(y) else { return }
        let bounds = target.bounds
        let point = CGPoint(x: bounds.minX + min(max(x, 0), 1) * bounds.width,
                            y: bounds.minY + min(max(y, 0), 1) * bounds.height)
        switch type {
        case "click":
            AX.raise(target, window: AX.window(for: target))
            // Give the window a beat to come forward before the click lands.
            queue.asyncAfter(deadline: .now() + 0.12) {
                postMouse(.leftMouseDown, at: point)
                postMouse(.leftMouseUp, at: point)
            }
        case "scroll":
            // Glance VR: long left pinch moved up/down. Hand up = content up (like dragging a page), so wheel < 0.
            guard let dy = (json["dy"] as? NSNumber)?.intValue, dy != 0 else { return }
            if scrollWindow != windowID {
                print("Glance VR: scrolling window \(windowID) (\(target.appName))")
                scrollWindow = windowID
                AX.raise(target, window: AX.window(for: target))
            }
            postMouse(.mouseMoved, at: point)
            if let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: Int32(clamping: -dy), wheel2: 0, wheel3: 0) {
                event.location = point
                event.post(tap: .cghidEventTap)
            }
        case "double_click":
            // Glance VR: a double pinch of the left thumb and index finger opens what you look at (a file in Finder).
            AX.raise(target, window: AX.window(for: target))
            queue.asyncAfter(deadline: .now() + 0.12) {
                postMouse(.leftMouseDown, at: point, clicks: 1)
                postMouse(.leftMouseUp, at: point, clicks: 1)
                postMouse(.leftMouseDown, at: point, clicks: 2)
                postMouse(.leftMouseUp, at: point, clicks: 2)
            }
        case "drag_start":
            AX.raise(target, window: AX.window(for: target))
            dragPending = true
            lastDragPoint = point
            armDragWatchdog()
            queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                // An end/cancel inside the raise delay clears dragPending, so no orphan mouse-down is posted.
                guard let self, self.dragPending, !self.draggingWindow else { return }
                self.dragPending = false
                self.draggingWindow = true
                postMouse(.leftMouseDown, at: point)
            }
        case "drag_move":
            lastDragPoint = point
            if draggingWindow { postMouse(.leftMouseDragged, at: point) }
            if draggingWindow || dragPending { armDragWatchdog() }
        case "drag_end":
            break   // already let go above; a duplicate end is harmless
        default:
            break
        }
    }

    /// A drag whose packets stop (headset died, cable pulled) must not hold the Mac's mouse down.
    private func armDragWatchdog() {
        dragWatchdogGeneration += 1
        let generation = dragWatchdogGeneration
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.dragWatchdogGeneration == generation,
                  self.draggingWindow || self.dragPending else { return }
            self.draggingWindow = false
            self.dragPending = false
            print("Glance VR: drag packets stopped, letting go of the mouse.")
            postMouse(.leftMouseUp, at: self.lastDragPoint)
        }
    }

    /// A headset that dies mid-pinch (sleep, cable, crash) must not leave Glance listening: if no packet arrives
    /// for 1.5 s while the talk key is down, let go on its behalf. Every fresh talk packet re-arms this.
    private func armWatchdog() {
        watchdogGeneration += 1
        let generation = watchdogGeneration
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.watchdogGeneration == generation, self.talkDown,
                  Date().timeIntervalSince(self.lastPacketAt) >= 1.5 else { return }
            self.talkDown = false
            print("Glance VR: no headset packets for 1.5 s, letting go of the talk key.")
            self.onTalk?(false)
        }
    }
}

/// The same event as part of a multi-click (clicks: 2 is the second click of a double-click).
private func postMouse(_ type: CGEventType, at point: CGPoint, clicks: Int64) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else { return }
    event.setIntegerValueField(.mouseEventClickState, value: clicks)
    event.post(tap: .cghidEventTap)
}

/// Posts one real mouse event at a global point, as if from the user's mouse.
private func postMouse(_ type: CGEventType, at point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
}
