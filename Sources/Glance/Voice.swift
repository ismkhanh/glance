import AVFoundation
import Foundation

/// Demo recordings: with GLANCE_DEMO_VOICE set to a folder, a WAV path written to `<folder>/next` is spoken
/// instead of the microphone on the next key press (24 kHz mono 16-bit, sent at real speed), so the real
/// transcription hears it. `<folder>/queue` holds one WAV path per line: each key press takes the next one.
/// Used files and lines are removed; with neither, the microphone is used as usual.
enum DemoVoice {
    static func takeClip() -> Data? {
        guard let dir = ProcessInfo.processInfo.environment["GLANCE_DEMO_VOICE"],
              let path = take(dir + "/next") ?? take(dir + "/queue") else { return nil }
        guard let wav = FileManager.default.contents(atPath: path),
              let marker = wav.range(of: Data("data".utf8)) else {
            print("  (demo voice: could not read \(path))")
            return nil
        }
        print(String(format: "  (demo voice: %@ at %.3f)", (path as NSString).lastPathComponent, Date().timeIntervalSince1970))
        return wav.subdata(in: (marker.upperBound + 4)..<wav.count)
    }

    /// The first non-empty line of the file; the rest is written back (or the file removed when empty).
    private static func take(_ file: String) -> String? {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst()
        if lines.isEmpty {
            try? FileManager.default.removeItem(atPath: file)
        } else {
            try? (lines.joined(separator: "\n") + "\n").write(toFile: file, atomically: true, encoding: .utf8)
        }
        return first
    }
}

/// Microphone → 24 kHz, mono, 16-bit PCM, the format Muse Voice Transcribe wants.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true)!
    private var clipTimer: DispatchSourceTimer?

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default:
            return false
        }
    }

    func start(onData: @escaping (Data) -> Void) throws {
        if let clip = DemoVoice.takeClip() {
            startClip(clip, onData: onData)
            return
        }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw ScriptError(message: "Cannot read the microphone. Check System Settings > Privacy & Security > Microphone for Terminal.")
        }
        converter.downmix = true
        let outFormat = self.outFormat
        input.installTap(onBus: 0, bufferSize: 2048, format: inFormat) { buffer, _ in
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if given {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                given = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData else { return }
            onData(Data(bytes: samples[0], count: Int(out.frameLength) * 2))
        }
        engine.prepare()
        try engine.start()
    }

    /// Sends the clip in 80 ms frames at real speed, then silence until `stop()`, like a microphone would.
    private func startClip(_ clip: Data, onData: @escaping (Data) -> Void) {
        let frame = 24000 * 2 * 80 / 1000
        var offset = 0
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "glance.demovoice"))
        timer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(5))
        timer.setEventHandler {
            if offset < clip.count {
                let end = min(offset + frame, clip.count)
                onData(clip.subdata(in: offset..<end))
                offset = end
            } else {
                onData(Data(count: frame))
            }
        }
        timer.resume()
        clipTimer = timer
        clipEndsAt = Date().addingTimeInterval(Double(clip.count) / 48000 + 0.3)
    }

    private var clipEndsAt = Date.distantPast

    func stop() {
        if let timer = clipTimer {
            // A clip is always heard to the end, however short the key was held.
            let left = clipEndsAt.timeIntervalSinceNow
            if left > 0 { Thread.sleep(forTimeInterval: left) }
            timer.cancel()
            clipTimer = nil
            return
        }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// One Muse Voice Transcribe realtime session in push-to-talk mode.
///
/// Opening a session took 1.9–3.9 s in the 31 Oct test, longer than saying "pause". So a session is opened
/// ahead of time and fed silence until you talk. Mic audio that arrives before the session is ready is kept
/// and sent as soon as it is.
///
/// The service closes a session whose audio falls behind real time, so audio is paced by the clock:
/// a pacer tops up silence until "audio sent" = "time passed" + a small lead (the service allows up to 5 s ahead).
final class VoiceSession: @unchecked Sendable {   // all state lives on `queue`
    var onPartial: ((String) -> Void)?
    let openedAt = Date()

    private static let rate = 24_000        // samples per second
    private static let idleLead = 0.3       // seconds of audio kept ahead of real time while waiting

    private let key: String
    private let queue = DispatchQueue(label: "glance.voice")
    private var socket: URLSessionWebSocketTask?
    private var ready = false
    private var readyAt = 0.0
    private var sentSamples = 0
    private var talking = false
    private var endRequested = false
    private var pending: [Data] = []
    private var pacer: DispatchSourceTimer?
    private var waiter: CheckedContinuation<String, Error>?
    private var failure: String?
    private var done = false
    private var feed: AudioFeed?
    private let mic = MicCapture()

    init(key: String) {
        self.key = key
    }

    /// Whether the session was ready when you started talking (if not, your words wait for it).
    private(set) var readyWhenTalkStarted = false

    /// False once the session has ended or failed (for example, closed by the service while waiting).
    var isAlive: Bool {
        queue.sync { !done }
    }

    func open() {
        queue.async {
            let url = URL(string: "wss://api.meta.ai/v1/asr/realtime?sessionId=glance-\(UUID().uuidString)")!
            let task = URLSession.shared.webSocketTask(with: url)
            self.socket = task
            task.resume()
            let handshake: [String: Any] = [
                "authorization": ["accessToken": "Bearer \(self.key)"],
                "audioEncoding": "PCM_24KHZ",
                "model": "muse-voice-transcribe-1.0",
                "mode": "PUSH_TO_TALK",
                "partialMode": "CUMULATIVE",
                "languageBias": ["English"],
                "emitAudioProgress": false,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: handshake),
                  let text = String(data: data, encoding: .utf8) else { return }
            task.send(.string(text)) { error in
                if let error = error { self.queue.async { self.fail("Could not start voice: \(error.localizedDescription)") } }
            }
            self.receive()
        }
    }

    /// Starts sending the microphone, or the hands-free listener's audio when `feed` is given. Call when the user
    /// starts talking.
    func startTalking(feed: AudioFeed? = nil) throws {
        queue.sync {
            talking = true
            readyWhenTalkStarted = ready
            self.feed = feed
        }
        let deliver: (Data) -> Void = { [weak self] data in
            guard let self = self else { return }
            self.queue.async {
                if self.done || self.endRequested { return }
                if self.ready {
                    self.send(data)
                } else {
                    self.pending.append(data)
                }
            }
        }
        if let feed = feed {
            feed.attach(deliver)
            return
        }
        do {
            try mic.start(onData: deliver)
        } catch {
            queue.sync { talking = false }
            throw error
        }
    }

    /// Stops the microphone (or the feed) and waits for the final transcript.
    func stopTalking(timeout: Double = 12) async throws -> String {
        if let feed = queue.sync(execute: { self.feed }) {
            feed.detach()
        } else {
            mic.stop()
        }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            queue.async {
                if let f = self.failure {
                    cont.resume(throwing: ScriptError(message: f))
                    return
                }
                self.waiter = cont
                self.endRequested = true
                if self.ready { self.sendEnd() }
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.fail("No transcript after \(Int(timeout)) s.")
                }
            }
        }
    }

    func close() {
        queue.async { self.shutDown() }
    }

    // MARK: - Private (all on `queue`)

    private func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }

    private func send(_ chunk: Data) {
        socket?.send(.data(chunk)) { _ in }
        sentSamples += chunk.count / 2
    }

    private func receive() {
        socket?.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                switch result {
                case .failure(let error):
                    self.fail("Voice connection closed: \(error.localizedDescription)")
                case .success(let message):
                    if case .string(let text) = message { self.handle(text) }
                    if !self.done { self.receive() }
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return }
        let type = json["type"] as? String ?? ""
        if type.isEmpty, json["sessionId"] != nil {
            ready = true
            readyAt = now()
            for chunk in pending { send(chunk) }
            pending = []
            startPacer()
            if endRequested { sendEnd() }
            return
        }
        switch type {
        case "transcript":
            let t = json["transcript"] as? String ?? ""
            if (json["final"] as? Bool) == true {
                finish(t)
            } else {
                onPartial?(t)
            }
        case "error":
            fail(json["message"] as? String ?? "Voice error.")
        default:
            break
        }
    }

    private func sendEnd() {
        socket?.send(.string("{\"type\":\"endStream\"}")) { _ in }
    }

    /// Every 20 ms: if less audio has been sent than time has passed (plus the lead), send silence to catch up.
    /// While you talk the microphone keeps it ahead, so silence is only added if the microphone stalls.
    private func startPacer() {
        guard pacer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self = self, self.ready, !self.done, !self.endRequested else { return }
            let lead = self.talking ? 0 : VoiceSession.idleLead
            let due = Int((self.now() - self.readyAt + lead) * Double(VoiceSession.rate))
            let missing = due - self.sentSamples
            if missing > 0 {
                self.send(Data(count: min(missing, VoiceSession.rate) * 2))
            }
        }
        timer.resume()
        pacer = timer
    }

    private func finish(_ text: String) {
        guard !done else { return }
        waiter?.resume(returning: text)
        waiter = nil
        shutDown()
    }

    private func fail(_ message: String) {
        guard !done else { return }
        failure = message
        waiter?.resume(throwing: ScriptError(message: message))
        waiter = nil
        shutDown()
    }

    private func shutDown() {
        done = true
        pacer?.cancel()
        pacer = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
    }
}
