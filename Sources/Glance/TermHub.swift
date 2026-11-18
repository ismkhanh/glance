import Darwin
import Foundation

/// Terminal text for the headset: escape sequences removed, carriage returns and backspaces applied,
/// only the last lines kept. Pure text work, so the tests can drive it without a shell.
struct TerminalText {
    static let maxLines = 600
    private(set) var lines: [String] = []
    private var current = ""

    mutating func append(_ raw: String) {
        for ch in TerminalText.stripANSI(raw) {
            switch ch {
            case "\n":
                lines.append(current)
                current = ""
                if lines.count > TerminalText.maxLines { lines.removeFirst(lines.count - TerminalText.maxLines) }
            case "\r":
                current = "" // rewritten line: shells redraw prompts and progress bars this way
            case "\u{08}", "\u{7f}":
                if !current.isEmpty { current.removeLast() }
            case "\t":
                current += "    "
            default:
                if ch.unicodeScalars.count == 1, let s = ch.unicodeScalars.first, s.value < 0x20 { continue }
                current.append(ch)
            }
        }
    }

    /// The last screenful, as the headset panel shows it.
    func snapshot(rows: Int = 34, cols: Int = 110) -> String {
        var tail = lines.suffix(rows - 1).map { String($0.prefix(cols)) }
        tail.append(String(current.prefix(cols)))
        while tail.count > 1, tail.last == "" { tail.removeLast() }
        return tail.joined(separator: "\n")
    }

    /// Removes ANSI escape sequences: CSI (`ESC [ … final`), OSC (`ESC ] … BEL` or `ESC \` ), and short escapes.
    static func stripANSI(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            guard ch == "\u{1b}" else { out.append(ch); i = text.index(after: i); continue }
            let next = text.index(after: i)
            guard next < text.endIndex else { break }
            let kind = text[next]
            if kind == "[" {
                var j = text.index(after: next)
                while j < text.endIndex {
                    let c = text[j]
                    j = text.index(after: j)
                    if ("@"..."~").contains(c) { break }
                }
                i = j
            } else if kind == "]" {
                var j = text.index(after: next)
                while j < text.endIndex {
                    let c = text[j]
                    if c == "\u{07}" { j = text.index(after: j); break }
                    if c == "\u{1b}" {
                        let k = text.index(after: j)
                        if k < text.endIndex, text[k] == "\\" { j = text.index(after: k); break }
                    }
                    j = text.index(after: j)
                }
                i = j
            } else if kind == "(" || kind == ")" || kind == "#" {
                var j = text.index(after: next)
                if j < text.endIndex { j = text.index(after: j) }
                i = j
            } else {
                i = text.index(after: next)
            }
        }
        return out
    }
}

/// What spoken words become as terminal input. A lone control phrase sends that key; words starting
/// with "type" are typed with no Return; anything else is a command and runs (Return is sent).
enum QuestSpeech {
    static func injection(for transcript: String) -> String? {
        let said = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty else { return nil }
        let plain = said.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!,"))
        switch plain {
        case "control c", "ctrl c", "control see": return "\u{03}"
        case "control d", "ctrl d": return "\u{04}"
        case "control z", "ctrl z": return "\u{1a}"
        case "control l", "ctrl l", "clear": return "\u{0c}"
        case "enter", "return", "run it", "go": return "\r"
        case "tab": return "\t"
        case "escape", "esc", "cancel": return "\u{1b}"
        case "backspace", "delete that": return "\u{7f}"
        case "up", "up arrow": return "\u{1b}[A"
        case "down", "down arrow": return "\u{1b}[B"
        default: break
        }
        if plain.hasPrefix("type ") {
            return String(said.dropFirst("type ".count))
        }
        return said + "\r"
    }
}

/// Real shells on this Mac, one per headset terminal panel. Each is `/bin/zsh` on a pseudo terminal:
/// the processes, files and network are the Mac's; the headset is only a view and a keyboard.
final class TermHub: @unchecked Sendable {
    struct Info { let id: String; let title: String }

    var onOutput: ((String, String, String) -> Void)? // id, title, snapshot text
    var onClosed: ((String) -> Void)?

    private final class Session: @unchecked Sendable {
        let id: String
        let title: String
        let master: Int32
        let process: Process
        var text = TerminalText()
        var lastSent = ""
        var reader: DispatchSourceRead?

        init(id: String, title: String, master: Int32, process: Process) {
            self.id = id; self.title = title; self.master = master; self.process = process
        }
    }

    private let lock = NSLock()
    private var sessions: [String: Session] = [:]
    private var order: [String] = []
    private let queue = DispatchQueue(label: "glance.termhub")

    var list: [Info] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { sessions[$0].map { Info(id: $0.id, title: $0.title) } }
    }

    @discardableResult
    func create(title: String? = nil) -> Info? {
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 34, ws_col: 110, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { return nil }

        let id = "t" + UUID().uuidString.prefix(6).lowercased()
        lock.lock()
        let name = title?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "Terminal \(order.count + 1)"
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-i"]
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory())
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["SHELL"] = "/bin/zsh"
        process.environment = env
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        let session = Session(id: id, title: name, master: master, process: process)
        lock.lock()
        sessions[id] = session
        order.append(id)
        lock.unlock()

        process.terminationHandler = { [weak self, weak session] _ in
            guard let self = self, let session = session else { return }
            session.reader?.cancel()
            Darwin.close(session.master)
            self.lock.lock()
            self.sessions[session.id] = nil
            self.order.removeAll { $0 == session.id }
            self.lock.unlock()
            self.onClosed?(session.id)
        }
        do {
            try process.run()
        } catch {
            lock.lock(); sessions[id] = nil; order.removeAll { $0 == id }; lock.unlock()
            Darwin.close(master); Darwin.close(slave)
            return nil
        }
        Darwin.close(slave)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        session.reader = source
        source.setEventHandler { [weak self, weak session] in
            guard let session = session else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(session.master, &buffer, buffer.count)
            guard count > 0 else { return }
            let chunk = String(decoding: buffer.prefix(count), as: UTF8.self)
            self?.queue.async { self?.absorb(session, chunk) }
        }
        source.setCancelHandler { }
        source.resume()
        return Info(id: id, title: name)
    }

    private func absorb(_ session: Session, _ chunk: String) {
        lock.lock()
        session.text.append(chunk)
        let snap = session.text.snapshot()
        let changed = snap != session.lastSent
        if changed { session.lastSent = snap }
        lock.unlock()
        if changed { onOutput?(session.id, session.title, snap) }
    }

    /// Snapshot for a (re)connecting headset.
    func snapshot(id: String) -> (title: String, text: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let s = sessions[id] else { return nil }
        return (s.title, s.text.snapshot())
    }

    /// Writes text (or key bytes) into the shell, exactly as if typed on the Mac.
    @discardableResult
    func input(id: String, _ text: String) -> Bool {
        lock.lock()
        let master = sessions[id]?.master
        lock.unlock()
        guard let master = master else { return false }
        let data = Data(text.utf8)
        return data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return write(master, base, raw.count) >= 0
        }
    }

    func close(id: String) {
        lock.lock()
        let session = sessions[id]
        lock.unlock()
        guard let session = session else { return }
        if session.process.isRunning { session.process.terminate() }
    }

    func closeAll() {
        for info in list { close(id: info.id) }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
