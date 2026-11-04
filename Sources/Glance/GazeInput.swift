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

    static func portFromArguments() -> UInt16? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--gaze") else { return nil }
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
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let x = json["x"] as? Double, let y = json["y"] as? Double,
              (-0.05...1.05).contains(x), (-0.05...1.05).contains(y) else { return }
        lastPacketAt = Date()
        let frame = CGDisplayBounds(CGMainDisplayID())
        let target = CGPoint(x: frame.minX + min(max(x, 0), 1) * frame.width, y: frame.minY + min(max(y, 0), 1) * frame.height)
        // Exponential smoothing: about 150 ms to follow a jump at 60 packets a second.
        let s = smooth.map { CGPoint(x: $0.x + (target.x - $0.x) * 0.25, y: $0.y + (target.y - $0.y) * 0.25) } ?? target
        smooth = s
        // Move only when the gaze has settled 24 pt or more away from where the pointer was put last.
        guard hypot(s.x - lastMoved.x, s.y - lastMoved.y) >= 24 else { return }
        lastMoved = s
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: s, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
