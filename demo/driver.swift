// Demo driver: plays a scene in the real Glance app, as a person would.
// Moves the pointer, holds Left Option while a Kokoro clip is "spoken" into Glance (GLANCE_DEMO_VOICE), clicks.
// Every step is logged with wall-clock time, so the editor can lay the same clip under the screen recording.
//
//   swiftc -O demo/driver.swift -o demo/.bin/driver
//   GLANCE_DEMO_VOICE=demo/.voice demo/.bin/driver demo/scenes/figma.json demo/takes/figma.events.json
//
// Scene: [{"do": "activate", "app": "com.figma.Desktop"}, {"do": "move", "to": [x, y], "ms": 700},
//         {"do": "say", "clip": "demo/audio/c01.wav"}, {"do": "click", "at": [x, y]}, {"do": "wait", "ms": 2000},
//         {"do": "mark", "name": "scene 2"}]   (points are screen points, top-left origin)
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let scene = try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[1]))) as? [[String: Any]] else {
    print("usage: driver <scene.json> <events-out.json>")
    exit(2)
}
guard let voiceDir = ProcessInfo.processInfo.environment["GLANCE_DEMO_VOICE"] else {
    print("Set GLANCE_DEMO_VOICE to the same folder Glance was started with.")
    exit(2)
}
if !AXIsProcessTrusted() { print("warning: this terminal has no Accessibility access, so pointer and key events will be ignored.") }

var events: [[String: Any]] = []
func log(_ kind: String, _ extra: [String: Any] = [:]) {
    var e = extra
    e["kind"] = kind
    e["t"] = Date().timeIntervalSince1970
    events.append(e)
    print(String(format: "%.2f", e["t"] as! Double), kind, extra)
}

func pointer() -> CGPoint {
    CGEvent(source: nil)?.location ?? .zero
}

func moveTo(_ target: CGPoint, ms: Double) {
    let start = pointer()
    let steps = max(1, Int(ms / 1000 * 60))
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        let e = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2      // ease in-out
        let p = CGPoint(x: start.x + (target.x - start.x) * e, y: start.y + (target.y - start.y) * e)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(useconds_t(ms * 1000 / Double(steps)))
    }
}

func option(_ down: Bool) {
    guard let e = CGEvent(keyboardEventSource: nil, virtualKey: 58, keyDown: down) else { return }
    e.type = .flagsChanged
    e.flags = down ? .maskAlternate : []
    e.post(tap: .cghidEventTap)
}

func click(_ at: CGPoint) {
    moveTo(at, ms: 350)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
        e?.setIntegerValueField(.mouseEventClickState, value: 1)
        e?.post(tap: .cghidEventTap)
        usleep(40_000)
    }
}

/// Seconds of audio in one of our 24 kHz mono 16-bit WAVs.
func duration(_ path: String) -> Double {
    guard let wav = FileManager.default.contents(atPath: path), let marker = wav.range(of: Data("data".utf8)) else { return 0 }
    return Double(wav.count - marker.upperBound - 4) / 48000
}

func point(_ value: Any?) -> CGPoint? {
    guard let xy = value as? [Double], xy.count == 2 else { return nil }
    return CGPoint(x: xy[0], y: xy[1])
}

/// Where Glance said it put something: the numbers after "card at" on the last log line containing `text`.
func loggedPoint(_ text: String?, file: String = "demo/logs/glance.log") -> CGPoint? {
    guard let text = text, let log = try? String(contentsOfFile: file, encoding: .utf8),
          let line = log.components(separatedBy: "\n").last(where: { $0.contains(text) && $0.contains("card at") }),
          let at = line.range(of: "card at ") else { return nil }
    let numbers = line[at.upperBound...].split(whereSeparator: { !"0123456789.-".contains($0) }).compactMap { Double($0) }
    return numbers.count >= 2 ? CGPoint(x: numbers[0], y: numbers[1]) : nil
}

log("start", ["scene": args[1]])
for step in scene {
    switch step["do"] as? String ?? "" {
    case "activate":
        let id = step["app"] as? String ?? ""
        // `open` brings the app forward; activate() from a background process is refused on recent macOS.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-b", id]
        try? open.run()
        open.waitUntilExit()
        usleep(800_000)
        log("activate", ["app": id])
    case "move":
        // "to": [x, y], or "fromLog": text — the last "<text> … (card at x, y)" line Glance printed.
        guard let to = point(step["to"]) ?? loggedPoint(step["fromLog"] as? String) else { continue }
        moveTo(to, ms: step["ms"] as? Double ?? 700)
        log("move", ["to": [to.x, to.y]])
    case "say":
        let clip = (step["clip"] as? String ?? "")
        let path = clip.hasPrefix("/") ? clip : FileManager.default.currentDirectoryPath + "/" + clip
        try? path.write(toFile: voiceDir + "/next", atomically: true, encoding: .utf8)
        let length = duration(path)
        option(true)
        log("say", ["clip": clip, "seconds": length])
        // Glance starts the clip as soon as it sees the key; hold a little past its end, like a person would.
        usleep(useconds_t((length + (step["pad"] as? Double ?? 0.35)) * 1_000_000))
        option(false)
        log("release", ["clip": clip])
    case "click":
        guard let at = point(step["at"]) else { continue }
        click(at)
        log("click", ["at": [at.x, at.y]])
    case "wait":
        usleep(useconds_t((step["ms"] as? Double ?? 1000) * 1000))
    case "until":
        // Wait for Glance to print something new (a question, an answer), then `ms` more, like a person reading it.
        let file = step["log"] as? String ?? "demo/logs/glance.log"
        let text = step["text"] as? String ?? ""
        func seen() -> Int { ((try? String(contentsOfFile: file, encoding: .utf8)) ?? "").components(separatedBy: text).count - 1 }
        let before = seen()
        let deadline = Date().addingTimeInterval((step["timeout"] as? Double ?? 30000) / 1000)
        while seen() <= before && Date() < deadline { usleep(100_000) }
        log("until", ["text": text, "found": seen() > before])
        usleep(useconds_t((step["ms"] as? Double ?? 0) * 1000))
    case "shot":
        // A screenshot for planning the next scene (demo/logs/<name>.png, full Retina size).
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "demo/logs/\(step["name"] as? String ?? "shot").png"]
        try? shot.run()
        shot.waitUntilExit()
        log("shot", ["name": step["name"] as? String ?? "shot"])
    case "mark":
        log("mark", ["name": step["name"] as? String ?? ""])
    default:
        print("unknown step: \(step)")
    }
}
log("end")
let out = try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted])
try out.write(to: URL(fileURLWithPath: args[2]))
