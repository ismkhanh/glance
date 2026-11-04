import AppKit
import Foundation

// Hands-free: say "Hey Glance" once, then talk to any window by pointing at it, without holding a key. Each thing
// you say is a command for the window under the pointer when you start saying it, exactly as if you held the talk
// key while you spoke. The session ends with Esc, "thanks, Glance", or when 10 s pass without a command: from
// "Hey Glance", or from the last command that ran. Talk and noise that run nothing do not keep it on.
//
// While Glance waits for "Hey Glance", a voice detector on the Mac finds speech, and only speech goes to Muse Voice
// Transcribe: at most its first 2 s until its words show it starts with "Hey Glance". Glance stops sending as soon
// as the first words are not "Hey Glance", and drops what it heard. The rest of what is said stays on the Mac.

/// Audio pushed into a voice session by the hands-free listener, instead of the session's own microphone.
/// Audio pushed before the session attaches is kept, so the first syllable is not lost.
final class AudioFeed: @unchecked Sendable {
    private static let keepAtMost = 24_000 * 2 * 20     // 20 s of audio, if no session ever attaches
    private let lock = NSLock()
    private var sink: ((Data) -> Void)?
    private var early: [Data] = []
    private var earlyBytes = 0

    /// The sink gets the kept audio, then the rest as it comes, in order. It is called with the feed's lock held,
    /// so it must hand the audio on and not call back into the feed.
    func attach(_ sink: @escaping (Data) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        for chunk in early { sink(chunk) }
        early = []
        earlyBytes = 0
        self.sink = sink
    }

    func detach() {
        lock.lock()
        sink = nil
        lock.unlock()
    }

    func push(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let sink = sink {
            sink(data)
        } else if earlyBytes < AudioFeed.keepAtMost {
            early.append(data)
            earlyBytes += data.count
        }
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

    /// A frame that must not count (Glance's own voice or sound): it neither starts speech nor ends it, so a sound
    /// played while you talk does not cut you off, and it teaches nothing about the room.
    mutating func ignore() {
        if speaking { spoken += 1 } else { loud = 0 }
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
    /// "Hey, glance at this": the verb, said to someone else, not Glance's name.
    private static let afterTheVerb: Set<String> = ["at", "over", "through", "around", "across", "toward", "towards"]
    private static let goodbyes: Set<String> = [
        "thanks", "thank you", "thanks so much", "thank you so much", "bye", "goodbye", "good bye",
        "stop listening", "thats all", "thats it", "go to sleep", "sleep",
    ]
    /// Said before a goodbye: "OK, thanks Glance", "great, thank you".
    private static let fillers: Set<String> = ["ok", "okay", "alright", "great", "cool", "perfect", "nice", "oh", "um",
                                               "uh", "well", "so", "hey", "hi"]
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

    /// "Hey Glance, make this red." → (true, "make this red."); "Hey, glance at this" → (false, the text).
    static func split(_ text: String) -> (woke: Bool, rest: String) {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = lead.firstMatch(in: text, range: range), let end = Range(match.range, in: text) else {
            return (false, text)
        }
        let rest = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let next = words(rest).first, afterTheVerb.contains(next) { return (false, text) }
        return (true, rest)
    }

    /// While the words are still coming in: false as soon as they cannot be "Hey Glance" (the first two words are
    /// something else, or the third shows "glance" was the verb).
    static func mightStart(_ partial: String) -> Bool {
        let w = words(partial)
        guard w.count >= 2 else { return true }
        guard greetings.contains(w[0]), names.contains(w[1]) else { return false }
        return w.count < 3 || !afterTheVerb.contains(w[2])
    }

    /// The words so far surely start with "Hey Glance": a word follows it, and that word is not "at".
    static func confirms(_ partial: String) -> Bool {
        words(partial).count >= 3 && mightStart(partial)
    }

    /// "Thanks, Glance", "OK, stop listening", "that's all": the whole sentence, so "stop the server" is a command.
    static func isGoodbye(_ text: String) -> Bool {
        var w = words(text).filter { !names.contains($0) }
        while let first = w.first, fillers.contains(first) { w.removeFirst() }
        return goodbyes.contains(w.joined(separator: " "))
    }
}

/// Whether Glance is listening: the talk key is held, or a hands-free session is on. The mascot's eye and the glow
/// show only then, and a short sound marks each change, so you always know whether Glance can hear you. In a
/// session, a pop says a command was heard to its end: point at the next window and go on.
final class Presence: @unchecked Sendable {
    static let shared = Presence()
    enum Reason { case key, session }

    /// How long after it starts each sound can reach the microphone: audible for 0.06 s (Tink), 0.22 s (Pop) and
    /// 0.5 s (Bottle), plus the speaker's delay and the room's echo.
    private static let heardFor: [String: Double] = ["Tink": 0.4, "Pop": 0.55, "Bottle": 0.8]

    private let lock = NSLock()
    private var reasons: Set<Reason> = []
    private var deafUntil = Date.distantPast
    private var sounds = true
    private var heard = 0

    var soundsOn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return sounds }
        set { lock.lock(); sounds = newValue; lock.unlock() }
    }

    var listening: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !reasons.isEmpty
    }

    /// True while one of Glance's sounds can still be heard, so the hands-free listener does not take it for speech.
    var justPlayed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date() < deafUntil
    }

    /// Commands heard to their end in hands-free sessions (for the tests).
    var commandsHeard: Int {
        lock.lock()
        defer { lock.unlock() }
        return heard
    }

    func set(_ reason: Reason, _ on: Bool) {
        lock.lock()
        let before = !reasons.isEmpty
        if on { reasons.insert(reason) } else { reasons.remove(reason) }
        let after = !reasons.isEmpty
        let sound = sounds && before != after ? (after ? "Tink" : "Bottle") : nil
        if let name = sound { deafen(name) }
        lock.unlock()
        guard before != after else { return }
        DispatchQueue.main.async {
            MascotModel.shared.awake = after
            if let name = sound { Presence.play(name) }
        }
    }

    /// A hands-free command was heard to its end: a pop, so you know you can point at the next window.
    func gotIt() {
        lock.lock()
        heard += 1
        let play = sounds
        if play { deafen("Pop") }
        lock.unlock()
        if play { DispatchQueue.main.async { Presence.play("Pop") } }
    }

    /// With `lock` held.
    private func deafen(_ name: String) {
        deafUntil = max(deafUntil, Date().addingTimeInterval(Presence.heardFor[name] ?? 1.0))
    }

    private static func play(_ name: String) {
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0.4
        sound.play()
    }
}

/// One utterance heard while waiting for "Hey Glance": transcribed, never run. `cancel()` may come after `finish()`.
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
    /// What is under the pointer now. A hands-free command goes where you pointed as you started saying it.
    func attention() -> Attention
    func keyDown(feed: AudioFeed?, at: Attention?)
    func keyUp()
    func cancelHeld()
    func transcribe(_ feed: AudioFeed, onPartial: @escaping (String) -> Void) -> Transcription?
    func runTyped(_ command: String, at: Attention?) async
    var isSpeaking: Bool { get }
    /// A yes/no question waits for its answer (the session stays on for it).
    var isAsking: Bool { get }
}

/// Listens for "Hey Glance", then runs the hands-free session. One microphone for everything: while the talk key
/// is held, its audio goes to the key's command instead.
final class HandsFree: @unchecked Sendable {   // all state lives on `queue`
    /// The most of anything said that goes to Muse before its words show it starts with "Hey Glance".
    static let wakeFrames = 100              // 2 s, in 20 ms frames
    var onSessionChange: ((Bool) -> Void)?

    /// One stretch of speech, from just before it started.
    private final class Utterance: @unchecked Sendable {   // used on `queue` only
        enum Kind {
            case wake(AudioFeed, Transcription)   // waiting for "Hey Glance": its start is transcribed, never run
            case held                             // said while an earlier "Hey Glance" is still being transcribed
            case command(AudioFeed)               // in a session: a talk-key press, made by voice
            case dropped                          // not for Glance
        }
        var kind = Kind.held
        let at: Attention                         // what was under the pointer as it started
        var audio: [Data]                         // all of it so far, kept on the Mac (until it is a command)
        var sent = 0                              // frames of `audio` sent to be checked for "Hey Glance"
        var confirmed = false                     // its words so far start with "Hey Glance"
        var frames = 0                            // 20 ms frames heard since speech started
        var ended = false

        init(at: Attention, audio: [Data]) {
            self.at = at
            self.audio = audio
        }
    }

    private let queue = DispatchQueue(label: "glance.handsfree")
    private let keys = DispatchQueue(label: "glance.handsfree.keys")   // keeps key down before key up
    private let mic = MicCapture(demoClips: false)                       // demo clips are for the talk key
    private let host: HandsFreeHost
    private let presence: Presence
    private var vad = VoiceActivity()
    private var pendingBytes = Data()
    private var preroll: [Data] = []         // the last 400 ms, so a command keeps its first syllable
    private var running = false
    private var active = false
    private var idleSeconds = 10.0
    private var lastCommand = Date()         // the session's start, or its last command that ran
    private var awaiting = 0                 // commands said whose words are not back from Glance yet
    private var awaitingSince = Date()
    private var current: Utterance?          // being said now
    private var checking: Utterance?         // finished; its transcript says whether it was "Hey Glance"
    private var held: [Utterance] = []       // said meanwhile, kept on the Mac until then
    private var borrowed: AudioFeed?
    private var ticker: DispatchSourceTimer?

    init(host: HandsFreeHost, presence: Presence = .shared) {
        self.host = host
        self.presence = presence
    }

    var isRunning: Bool { queue.sync { running } }
    var isActive: Bool { queue.sync { active } }

    /// Seconds without a command that end a session.
    var idleTimeout: Double {
        get { queue.sync { idleSeconds } }
        set { queue.sync { idleSeconds = newValue } }
    }

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
            dropAll()
            let feed = AudioFeed()
            borrowed = feed
            vad.reset()
            keys.async { self.host.keyDown(feed: feed, at: nil) }
            return true
        }
    }

    func keyUp() -> Bool {
        queue.sync {
            guard borrowed != nil else { return false }
            borrowed = nil
            if active { lastCommand = Date() }      // a command with the talk key counts too
            keys.async { self.host.keyUp() }
            return true
        }
    }

    /// Every transcript of a command passes here first: nil drops it. "Thanks, Glance" ends the session, and a
    /// "Hey Glance" said again inside one is taken off the front. With hands-free off, the words pass unchanged.
    func filter(_ text: String) -> String? {
        let (on, inSession) = queue.sync { (running, active) }
        guard on else { return text }
        if inSession && WakePhrase.isGoodbye(text) {
            queue.async { self.endSession("you said “\(text.trimmingCharacters(in: .whitespacesAndNewlines))”") }
            return nil
        }
        let (woke, rest) = WakePhrase.split(text)
        if woke { return rest.isEmpty ? nil : rest }
        return text
    }

    /// Glance has the words of a command said in a session: `ran` if they ran as a command or answered a question.
    /// Words that ran nothing (noise, talk Glance couldn't use) don't keep the session on.
    func commandDone(ran: Bool) {
        queue.async {
            self.awaiting = max(0, self.awaiting - 1)
            if ran && self.active { self.lastCommand = Date() }
        }
    }

    /// Waits until what hands-free has heard so far has been handled, and its key presses have reached Glance
    /// (for the tests).
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
        var event: VoiceActivity.Event?
        if deaf { vad.ignore() } else { event = vad.process(frame) }
        if let u = current {
            u.frames += 1
            switch u.kind {
            case .command(let feed): feed.push(frame)
            case .wake: u.audio.append(frame); send(u)
            case .held: u.audio.append(frame)
            case .dropped: break
            }
        } else if deaf {
            preroll.removeAll()          // a command said right after must not start with Glance's sound
        } else {
            preroll.append(frame)
            if preroll.count > 20 { preroll.removeFirst(preroll.count - 20) }
        }
        switch event {
        case .started?: begin()
        case .ended?: end()
        case nil: break
        }
    }

    private func begin() {
        let u = Utterance(at: host.attention(), audio: preroll)
        preroll.removeAll()
        current = u
        if active {
            startCommand(u)
        } else if checking != nil {
            held.append(u)               // "Hey Glance" may have just been said: wait for its transcript
        } else {
            startWake(u)
        }
    }

    private func end() {
        guard let u = current else { return }
        current = nil
        u.ended = true
        // A cough, a door, a click: too short to be words (the last 800 ms are the quiet that ended it).
        let short = Double(u.frames - vad.endFrames + vad.startFrames) * VoiceActivity.frameSeconds < 0.3
        switch u.kind {
        case .command:
            if !short {
                presence.gotIt()
                expectWords()
            }
            keys.async { short ? self.host.cancelHeld() : self.host.keyUp() }
        case .wake(_, let transcription):
            if short {
                transcription.cancel()
                drop(u)
            } else {
                if u.confirmed { presence.gotIt() }     // "Hey Glance, make this red" in one breath
                check(u, transcription)
            }
        case .held:
            if short { held.removeAll { $0 === u } }
        case .dropped:
            break
        }
    }

    /// Waiting for "Hey Glance": what is said goes to be transcribed, 2 s of it at most until its words confirm it.
    private func startWake(_ u: Utterance) {
        let feed = AudioFeed()
        let heard = host.transcribe(feed) { [weak self, weak u] partial in
            self?.queue.async {
                if let u = u { self?.heard(partial, in: u) }
            }
        }
        guard let transcription = heard else {
            u.kind = .dropped
            return
        }
        u.kind = .wake(feed, transcription)
        send(u)
    }

    /// Sends what the "Hey Glance" check may have so far: the first 2 s, or all of it once its words confirm it.
    private func send(_ u: Utterance) {
        guard case .wake(let feed, _) = u.kind else { return }
        let allowed = u.confirmed ? u.audio.count : min(u.audio.count, HandsFree.wakeFrames)
        while u.sent < allowed {
            feed.push(u.audio[u.sent])
            u.sent += 1
        }
    }

    private func heard(_ partial: String, in u: Utterance) {
        guard case .wake(_, let transcription) = u.kind else { return }
        if !WakePhrase.mightStart(partial) {
            transcription.cancel()               // not for Glance: stop sending
            drop(u)
        } else if !u.confirmed && WakePhrase.confirms(partial) {
            u.confirmed = true
            send(u)                              // what was held back
            startSession()
            release()
        }
    }

    /// It ended: its transcript says whether it was "Hey Glance". What is said meanwhile waits on the Mac.
    private func check(_ u: Utterance, _ transcription: Transcription) {
        checking = u
        Task.detached {
            let text = await transcription.finish()
            self.queue.async { self.verdict(text, on: u) }
        }
    }

    private func verdict(_ text: String, on u: Utterance) {
        guard checking === u else { return }
        checking = nil
        let (woke, rest) = WakePhrase.split(text)
        if woke && running {
            startSession()
            if u.sent < u.audio.count - vad.endFrames {      // (the last 800 ms are the quiet that ended it)
                // Only its first 2 s went to be checked and words came after: all of it is a command, where you
                // pointed.
                startCommand(u)
            } else if !rest.isEmpty {
                // "Hey Glance, make this red" in one breath: the rest is a command for where you pointed.
                let at = u.at
                lastCommand = Date()
                Task.detached { await self.host.runTyped(rest, at: at) }
            }
        }
        if case .wake = u.kind { u.kind = .dropped }
        u.audio = []
        release()
    }

    /// What was said while "Hey Glance" was checked: commands if it woke Glance, else checked the same way in turn.
    private func release() {
        while !held.isEmpty, active || checking == nil {
            let u = held.removeFirst()
            if active {
                startCommand(u)
                continue
            }
            startWake(u)
            if u.ended, case .wake(_, let transcription) = u.kind { check(u, transcription) }
        }
    }

    /// A talk-key press made by voice, with all of the utterance so far; more follows while it goes on.
    private func startCommand(_ u: Utterance) {
        let feed = AudioFeed()
        for f in u.audio { feed.push(f) }
        u.audio = []
        u.kind = .command(feed)
        let at = u.at
        keys.async { self.host.keyDown(feed: feed, at: at) }
        if u.ended {
            expectWords()
            keys.async { self.host.keyUp() }
        }
    }

    /// A command was said to its end; its words are on their way (`commandDone` brings them).
    private func expectWords() {
        awaiting += 1
        awaitingSince = Date()
    }

    private func drop(_ u: Utterance) {
        u.kind = .dropped
        u.audio = []
        if checking === u {
            checking = nil
            release()
        }
    }

    /// Forgets everything half said or waiting (the talk key went down, or the session ended).
    private func dropAll() {
        for u in [current, checking].compactMap({ $0 }) + held {
            switch u.kind {
            case .wake(_, let transcription): transcription.cancel()
            case .command: if !u.ended { keys.async { self.host.cancelHeld() } }
            case .held, .dropped: break
            }
            u.kind = .dropped
            u.audio = []
        }
        current = nil
        checking = nil
        held = []
    }

    private func startSession() {
        guard !active else { return }
        active = true
        lastCommand = Date()
        awaiting = 0
        vad.longestFrames = 1500                 // 30 s: a long command is not cut in two
        presence.set(.session, true)
        onSessionChange?(true)
        print("\nHey! Hands-free: point at a window and talk. Esc or “thanks, Glance” ends it.")
        Glance.prompt()
    }

    /// Ends the session 10 s after its last command, but not while you talk, while a command's words are on their
    /// way, or while a question waits for yes or no.
    private func checkIdle() {
        guard active, current == nil, checking == nil, borrowed == nil, !host.isAsking else { return }
        if awaiting > 0 {
            guard Date().timeIntervalSince(awaitingSince) > 15 else { return }
            awaiting = 0                         // the words never came back (no window there, a voice error)
        }
        guard Date().timeIntervalSince(lastCommand) > idleSeconds else { return }
        endSession("\(Int(idleSeconds)) s without a command")
    }

    private func endSession(_ why: String?) {
        dropAll()
        vad.reset()
        preroll.removeAll()
        guard active else { return }
        active = false
        vad.longestFrames = VoiceActivity().longestFrames
        presence.set(.session, false)
        onSessionChange?(false)
        if let why = why {
            print("\nHands-free session ended (\(why)). Say “Hey Glance” to start again.")
            Glance.prompt()
        }
    }
}
