import AppKit

// Glance gaze test: can the built-in webcam tell which part of the screen you look at?
// Run from Terminal, in the Glance folder:  swift run -c release GazeTest

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.regular)
app.run()
