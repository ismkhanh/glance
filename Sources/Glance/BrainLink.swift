import Foundation

/// The app's side of the Glance brain (brain/, Node): starts it, then talks to it over a local WebSocket.
/// The brain runs the orchestrator, the parallel workers and the reviewer; see PROTOCOL.md.
final class BrainLink: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    static let port = 47800

    /// Called on the main thread with every message from the brain.
    var onMessage: (([String: Any]) -> Void)?
    /// Called on the main thread when the connection opens or closes.
    var onConnection: ((Bool) -> Void)?

    private let token = UUID().uuidString
    private let museKey: String?
    private let lock = NSLock()
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var process: Process?
    private var isOpen = false
    private var stopped = false
    private var warnedNoBrain = false
    private var restarts: [Date] = []

    /// `museKey` is the key the app found; the brain gets it too, so it works wherever brain/ is.
    init(museKey: String?) {
        self.museKey = museKey
        super.init()
    }

    var connected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isOpen
    }

    /// Starts `node brain/src/main.js` (unless a brain is already running) and connects to it.
    func start() {
        launchBrain()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { self.connect() }
    }

    func stop() {
        lock.lock()
        stopped = true
        let s = socket
        let p = process
        lock.unlock()
        s?.cancel(with: .goingAway, reason: nil)
        if let p = p, p.isRunning { p.terminate() }
    }

    func send(_ message: [String: Any]) {
        lock.lock()
        let open = isOpen ? socket : nil
        lock.unlock()
        guard let s = open,
              let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else { return }
        s.send(.string(text)) { error in
            if let error = error { print("\n(brain: could not send: \(error.localizedDescription))") }
        }
    }

    // MARK: - Starting the brain

    /// The brain folder: $GLANCE_BRAIN_DIR, or ./brain next to where `swift run` was started.
    private func brainDirectory() -> String? {
        let env = ProcessInfo.processInfo.environment
        let candidates = [env["GLANCE_BRAIN_DIR"], FileManager.default.currentDirectoryPath + "/brain"].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0 + "/src/main.js") }
    }

    /// The brain's environment: the app's own, plus how to reach the app, and the Muse key unless one is set already.
    static func environment(_ base: [String: String], token: String, museKey: String?) -> [String: String] {
        var env = base
        env["GLANCE_TOKEN"] = token
        env["GLANCE_PORT"] = String(BrainLink.port)
        env["GLANCE_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        if let key = museKey, (env["MUSE_API_KEY"] ?? "").isEmpty { env["MUSE_API_KEY"] = key }
        return env
    }

    private func launchBrain() {
        guard let dir = brainDirectory() else {
            print("Glance brain not found (expected ./brain/src/main.js). Figma commands need it; other apps still work.")
            return
        }
        if !FileManager.default.fileExists(atPath: dir + "/node_modules/ws") {
            print("The Glance brain needs one install first:  cd brain && npm install")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["node", dir + "/src/main.js"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        p.environment = BrainLink.environment(ProcessInfo.processInfo.environment, token: token, museKey: museKey)
        // If the brain stops on its own (a crash), start it again; the app reconnects by itself. Exit code 0 means
        // another brain already had the port, which is fine. More than 5 restarts in a minute: give up and say so.
        p.terminationHandler = { [weak self] proc in
            guard let self = self else { return }
            self.lock.lock()
            let done = self.stopped
            let now = Date()
            self.restarts = self.restarts.filter { now.timeIntervalSince($0) < 60 } + [now]
            let tooMany = self.restarts.count > 5
            self.lock.unlock()
            guard !done, proc.terminationStatus != 0 || proc.terminationReason == .uncaughtSignal else { return }
            if tooMany {
                print("\n(the Glance brain keeps stopping; not starting it again. Check brain/ with `npm test`.)")
                return
            }
            print("\n(the Glance brain stopped (exit \(proc.terminationStatus)); starting it again…)")
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self.launchBrain() }
        }
        do {
            try p.run()
            lock.lock()
            process = p
            lock.unlock()
        } catch {
            print("Could not start the Glance brain (is Node installed? `node --version`): \(error.localizedDescription)")
        }
    }

    // MARK: - Connection

    private func connect() {
        lock.lock()
        let done = stopped
        lock.unlock()
        guard !done, let session = session,
              let url = URL(string: "ws://127.0.0.1:\(BrainLink.port)/app?token=\(token)") else { return }
        let task = session.webSocketTask(with: url)
        lock.lock()
        socket = task
        lock.unlock()
        task.resume()
        receive(task)
    }

    private func receive(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                let data: Data?
                switch message {
                case .string(let text): data = text.data(using: .utf8)
                case .data(let d): data = d
                @unknown default: data = nil
                }
                if let data = data,
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    DispatchQueue.main.async { self.onMessage?(json) }
                }
                self.receive(task)
            case .failure:
                self.closed(task)
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.lock()
        isOpen = true
        lock.unlock()
        warnedNoBrain = false
        DispatchQueue.main.async { self.onConnection?(true) }
        send(["type": "hello", "app": "glance", "version": "0.3"])
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closed(webSocketTask)
    }

    /// Lost or never opened: tell the UI and try again in 2 s.
    private func closed(_ task: URLSessionWebSocketTask) {
        lock.lock()
        guard socket === task else {
            lock.unlock()
            return
        }
        let wasOpen = isOpen
        isOpen = false
        socket = nil
        let done = stopped
        lock.unlock()
        if wasOpen {
            DispatchQueue.main.async { self.onConnection?(false) }
        } else if !warnedNoBrain {
            warnedNoBrain = true
            print("\n(waiting for the Glance brain on port \(BrainLink.port)…)")
        }
        if !done {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.connect() }
        }
    }
}
