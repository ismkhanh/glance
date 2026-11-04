import AppKit
import CoreGraphics

/// Figma desktop: instead of guessing which layer is under the pointer, Glance lets Figma tell it.
enum FigmaPointer {
    static func isFigma(_ window: TargetWindow) -> Bool {
        window.bundleID.hasPrefix("com.figma.Desktop")
    }

    /// Cmd+click exactly where the pointer is. Figma selects the deepest layer there and draws its blue outline,
    /// so you see which layer your words go to; the Glance Bridge plugin reports that selection to the brain.
    /// The pointer does not move.
    static func selectUnderPointer() {
        let point = WindowLocator.pointer()
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        usleep(15_000)
        up.post(tap: .cghidEventTap)
    }

    /// The `point` message for the brain (see PROTOCOL.md).
    static func pointMessage(id: String, window: TargetWindow?) -> [String: Any] {
        let at = WindowLocator.pointer()
        var msg: [String: Any] = ["type": "point", "id": id, "at": ["x": Double(at.x), "y": Double(at.y)] as [String: Any]]
        if let w = window {
            let bounds: [String: Any] = ["x": Double(w.bounds.minX), "y": Double(w.bounds.minY),
                                         "w": Double(w.bounds.width), "h": Double(w.bounds.height)]
            msg["window"] = ["id": Int(w.windowID), "app": w.appName, "bundleID": w.bundleID,
                             "title": w.title, "bounds": bounds] as [String: Any]
        }
        return msg
    }
}
