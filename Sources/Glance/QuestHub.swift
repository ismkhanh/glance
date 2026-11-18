import Foundation
import Network

/// Speech for the headset, supplied by Glance (its existing Muse voice path). Nil means voice is off.
protocol QuestTranscribing: AnyObject, Sendable {
    func questTranscribe(_ feed: AudioFeed, onPartial: @escaping (String) -> Void) -> Transcription?
}

extension Glance: QuestTranscribing {
    func questTranscribe(_ feed: AudioFeed, onPartial: @escaping (String) -> Void) -> Transcription? {
        transcribe(feed, onPartial: onPartial)
    }
}

/// The Quest Desk server: one WebSocket the headset connects to on the local network.
/// Text packets are JSON (see docs/specs/0001-quest-desk.md); binary packets starting with "A" are
/// 24 kHz voice audio, and binary packets starting with "S" are screen JPEG frames going back.
/// On by default on port 47811, so a reviewer launches the app and opens the Quest app; nothing
/// to configure. `--quest <port>` picks another port, `--no-quest` turns it off. The headset
/// finds this Mac by UDP broadcast (port 47812), never by a typed address.
///   swift run -c release Glance
final class QuestHub: @unchecked Sendable {
    static let defaultPort: UInt16 = 47811
    static let discoveryPort: UInt16 = 47812

    static func portFromArguments() -> UInt16? {
        let args = CommandLine.arguments
        if args.contains("--no-quest") { return nil }
        guard let i = args.firstIndex(of: "--quest") else { return defaultPort }
        return i + 1 < args.count ? UInt16(args[i + 1]) ?? defaultPort : defaultPort
    }

    weak var transcriber: QuestTranscribing?

    let terms = TermHub()
    private let screen = ScreenStream()
    /// Floating windows (protocol 2): one panel per Mac window. Roster + per-window frames.
    let windowRegistry = WindowRegistry()
    private let windowPool = WindowStreamPool()
    private var windowsClients: Set<UUID> = []
    private var restrictedClients: Set<UUID> = []   // mirror-only over USB when the app has no token but the Mac does
    private var rosterTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var greeted: Set<UUID> = []
    private var voices: [UUID: (id: String, feed: AudioFeed, take: Transcription)] = [:]
    private var screenWanted = false
    /// Glance VR sends `{"type": "gaze", "x", "y", "talk"}` here when it runs over the USB cable.
    var onGaze: (([String: Any]) -> Void)?
    /// Floating-window actions: `click` / `drag_start` / `drag_move` / `drag_end` with a window id and point.
    var onAction: (([String: Any]) -> Void)?
    private let token: String?

    init(token: String? = ProcessInfo.processInfo.environment["GLANCE_QUEST_TOKEN"]) {
        self.token = token?.trimmingCharacters(in: .whitespaces).isEmpty == false ? token : nil
        terms.onOutput = { [weak self] id, title, text in
            self?.broadcast(["type": "term_output", "id": id, "title": title, "text": text])
        }
        terms.onClosed = { [weak self] id in
            self?.broadcast(["type": "term_closed", "id": id])
        }
        screen.onFrame = { [weak self] jpeg in
            guard let self = self else { return }
            var packet = Data([0x53]) // "S"
            packet.append(jpeg)
            self.broadcastBinary(packet)
        }
        screen.onError = { [weak self] message in
            print("Quest screen: \(message)")
            self?.broadcast(["type": "error", "text": message])
        }
        windowPool.onFrame = { [weak self] windowID, jpeg in
            guard let self else { return }
            var packet = Data([0x57]) // "W": one floating-window panel frame
            var bigEndian = windowID.bigEndian
            withUnsafeBytes(of: &bigEndian) { packet.append(contentsOf: $0) }
            packet.append(jpeg)
            self.broadcastBinaryToWindows(packet)
        }
        windowPool.onError = { [weak self] message in
            print("Quest windows: \(message)")
            self?.broadcastToWindows(["type": "error", "text": message])
        }
    }

    /// The Mac window a floating panel stands for, for gaze/talk targeting.
    func windowTarget(for id: UInt32) -> TargetWindow? {
        windowRegistry.target(for: id)
    }

    func start(port: UInt16) {
        do {
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            let params = NWParameters(tls: nil)
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            // Wi-Fi by default, so the headset finds and connects to this Mac with no setup.
            // A connection can open real shells: on shared Wi-Fi set GLANCE_QUEST_TOKEN (the Quest
            // app then needs the same word), or GLANCE_QUEST_LAN=0 to accept USB (`adb reverse`) only.
            let lan = ProcessInfo.processInfo.environment["GLANCE_QUEST_LAN"] != "0"
            let listener: NWListener
            if lan {
                listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            } else {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
                listener = try NWListener(using: params)
            }
            listener.newConnectionHandler = { [weak self] connection in
                let id = UUID()
                self?.lock.lock()
                self?.clients[id] = connection
                self?.lock.unlock()
                connection.stateUpdateHandler = { [weak self] state in
                    if case .cancelled = state { self?.drop(id) }
                    if case .failed = state { self?.drop(id) }
                }
                connection.start(queue: DispatchQueue(label: "glance.quest.client"))
                self?.receive(id, connection)
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state {
                    print("Quest Desk: listening on ws port \(port), \(lan ? "Wi-Fi and USB" : "USB only (adb reverse)"), token \(self.token == nil ? "off" : "on").")
                }
                if case .failed(let error) = state { print("Quest Desk: could not listen on port \(port): \(error)") }
            }
            listener.start(queue: DispatchQueue(label: "glance.quest"))
            self.listener = listener
            startDiscovery(wsPort: port)
        } catch {
            print("Quest Desk: could not listen on port \(port): \(error)")
        }
    }

    /// Answers "GLANCE_DISCOVER" UDP broadcasts with this Mac's WebSocket port, so the Quest app
    /// needs no typed address: it broadcasts, this replies, it connects to the reply's sender.
    private var discoveryListener: NWListener?

    private func startDiscovery(wsPort: UInt16) {
        guard discoveryListener == nil else { return }
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true // another Glance on this Mac may already answer
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.discoveryPort)!)
            listener.newConnectionHandler = { connection in
                connection.start(queue: DispatchQueue(label: "glance.quest.discovery"))
                Self.answerDiscovery(on: connection, wsPort: wsPort)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state { print("Quest discovery: \(error)") }
            }
            listener.start(queue: DispatchQueue(label: "glance.quest.discovery"))
            discoveryListener = listener
        } catch {
            print("Quest discovery: could not listen on UDP \(Self.discoveryPort): \(error)")
        }
    }

    private static func answerDiscovery(on connection: NWConnection, wsPort: UInt16) {
        connection.receiveMessage { data, _, _, error in
            if let data, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "GLANCE_DISCOVER" {
                let reply = "{\"type\":\"glance_mac\",\"port\":\(wsPort)}"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
            }
            if error == nil { answerDiscovery(on: connection, wsPort: wsPort) }
        }
    }

    func stop() {
        listener?.cancel()
        discoveryListener?.cancel()
        discoveryListener = nil
        lock.lock()
        let all = Array(clients.values)
        clients.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
        screen.stop()
        windowPool.stop()
        rosterTimer?.cancel()
        rosterTimer = nil
        terms.closeAll()
    }

    // MARK: - Clients

    private func drop(_ id: UUID) {
        lock.lock()
        clients[id] = nil
        greeted.remove(id)
        restrictedClients.remove(id)
        let wasWindows = windowsClients.remove(id) != nil
        let noWindowsLeft = windowsClients.isEmpty
        let take = voices[id]?.take
        voices[id] = nil
        let anyLeft = !clients.isEmpty
        lock.unlock()
        take?.cancel()
        // Glance VR: a headset that drops mid-pinch (cable pulled, app closed) must not leave Glance listening,
        // or its mouse button held down from a drag that will never end.
        onGaze?(["type": "gaze", "talk": false])
        onAction?(["type": "drag_cancel"])
        if !anyLeft { screen.stop(); lock.lock(); screenWanted = false; lock.unlock() }
        if wasWindows && noWindowsLeft { stopRoster() }
    }

    // MARK: - Floating windows

    private func startRoster() {
        lock.lock()
        let already = rosterTimer != nil
        lock.unlock()
        guard !already else { return }
        windowRegistry.refresh()
        broadcastToWindows(windowRegistry.rosterJSON)
        windowPool.setWindows(windowRegistry.snapshot().map(\.id))
        windowPool.start()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "glance.quest.roster"))
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.windowRegistry.refresh() {
                self.broadcastToWindows(self.windowRegistry.rosterJSON)
                self.windowPool.setWindows(self.windowRegistry.snapshot().map(\.id))
            }
        }
        lock.lock(); rosterTimer = timer; lock.unlock()   // record before resuming, so no second timer slips in
        timer.resume()
    }

    private func stopRoster() {
        lock.lock()
        let timer = rosterTimer
        rosterTimer = nil
        lock.unlock()
        timer?.cancel()
        windowPool.stop()
    }

    private func broadcastToWindows(_ object: [String: Any]) {
        lock.lock()
        let targets = windowsClients.compactMap { clients[$0] }
        lock.unlock()
        targets.forEach { send($0, object) }
    }

    private func broadcastBinaryToWindows(_ data: Data) {
        lock.lock()
        let targets = windowsClients.compactMap { clients[$0] }
        let wanted = !windowsClients.isEmpty
        lock.unlock()
        guard wanted else { return }
        targets.forEach { sendBinary($0, data) }
    }

    private func receive(_ id: UUID, _ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata)?.opcode
                if opcode == .binary {
                    self.handleBinary(id, data)
                } else {
                    self.handleText(id, connection, data)
                }
            }
            if error == nil { self.receive(id, connection) } else { self.drop(id) }
        }
    }

    private func send(_ connection: NWConnection, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func sendBinary(_ connection: NWConnection, _ data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [meta])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func broadcast(_ object: [String: Any]) {
        lock.lock()
        let targets = greeted.compactMap { clients[$0] }
        lock.unlock()
        targets.forEach { send($0, object) }
    }

    private func broadcastBinary(_ data: Data) {
        lock.lock()
        let targets = greeted.compactMap { clients[$0] }
        let wanted = screenWanted
        lock.unlock()
        guard wanted else { return }
        targets.forEach { sendBinary($0, data) }
    }

    // MARK: - Messages

    private func handleText(_ id: UUID, _ connection: NWConnection, _ data: Data) {
        guard let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = msg["type"] as? String else { return }

        lock.lock()
        let isGreeted = greeted.contains(id)
        lock.unlock()
        guard isGreeted || type == "hello" else {
            send(connection, ["type": "error", "text": "Say hello first."])
            return
        }

        lock.lock()
        let isRestricted = restrictedClients.contains(id)
        lock.unlock()
        if isRestricted && type != "hello" && !["gaze", "screen_want", "highlight"].contains(type) {
            send(connection, ["type": "error", "text": "Mirror-only connection (the app has no token). Floating windows and terminals need the same GLANCE_QUEST_TOKEN in the app."])
            return
        }

        switch type {
        case "hello":
            // Floating windows (proto 2) carry every window's picture, so they need the token even on USB.
            let wantsWindows = (msg["proto"] as? Int) == 2
            if let token = token, (msg["token"] as? String) != token {
                // First-try trap: token set only on the Mac, app built without it. Over the USB cable (loopback)
                // the headset still gets the whole-screen mirror instead of a dead connection; terminals,
                // floating windows and actions stay locked. A wrong (not missing) token still hard-fails.
                if wantsWindows, msg["token"] == nil, Self.isLoopback(connection) {
                    lock.lock(); greeted.insert(id); restrictedClients.insert(id); lock.unlock()
                    send(connection, ["type": "hello", "mac": Host.current().localizedName ?? "Mac", "version": "quest-desk-1", "windows": false])
                    send(connection, ["type": "error", "text": "The Mac has a token but the app does not. Showing the whole screen; rebuild with GLANCE_QUEST_TOKEN for floating windows."])
                    return
                }
                send(connection, ["type": "error", "text": "Wrong token. Set the same GLANCE_QUEST_TOKEN in the Quest app."])
                connection.cancel()
                return
            }
            // No token on the Mac (the default) means no setup on the headset either: floating
            // windows just work. A token, when set, has already been checked above.
            var windowsOK = false
            if wantsWindows {
                lock.lock(); windowsClients.insert(id); lock.unlock()
                windowsOK = true
            }
            lock.lock(); greeted.insert(id); restrictedClients.remove(id); lock.unlock()
            send(connection, ["type": "hello", "mac": Host.current().localizedName ?? "Mac", "version": "quest-desk-1", "windows": windowsOK])
            sendTermList(to: connection)
            for info in terms.list {
                if let snap = terms.snapshot(id: info.id) {
                    send(connection, ["type": "term_output", "id": info.id, "title": snap.title, "text": snap.text])
                }
            }
        case "term_create":
            if let info = terms.create(title: msg["title"] as? String) {
                broadcast(["type": "term_list", "terms": terms.list.map { ["id": $0.id, "title": $0.title] }])
                if let snap = terms.snapshot(id: info.id) {
                    send(connection, ["type": "term_output", "id": info.id, "title": snap.title, "text": snap.text])
                }
            } else {
                send(connection, ["type": "error", "text": "Could not start a shell on the Mac."])
            }
        case "term_input":
            guard let termId = msg["id"] as? String, let text = msg["text"] as? String else { return }
            if !terms.input(id: termId, text) {
                send(connection, ["type": "error", "id": termId, "text": "That terminal is gone."])
            }
        case "term_close":
            if let termId = msg["id"] as? String { terms.close(id: termId) }
        case "gaze":
            onGaze?(msg)
        case "screen_want":
            let on = (msg["on"] as? Bool) ?? true
            lock.lock(); screenWanted = on; lock.unlock()
            if on { screen.start() } else { screen.stop() }
        case "windows_want":
            lock.lock()
            let isWindowsClient = windowsClients.contains(id)
            lock.unlock()
            guard isWindowsClient else {
                send(connection, ["type": "error", "text": "Floating windows are not on for this connection."])
                return
            }
            if (msg["on"] as? Bool) ?? true { startRoster() } else { stopRoster() }
        case "highlight":
            if let raw = msg["window"] as? Int {
                if raw >= 0, let id = UInt32(exactly: raw) {
                    windowPool.setHighlighted(id)
                } else if raw < 0 {
                    windowPool.clearHighlight()
                }
            }
        case "click", "double_click", "scroll", "drag_start", "drag_move", "drag_end", "drag_cancel":
            onAction?(msg)
        case "voice_begin":
            guard let termId = msg["id"] as? String else { return }
            guard let transcriber = transcriber else {
                send(connection, ["type": "error", "id": termId, "text": "Voice is off on the Mac (no Muse key), so nothing was typed."])
                return
            }
            let feed = AudioFeed()
            guard let take = transcriber.questTranscribe(feed, onPartial: { [weak self] partial in
                self?.send(connection, ["type": "voice_partial", "id": termId, "text": partial])
            }) else {
                send(connection, ["type": "error", "id": termId, "text": "Could not start voice on the Mac."])
                return
            }
            lock.lock(); voices[id] = (termId, feed, take); lock.unlock()
        case "voice_cancel":
            lock.lock()
            let take = voices[id]?.take
            voices[id] = nil
            lock.unlock()
            take?.cancel()
        case "voice_end":
            lock.lock()
            let voice = voices[id]
            voices[id] = nil
            lock.unlock()
            guard let voice = voice else { return }
            let termId = (msg["id"] as? String) ?? voice.id
            Task { [weak self] in
                let words = await voice.take.finish()
                guard let self = self else { return }
                guard let injection = QuestSpeech.injection(for: words) else {
                    self.send(connection, ["type": "error", "id": termId, "text": "Heard nothing, so nothing was typed."])
                    return
                }
                if self.terms.input(id: termId, injection) {
                    self.send(connection, ["type": "heard", "id": termId, "text": words])
                    print("Quest voice → \(termId): \(words)")
                } else {
                    self.send(connection, ["type": "error", "id": termId, "text": "That terminal is gone, so nothing was typed."])
                }
            }
        default:
            break
        }
    }

    private func handleBinary(_ id: UUID, _ data: Data) {
        guard data.first == 0x41 else { return } // "A": voice audio for the take in progress
        lock.lock()
        let feed = voices[id]?.feed
        lock.unlock()
        feed?.push(data.dropFirst())
    }

    private static func isLoopback(_ connection: NWConnection) -> Bool {
        guard case .hostPort(let host, _) = connection.endpoint else { return false }
        switch host {
        case .ipv4(let address): return address == .loopback
        case .ipv6(let address): return address == .loopback
        default: return false
        }
    }

    private func sendTermList(to connection: NWConnection) {
        send(connection, ["type": "term_list", "terms": terms.list.map { ["id": $0.id, "title": $0.title] }])
    }
}
