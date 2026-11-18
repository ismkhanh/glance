import AppKit

/// Glance VR for Mac. It streams your Mac's windows to the Glance VR app on Meta Quest, one floating panel per window,
/// and does the clicks, double-clicks, scrolls and drags the headset sends, in the exact window you looked at.
///
///   swift run -c release GlanceVR                       Wi-Fi and USB
///   GLANCE_QUEST_LAN=0 swift run -c release GlanceVR    USB cable only (adb reverse tcp:47811 tcp:47811)
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hub: QuestHub?
    private var gaze: GazeInput?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Glance VR for Mac")
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
            print("• Allow Screen Recording for this terminal app (System Settings > Privacy & Security), then start again.")
        }
        if !AX.isTrusted(prompt: true) {
            print("• Allow Accessibility for this terminal app (System Settings > Privacy & Security), so clicks and scrolls work.")
        }
        guard let port = QuestHub.portFromArguments() else {
            print("--no-quest: nothing to do.")
            NSApp.terminate(nil)
            return
        }
        let hub = QuestHub()
        let gaze = GazeInput()
        hub.onGaze = { [weak gaze] message in gaze?.handle(json: message) }
        hub.onAction = { [weak gaze] message in gaze?.handleAction(json: message) }
        gaze.windowResolver = { [weak hub] id in hub?.windowTarget(for: id) }
        hub.start(port: port)
        self.hub = hub
        self.gaze = gaze
        print("Now open Glance VR on your Quest (same Wi-Fi, or USB cable). Keep this window open. Ctrl+C to stop.")
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
