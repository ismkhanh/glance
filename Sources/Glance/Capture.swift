import AppKit
import ApplicationServices
import ScreenCaptureKit

/// A picture of one window, for apps that do not share their text (Ghostty, iTerm2, canvas apps).
@available(macOS 14.0, *)
enum WindowCapture {
    static func jpeg(windowID: CGWindowID, maxWidth: Int = 1600) async throws -> Data {
        let image = try await self.image(windowID: windowID, maxWidth: maxWidth)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
            throw ScriptError(message: "Could not encode the window picture.")
        }
        return data
    }

    static func image(windowID: CGWindowID, maxWidth: Int = 1600) async throws -> CGImage {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            throw ScriptError(message: "Screen Recording is off for your terminal app. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording, then restart the terminal app.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScriptError(message: "That window is not on screen.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let pixelWidth = Int(window.frame.width * 2)            // Retina: 2 pixels per point
        let width = min(maxWidth, max(200, pixelWidth))
        let height = Int(Double(width) * Double(window.frame.height / max(window.frame.width, 1)))
        config.width = width
        config.height = max(100, height)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// Remembers which app and window had keyboard focus, so Glance can put focus back after it types somewhere else.
struct FocusSnapshot {
    let app: NSRunningApplication?
    let window: AXUIElement?

    static func take() -> FocusSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        var window: AXUIElement?
        if let pid = app?.processIdentifier,
           let w = AX.attr(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute) {
            window = (w as! AXUIElement)
        }
        return FocusSnapshot(app: app, window: window)
    }

    func restore() {
        if let w = window { _ = AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
        app?.activate(options: [])
    }
}

enum Typing {
    /// Types text as if from the keyboard into whatever has focus.
    static func type(_ text: String) -> Bool {
        for ch in text {
            let units = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { return false }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(4_000)
        }
        return true
    }
}

private let keyboardLock = NSLock()

/// Brings the target window forward, runs `send` (key presses or typing), then gives focus back.
func sendToWindow(_ target: TargetWindow, _ send: () -> Bool) -> Bool {
    // Tasks run side by side: one at a time takes the keyboard, so their keys never mix.
    keyboardLock.lock()
    defer { keyboardLock.unlock() }
    let before = FocusSnapshot.take()
    AX.raise(target, window: AX.window(for: target))
    usleep(200_000)                 // let the window come forward
    let ok = send()
    usleep(250_000)                 // let the target take the keys before focus moves back
    before.restore()
    return ok
}
