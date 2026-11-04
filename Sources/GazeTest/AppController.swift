import AppKit

/// A borderless window that can still take keyboard input.
final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AppController: NSObject, NSApplicationDelegate {
    private let engine = GazeEngine()
    private var window: NSWindow?
    private var gazeView: GazeView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        // Ask for the camera first, before the full-screen window,
        // so the system permission prompt is never hidden behind it.
        engine.start { [weak self] error in
            self?.showWindow(cameraError: error)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func showWindow(cameraError: String?) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = .statusBar          // above the menu bar and the Dock
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black

        let view = GazeView(frame: NSRect(origin: .zero, size: screen.frame.size), engine: engine)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        view.attach(cameraError: cameraError)

        self.window = window
        self.gazeView = view
    }

    private func buildMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Glance Gaze Test", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }
}
