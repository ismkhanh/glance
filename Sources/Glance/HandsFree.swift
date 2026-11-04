import AppKit
import Foundation

// Hands-free: say "Hey Glance" once, then talk to any window by pointing at it, without holding a key. Each thing
// you say is a command for the window under the pointer when you start saying it, exactly as if you held the talk
// key while you spoke. The session ends with Esc, "thanks, Glance", or 30 s without speech.
//
// While Glance waits for "Hey Glance", a voice detector on the Mac finds speech, and only speech goes to Muse Voice
// Transcribe. Glance stops sending as soon as the first words are not "Hey Glance", and drops what it heard.

/// Audio pushed into a voice session by the hands-free listener, instead of the session's own microphone.
/// Audio pushed before the session attaches is kept, so the first syllable is not lost.
final class AudioFeed: @unchecked Sendable {
    private static let keepAtMost = 24_000 * 2 * 20     // 20 s of audio, if no session ever attaches
    private let lock = NSLock()
    private var sink: ((Data) -> Void)?
    private var early: [Data] = []
    private var earlyBytes = 0

    func attach(_ sink: @escaping (Data) -> Void) {
        lock.lock()
        let kept = early
        early = []
        earlyBytes = 0
        self.sink = sink
        lock.unlock()
        for chunk in kept { sink(chunk) }
    }

    func detach() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    func push(_ data: Data) {
        lock.lock()
        if let sink = sink {
            lock.unlock()
            sink(data)
            return
        }
        if earlyBytes < AudioFeed.keepAtMost {
            early.append(data)
            earlyBytes += data.count
        }
        lock.unlock()
    }
}

/// Finds where speech starts and ends in 24 kHz 16-bit audio, by loudness against the room's own noise level,
/// which it learns while nobody talks. Works in 20 ms frames.
struct VoiceActivity {
    enum Event: Equatable { case started, ended }

    static let frameBytes = 480 * 2          // 20 ms
    static let frameSeconds = 0.02
    var startFrames = 3                      // 60 ms clearly above the room starts speech
    var endFrames = 40                       // 800 ms back near the room ends it (a comma's pause does not)
    var longestFrames = 750                  // 15 s: longer is the room getting louder, not speech
    private(set) var speaking = false
    private(set) var floor = -60.0           // dBFS
    private var loud = 0
    private var quiet = 0
    private var spoken = 0
    private var speechLevel = -90.0

    /// Loudness of one frame in dBFS (RMS), -90 for silence.
    static func level(_ frame: Data) -> Double {
        let count = frame.count / 2
        guard count > 0 else { return -90 }
        var sum = 0.0
        frame.withUnsafeBytes { raw in
            for s in raw.bindMemory(to: Int16.self) { sum += Double(s) * Double(s) }
        }
        let rms = (sum / Double(count)).squareRoot() / 32768
        return max(-90, 20 * log10(max(rms, 1e-9)))
    }

    mutating func process(_ frame: Data) -> Event? {
        process(level: VoiceActivity.level(frame))
    }

    mutating func process(level db: Double) -> Event? {
        if speaking {
            spoken += 1
            speechLevel = speechLevel * 0.95 + db * 0.05
            if spoken >= longestFrames {
                // A fan or music came on: that is the room now.
                speaking = false
                floor = min(max(speechLevel - 3, -90), -30)
                return .ended
            }
            if db < max(floor + 7, -54) {
                quiet += 1
                if quiet >= endFrames {
                    speaking = false
                    quiet = 0
                    return .ended
                }
            } else {
                quiet = 0
            }
            return nil
        }
        if db > max(floor + 12, -48) {
            loud += 1
            if loud >= startFrames {
                speaking = true
                loud = 0
                quiet = 0
                spoken = 0
                speechLevel = db
                return .started
            }
            return nil
        }
        loud = 0
        // The room's level: follows quieter frames quickly (in about 0.1 s) and louder ones slowly (about 1 s).
        floor = db < floor ? floor * 0.85 + db * 0.15 : floor + (db - floor) * 0.02
        floor = min(max(floor, -90), -30)
        return nil
    }

    /// A frame that must not count as speech (Glance's own voice or sound): it can end speech, and teaches nothing
    /// about the room.
    mutating func ignore() -> Event? {
        guard speaking else {
            loud = 0
            return nil
        }
        return process(level: -90)
    }

    /// Back to waiting for speech (the room's level is kept).
    mutating func reset() {
        speaking = false
        loud = 0
        quiet = 0
    }
}

/// "Hey Glance" as speech to text writes it, and the phrases that end a hands-free session.
enum WakePhrase {
    private static let greetings: Set<String> = ["hey", "hi", "hay", "hei", "a", "ok", "okay", "hello", "yo"]
    private static let names: Set<String> = ["glance", "glances", "glans", "glanz", "glants", "lance", "clance"]
    private static let goodbyes: Set<String> = [
        "thanks", "thank you", "thanks glance", "thank you glance", "bye glance", "goodbye glance", "good bye glance",
        "stop listening", "glance stop listening", "thats all", "thats all glance", "thats it", "thats it glance",
        "go to sleep", "glance go to sleep", "sleep glance",
    ]
    private static let lead = try! NSRegularExpression(
        pattern: "^\\W*(\(greetings.sorted().joined(separator: "|")))\\W+(\(names.sorted().joined(separator: "|")))\\b\\W*",
        options: [.caseInsensitive])

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "")
            .replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// "Hey Glance, make this red." → (true, "make this red."); "Take a glance at this" → (false, the text).
    static func split(_ text: String) -> (woke: Bool, rest: String) {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = lead.firstMatch(in: text, range: range), let end = Range(match.range, in: text) else {
            return (false, text)
        }
        return (true, String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// While the words are still coming in: false as soon as the first two cannot be "Hey Glance".
    static func mightStart(_ partial: String) -> Bool {
        let w = words(partial)
        guard w.count >= 2 else { return true }
        return greetings.contains(w[0]) && names.contains(w[1])
    }

    /// "Thanks, Glance", "stop listening", "that's all": the whole sentence, so "stop the server" is a command.
    static func isGoodbye(_ text: String) -> Bool {
        goodbyes.contains(words(text).joined(separator: " "))
    }
}

/// Whether Glance is listening: the talk key is held, or a hands-free session is on. The mascot's eye is open only
/// then, and a short sound marks each change, so you always know whether Glance can hear you.
final class Presence: @unchecked Sendable {
    static let shared = Presence()
    enum Reason { case key, session }

    private let lock = NSLock()
    private var reasons: Set<Reason> = []
    private var lastSound = Date.distantPast
    private var sounds = true

    var soundsOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return sounds }
        set { lock.lock(); sounds = newValue; lock.unlock() }
    }

    var listening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !reasons.isEmpty
    }

    /// True for a moment after a sound, so the hands-free listener does not take Glance's own sound for speech.
    var justPlayed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastSound) < 0.6
    }

    func set(_ reason: Reason, _ on: Bool) {
        lock.lock()
        let before = !reasons.isEmpty
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        let after = !reasons.isEmpty
        let play = sounds && before != after
        if play { lastSound = Date() }
        lock.unlock()
        guard before != after else { return }
        DispatchQueue.main.async {
            MascotModel.shared.awake = after
            if play, let sound = NSSound(named: after ? "Tink" : "Bottle") {
                sound.volume = 0.4
                sound.play()
            }
        }
    }
}

/// One utterance heard while waiting for "Hey Glance": transcribed, never run.
protocol Transcription: AnyObject, Sendable {
    func finish() async -> String
    func cancel()
}

extension VoiceSession: Transcription {
    func finish() async -> String { (try? await stopTalking()) ?? "" }
    func cancel() { close() }
}

/// What hands-free needs from Glance (Glance itself; the tests stand in for it).
protocol HandsFreeHost: AnyObject, Sendable {
    func keyDown(feed: AudioFeed?)
    func keyUp()
    func cancelHeld()
    func transcribe(_ feed: AudioFeed, onPartial: @escaping (String) -> Void) -> Transcription?
    func runTyped(_ command: String) async
    var isSpeaking: Bool { get }
}

/// Listens for "Hey Glance", then runs the hands-free session. One microphone for everything: while the talk key
/// is held, its audio goes to the key's command instead.
final class HandsFree: @unchecked Sendable {   // all state lives on `queue`
    var idleTimeout = 30.0                   // seconds without speech that end a session
    var onSessionChange: ((Bool) -> Void)?

    private enum Kind {
        case wake(Transcription)             // waiting for "Hey Glance": only transcribed
        case command                         // in a session: a talk-key press, made by voice
    }

    private struct Utterance {
        let feed: AudioFeed
        let kind: Kind
        var frames = 0                       // how long it is, in 20 ms frames of audio
        var dropped = false
    }

    private let queue = DispatchQueue(label: "glance.handsfree")
    private let keys = DispatchQueue(label: "glance.handsfree.keys")   // keeps key down before key up
    private let mic = MicCapture()
    private let host: HandsFreeHost
    private let presence: Presence
    private var vad = VoiceActivity()
    private var pendingBytes = Data()
    private var preroll: [Data] = []         // the last 400 ms, so a command keeps its first syllable
    private var running = false
    private var active = false
    private var lastSpeech = Date()
    private var utterance: Utterance?
    private var borrowed: AudioFeed?
    private var ticker: DispatchSourceTimer?

    init(host: HandsFreeHost, presence: Presence = .shared) {
        self.host = host
        self.presence = presence
    }

    var isRunning: Bool { queue.sync { running } }
    var isActive: Bool { queue.sync { active } }

    /// Starts listening for "Hey Glance". Returns false if the microphone could not start.
    func start() -> Bool {
        queue.sync {
            guard !running else { return true }
            do {
                try mic.start { [weak self] data in
                    self?.queue.async { self?.hear(data) }
                }
            } catch {
                print("\nHands-free could not start the microphone: \(error)")
                return false
            }
            arm()
            return true
        }
    }

    /// Listening without the microphone: the tests push audio with `listen(_:)`.
    func startWithoutMic() {
        queue.sync { if !running { arm() } }
    }

    /// Audio, as the microphone would bring it (for the tests; waits until it is handled).
    func listen(_ data: Data) {
        queue.sync { hear(data) }
    }

    func stop() {
        queue.sync {
            guard running else { return }
            endSession(nil)
            ticker?.cancel()
            ticker = nil
            mic.stop()
            running = false
            print("\nNot listening for “Hey Glance” any more.")
        }
    }

    /// Esc anywhere: the session ends, and anything half said is dropped.
    func escape() {
        queue.async {
            if self.active { self.endSession("Esc") }
        }
    }

    /// The talk key went down. Returns true if hands-free owns the microphone, so the key's command gets its audio.
    func keyDown() -> Bool {
        queue.sync {
            guard running else { return false }
            if borrowed != nil { return true }
            dropUtterance()
            let feed = AudioFeed()
            borrowed = feed
            vad.reset()
            keys.async { self.host.keyDown(feed: feed) }
            return true
        }
    }

    func keyUp() -> Bool {
        queue.sync {
            guard borrowed != nil else { return false }
            borrowed = nil
            if active { lastSpeech = Date() }
            keys.async { self.host.keyUp() }
            return true
        }
    }

    /// Every transcript of a command passes here first: nil drops it. "Thanks, Glance" ends the session, and a
    /// "Hey Glance" said again inside one is taken off the front.
    func filter(_ text: String) -> String? {
        let inSession = queue.sync { active }
        if inSession && WakePhrase.isGoodbye(text) {
            queue.async { self.endSession("you said “\(text.trimmingCharacters(in: .whitespacesAndNewlines))”") }
            return nil
        }
        let (woke, rest) = WakePhrase.split(text)
        if woke { return rest.isEmpty ? nil : rest }
        return text
    }

    /// Waits until the key presses hands-free made have reached Glance (for the tests).
    func settle() {
        queue.sync {}
        keys.sync {}
    }

    // MARK: - Private (all on `queue`)

    private func arm() {
        running = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.checkIdle() }
        timer.resume()
        ticker = timer
        print("\nListening for “Hey Glance”. Then point and talk; Esc or “thanks, Glance” ends it.")
    }

    private func hear(_ data: Data) {
        if let feed = borrowed {
            feed.push(data)
            return
        }
        pendingBytes.append(data)
        var offset = 0
        while pendingBytes.count - offset >= VoiceActivity.frameBytes {
            frame(pendingBytes.subdata(in: offset..<(offset + VoiceActivity.frameBytes)))
            offset += VoiceActivity.frameBytes
        }
        pendingBytes = pendingBytes.subdata(in: offset..<pendingBytes.count)
    }

    private func frame(_ frame: Data) {
        // Glance's own voice and sounds are not speech to listen to.
        let deaf = host.isSpeaking || presence.justPlayed
        let event = deaf ? vad.ignore() : vad.process(frame)
        if let u = utterance {
            u.feed.push(frame)
            utterance?.frames += 1
        } else {
            preroll.append(frame)
            if preroll.count > 20 { preroll.removeFirst(preroll.count - 20) }
        }
        switch event {
        case .started?: beginUtterance()
        case .ended?: finishUtterance()
        case nil: break
        }
    }

    private func beginUtterance() {
        let feed = AudioFeed()
        for f in preroll { feed.push(f) }
        preroll.removeAll()
        if active {
            lastSpeech = Date()
            utterance = Utterance(feed: feed, kind: .command)
            keys.async { self.host.keyDown(feed: feed) }
            return
        }
        let heard = host.transcribe(feed) { [weak self] partial in
            self?.queue.async {
                guard let self = self, !WakePhrase.mightStart(partial), let u = self.utterance, u.feed === feed,
                      case .wake(let t) = u.kind else { return }
                t.cancel()                 // not for Glance: stop sending
                self.utterance?.dropped = true
            }
        }
        guard let transcription = heard else { return }
        utterance = Utterance(feed: feed, kind: .wake(transcription))
    }

    private func finishUtterance() {
        guard let u = utterance else { return }
        utterance = nil
        switch u.kind {
        case .command:
            lastSpeech = Date()
            keys.async { self.host.keyUp() }
        case .wake(let transcription):
            u.feed.detach()
            if u.dropped { return }                                              // already stopped sending
            if Double(u.frames) * VoiceActivity.frameSeconds < 0.4 {            // a cough, a door
                transcription.cancel()
                return
            }
            Task.detached {
                let text = await transcription.finish()
                self.queue.async { self.heardWhileWaiting(text) }
            }
        }
    }

    private func heardWhileWaiting(_ text: String) {
        let (woke, rest) = WakePhrase.split(text)
        guard woke, running, !active else { return }
        active = true
        lastSpeech = Date()
        presence.set(.session, true)
        onSessionChange?(true)
        print("\nHey! Hands-free: point at a window and talk. Esc or “thanks, Glance” ends it.")
        if !rest.isEmpty {
            // "Hey Glance, make this red" in one breath: the rest is a command for the window under the pointer.
            Task.detached { await self.host.runTyped(rest) }
        }
        Glance.prompt()
    }

    private func dropUtterance() {
        guard let u = utterance else { return }
        utterance = nil
        u.feed.detach()
        switch u.kind {
        case .wake(let transcription): transcription.cancel()
        case .command: keys.async { self.host.cancelHeld() }
        }
    }

    private func checkIdle() {
        guard active, utterance == nil, borrowed == nil,
              Date().timeIntervalSince(lastSpeech) > idleTimeout else { return }
        endSession("\(Int(idleTimeout)) s without speech")
    }

    private func endSession(_ why: String?) {
        dropUtterance()
        vad.reset()
        preroll.removeAll()
        guard active else { return }
        active = false
        presence.set(.session, false)
        onSessionChange?(false)
        if let why = why {
            print("\nHands-free session ended (\(why)). Say “Hey Glance” to start again.")
            Glance.prompt()
        }
    }
}
