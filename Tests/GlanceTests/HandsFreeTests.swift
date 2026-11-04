import Foundation
import Testing
@testable import Glance

/// Spoken clips voiced with Kokoro (am_michael) in Fixtures/, 24 kHz mono 16-bit like the microphone after
/// conversion, and a quiet room to put them in.
enum Clip {
    struct Missing: Error {}

    static func pcm(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "wav", subdirectory: "Fixtures") else { throw Missing() }
        let wav = try Data(contentsOf: url)
        guard let marker = wav.range(of: Data("data".utf8)) else { throw Missing() }
        return wav.subdata(in: (marker.upperBound + 4)..<wav.count)
    }

    static func seconds(_ audio: Data) -> Double { Double(audio.count) / 48_000 }

    /// Room noise, the same every run. Level 32 is about -60 dBFS, a quiet room; 260 is about -42, a loud fan.
    static func room(seconds: Double, level: Int16 = 32) -> Data {
        var state: UInt32 = 12345
        var samples = [Int16](repeating: 0, count: Int(seconds * 24_000))
        let spread = Int32(level) * 7 / 4          // uniform noise: RMS = spread / √3
        for i in samples.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            samples[i] = Int16(Int32(state >> 16) % (2 * spread + 1) - spread)
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Two sounds at once.
    static func mix(_ a: Data, _ b: Data) -> Data {
        let x = a.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let y = b.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let sum = (0..<min(x.count, y.count)).map { Int16(clamping: Int32(x[$0]) + Int32(y[$0])) }
        return sum.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// When speech started and ended, in seconds from the start.
    static func events(_ audio: Data) -> [(VoiceActivity.Event, Double)] {
        var vad = VoiceActivity()
        var out: [(VoiceActivity.Event, Double)] = []
        var offset = 0
        var frame = 0
        while offset + VoiceActivity.frameBytes <= audio.count {
            if let e = vad.process(audio.subdata(in: offset..<(offset + VoiceActivity.frameBytes))) {
                out.append((e, Double(frame) * VoiceActivity.frameSeconds))
            }
            offset += VoiceActivity.frameBytes
            frame += 1
        }
        return out
    }
}

@Suite struct HandsFreeTests {
    @Test("Speech in a quiet room is found from its start to just after its end",
          arguments: ["hey-glance", "hey-glance-command", "not-for-glance", "thanks-glance"])
    func findsSpeech(clip: String) throws {
        let speech = try Clip.pcm(clip)
        let audio = Clip.room(seconds: 1) + speech + Clip.room(seconds: 1.5)
        let events = Clip.events(audio)
        #expect(events.map(\.0) == [.started, .ended], "\(events)")    // one utterance: a comma does not split it
        guard events.count == 2 else { return }
        #expect(events[0].1 >= 1.0 && events[0].1 <= 1.4, "started at \(events[0].1) s")
        let end = 1 + Clip.seconds(speech)
        #expect(events[1].1 >= end + 0.4 && events[1].1 <= end + 1.0, "ended at \(events[1].1) s, speech ends at \(end) s")
    }

    @Test("A quiet room and a 40 ms click are not speech")
    func ignoresNoise() {
        #expect(Clip.events(Clip.room(seconds: 5)).isEmpty)
        let click = Data(repeating: 0x40, count: VoiceActivity.frameBytes * 2)    // 40 ms
        #expect(Clip.events(Clip.room(seconds: 1) + click + Clip.room(seconds: 1)).isEmpty)
    }

    @Test("A fan that comes on is taken for the room after 15 s, and speech is still found after that")
    func learnsALouderRoom() throws {
        let fan = Clip.room(seconds: 20, level: 260)
        let speech = try Clip.pcm("hey-glance")
        let louder = speech.withUnsafeBytes { raw in
            Data(raw.bindMemory(to: Int16.self).map { Int16(clamping: Int32($0) * 2) }.withUnsafeBufferPointer { Data(buffer: $0) })
        }
        // The fan keeps running under the speech, as it would in the room.
        let underFan = Clip.mix(louder, Clip.room(seconds: Clip.seconds(louder), level: 260))
        let events = Clip.events(Clip.room(seconds: 1) + fan + underFan + Clip.room(seconds: 1.5, level: 260))
        #expect(events.map(\.0) == [.started, .ended, .started, .ended], "\(events)")
        if events.count == 4 {
            #expect(events[1].1 > 15 && events[1].1 < 17, "gave up on the fan at \(events[1].1) s")
            #expect(events[2].1 > 20.9 && events[2].1 < 21.5, "speech found at \(events[2].1) s")
        }
    }

    @Test("Glance's own voice or sound neither starts speech nor cuts it off")
    func ignoredFrames() {
        var vad = VoiceActivity()
        for _ in 0..<50 { vad.ignore() }
        #expect(!vad.speaking)
        for _ in 0..<3 { _ = vad.process(level: -20) }
        #expect(vad.speaking)
        for _ in 0..<60 { vad.ignore() }          // the 0.77 s sound and more, while you talk
        #expect(vad.speaking)
        var events: [VoiceActivity.Event] = []
        for _ in 0..<40 { if let e = vad.process(level: -70) { events.append(e) } }
        #expect(events == [.ended])
    }

    @Test("“Hey Glance” is found however speech to text writes it, and the rest is the command",
          arguments: [("Hey Glance.", ""), ("Hey, Glance, make this button green.", "make this button green."),
                      ("hi glance what's failing", "what's failing"), ("Hey Glans", ""), ("OK Glance: pause", "pause")])
    func wakePhrase(said: String, rest: String) {
        let found = WakePhrase.split(said)
        #expect(found.woke)
        #expect(found.rest == rest)
    }

    @Test("Talk that only mentions a glance does not wake Glance",
          arguments: ["Take a glance at the logs", "Hey, can you glance at this?", "Glancing at it now", "Hey there",
                      "Hey, glance at this", "A glance at the logs would help", "Hey glance over the PR for me"])
    func notWakePhrase(said: String) {
        #expect(!WakePhrase.split(said).woke)
    }

    @Test("Glance stops sending as soon as the first words can't be “Hey Glance”, and is sure once a command follows")
    func stopsEarly() {
        #expect(WakePhrase.mightStart(""))
        #expect(WakePhrase.mightStart("Hey"))
        #expect(WakePhrase.mightStart("Hey Glance, make"))
        #expect(!WakePhrase.mightStart("Can you"))
        #expect(!WakePhrase.mightStart("Hey can"))
        #expect(!WakePhrase.mightStart("Hey, glance at"))
        #expect(WakePhrase.confirms("Hey Glance, make"))
        #expect(!WakePhrase.confirms("Hey Glance"))           // could still be "Hey, glance at this"
        #expect(!WakePhrase.confirms("Hey glance at"))
    }

    @Test("“Thanks, Glance” and “stop listening” end a session; a command that starts like one does not")
    func goodbyes() {
        for said in ["Thanks, Glance.", "That's all.", "Stop listening", "thank you", "Bye Glance!", "Thanks, Lance.",
                     "OK thanks Glance", "Great, thank you Glance!", "Glance, go to sleep"] {
            #expect(WakePhrase.isGoodbye(said), "\(said)")
        }
        for said in ["Stop the server", "Thanks Glance, now make it red", "that's all the tests?"] {
            #expect(!WakePhrase.isGoodbye(said), "\(said)")
        }
    }

    @Test("Audio pushed before a session attaches is kept, in order")
    func feedKeepsEarlyAudio() {
        let feed = AudioFeed()
        feed.push(Data([1]))
        feed.push(Data([2]))
        var got: [UInt8] = []
        feed.attach { got.append(contentsOf: $0) }
        feed.push(Data([3]))
        feed.detach()
        feed.push(Data([4]))
        #expect(got == [1, 2, 3])
    }

    @Test("Audio pushed while a session attaches still arrives in order")
    func feedKeepsOrder() async {
        let feed = AudioFeed()
        let pusher = Thread {
            for i in 0..<20_000 { feed.push(withUnsafeBytes(of: UInt32(i)) { Data($0) }) }
        }
        pusher.start()
        while !pusher.isExecuting && !pusher.isFinished { usleep(100) }
        usleep(2_000)
        let got = Got()
        feed.attach { got.add($0) }
        while !pusher.isFinished { usleep(1_000) }
        let values = got.values
        #expect(!values.isEmpty)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 + 1 == $1 }, "out of order")
    }

    final class Got: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [UInt32] = []
        func add(_ d: Data) { lock.lock(); list.append(d.withUnsafeBytes { $0.load(as: UInt32.self) }); lock.unlock() }
        var values: [UInt32] { lock.lock(); defer { lock.unlock() }; return list }
    }

    @Test("Hands-free answers a question only with a clear yes or no; the talk key's answers stay easy",
          arguments: [("yes", true), ("Yes, go ahead.", true), ("No, don't.", false), ("Go ahead and do it", true),
                      ("Cancel", false), ("Sure, let's go to lunch.", nil), ("OK", nil), ("Sure", nil),
                      ("Hmm, that's not right", nil)] as [(String, Bool?)])
    func answers(said: String, handsFree: Bool?) {
        #expect(Glance.answer(said, strict: true) == handsFree)
        if handsFree != nil { #expect(Glance.answer(said, strict: false) == handsFree) }
    }

    @Test("With the talk key, “sure” and “ok” still answer yes")
    func keyAnswers() {
        #expect(Glance.answer("Sure", strict: false) == true)
        #expect(Glance.answer("OK", strict: false) == true)
    }
}

/// Live: do Muse Voice Transcribe and the wake rules hear the clips the way a person meant them? Off by default:
///     GLANCE_LIVE_EVAL=1 swift test --filter HandsFreeLiveEvals
@Suite(.enabled(if: ProcessInfo.processInfo.environment["GLANCE_LIVE_EVAL"] == "1"), .serialized)
struct HandsFreeLiveEvals {
    final class Partials: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.lock(); list.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return list }
    }

    /// Streams a clip through a real voice session at real speed, as the hands-free listener does.
    func hear(_ clip: String) async throws -> (text: String, partials: [String]) {
        let key = try #require(GlanceMain.museKey(), "No Muse key: set MUSE_API_KEY")
        let session = VoiceSession(key: key)
        let partials = Partials()
        session.onPartial = { partials.add($0) }
        session.open()
        let feed = AudioFeed()
        try session.startTalking(feed: feed)
        let audio = Clip.room(seconds: 0.3) + (try Clip.pcm(clip)) + Clip.room(seconds: 0.6)
        let chunk = 24_000 * 2 * 80 / 1000
        var offset = 0
        while offset < audio.count {
            feed.push(audio.subdata(in: offset..<min(offset + chunk, audio.count)))
            offset += chunk
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        let text = try await session.stopTalking()
        print("  \(clip): \"\(text)\"  partials: \(partials.all)")
        return (text, partials.all)
    }

    @Test("“Hey Glance.” wakes Glance, with nothing else to do")
    func wake() async throws {
        let (text, _) = try await hear("hey-glance")
        let found = WakePhrase.split(text)
        #expect(found.woke, "heard \"\(text)\"")
        #expect(found.rest.isEmpty, "heard \"\(text)\"")
    }

    @Test("“Hey Glance, make this button green.” wakes Glance and keeps the command")
    func wakeWithCommand() async throws {
        let (text, _) = try await hear("hey-glance-command")
        let found = WakePhrase.split(text)
        #expect(found.woke, "heard \"\(text)\"")
        #expect(found.rest.lowercased().contains("green"), "heard \"\(text)\"")
    }

    @Test("Talk that is not for Glance is dropped, and sending stops early")
    func notForGlance() async throws {
        let (text, partials) = try await hear("not-for-glance")
        #expect(!WakePhrase.split(text).woke, "heard \"\(text)\"")
        #expect(partials.contains { !WakePhrase.mightStart($0) }, "partials \(partials)")
    }

    @Test("“Thanks, Glance.” ends a session")
    func goodbye() async throws {
        let (text, _) = try await hear("thanks-glance")
        #expect(WakePhrase.isGoodbye(text), "heard \"\(text)\"")
    }

    @Test("Speech handed over all at once (said while “Hey Glance” was checked) goes out at the service's pace")
    func handedOverAtOnce() async throws {
        let key = try #require(GlanceMain.museKey(), "No Muse key: set MUSE_API_KEY")
        let session = VoiceSession(key: key)
        session.open()
        let feed = AudioFeed()
        let audio = Clip.room(seconds: 0.3) + (try Clip.pcm("hey-glance-command")) + Clip.room(seconds: 0.5)
            + (try Clip.pcm("not-for-glance")) + Clip.room(seconds: 0.5) + (try Clip.pcm("hey-glance-command"))
        var offset = 0                            // 7 s at once, more than the service takes ahead of time
        while offset < audio.count {
            feed.push(audio.subdata(in: offset..<min(offset + VoiceActivity.frameBytes, audio.count)))
            offset += VoiceActivity.frameBytes
        }
        try session.startTalking(feed: feed)
        let text = try await session.stopTalking(timeout: 20)
        print("  handed over at once (\(String(format: "%.1f", Clip.seconds(audio))) s): \"\(text)\"")
        let lower = text.lowercased()
        #expect(lower.contains("logs") && lower.components(separatedBy: "green").count == 3, "heard \"\(text)\"")
    }
}

/// Stands in for Glance: records the key presses hands-free makes, and answers "Hey Glance" checks with scripted
/// words, which come in as the audio arrives, as Muse's do.
final class FakeHost: HandsFreeHost, @unchecked Sendable {
    /// What one "Hey Glance" check hears: its transcript, the words it has after so many seconds of audio, and how
    /// long the transcript takes once the speech ended.
    struct Said {
        var text: String
        var partials: [(after: Double, words: String)] = []
        var delay = 0.0
    }

    final class Heard: Transcription, @unchecked Sendable {
        let said: Said
        let host: FakeHost
        init(_ said: Said, host: FakeHost) { self.said = said; self.host = host }
        func finish() async -> String {
            host.record("finish")
            if said.delay > 0 { try? await Task.sleep(nanoseconds: UInt64(said.delay * 1e9)) }
            return said.text
        }
        func cancel() { host.record("stopped sending") }
    }

    private let lock = NSLock()
    private var said: [Said]
    private var entries: [String] = []
    private var received: [Int] = []
    private var checks: [Int] = []
    private var pointed: [String] = []
    private var looks = 0
    var speaking = false

    init(_ said: [Said] = []) {
        self.said = said
    }

    func record(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    /// Bytes of audio each key press got.
    var audio: [Int] { lock.lock(); defer { lock.unlock() }; return received }
    /// Bytes of audio each "Hey Glance" check got.
    var checked: [Int] { lock.lock(); defer { lock.unlock() }; return checks }
    /// Where each command went: "look 1" is what was under the pointer the first time hands-free looked.
    var targets: [String] { lock.lock(); defer { lock.unlock() }; return pointed }

    func attention() -> Attention {
        lock.lock()
        looks += 1
        let n = looks
        lock.unlock()
        return Attention(window: TargetWindow(windowID: 0, pid: 0, appName: "Test", bundleID: "test", title: "look \(n)",
                                              bounds: .zero))
    }

    func went(to at: Attention?) {
        lock.lock()
        if let title = at?.window?.title { pointed.append(title) }
        lock.unlock()
    }

    func keyDown(feed: AudioFeed?, at: Attention?) {
        record("key down")
        went(to: at)
        guard let feed = feed else { return }
        lock.lock()
        let i = received.count
        received.append(0)
        lock.unlock()
        feed.attach { [weak self] data in
            guard let self = self else { return }
            self.lock.lock(); self.received[i] += data.count; self.lock.unlock()
        }
    }

    func keyUp() { record("key up") }
    func cancelHeld() { record("dropped") }

    func runTyped(_ command: String, at: Attention?) async {
        went(to: at)
        record("command: \(command)")
    }

    var isSpeaking: Bool { lock.lock(); defer { lock.unlock() }; return speaking }

    func transcribe(_ feed: AudioFeed, onPartial: @escaping (String) -> Void) -> Transcription? {
        record("transcribing")
        lock.lock()
        let next = said.isEmpty ? Said(text: "") : said.removeFirst()
        let i = checks.count
        checks.append(0)
        lock.unlock()
        var partials = next.partials[...]
        feed.attach { [weak self] data in
            guard let self = self else { return }
            self.lock.lock()
            self.checks[i] += data.count
            let bytes = self.checks[i]
            self.lock.unlock()
            while let p = partials.first, Double(bytes) >= p.after * 48_000 {
                partials.removeFirst()
                onPartial(p.words)
            }
        }
        return Heard(next, host: self)
    }
}

/// The hands-free session from "Hey Glance" to Esc, "thanks, Glance" or silence, with the clips as the microphone.
@Suite(.serialized) struct HandsFreeSessionTests {
    typealias Said = FakeHost.Said

    func quietPresence() -> Presence {
        let p = Presence()
        p.soundsOn = false
        return p
    }

    /// The clip in a quiet room, as the microphone brings it (80 ms chunks).
    func say(_ handsFree: HandsFree, _ clip: String, after: Double = 1.2) throws {
        play(handsFree, Clip.room(seconds: 0.6) + (try Clip.pcm(clip)) + Clip.room(seconds: after))
    }

    func play(_ handsFree: HandsFree, _ audio: Data) {
        let chunk = 24_000 * 2 * 80 / 1000
        var offset = 0
        while offset < audio.count {
            handsFree.listen(audio.subdata(in: offset..<min(offset + chunk, audio.count)))
            offset += chunk
        }
        handsFree.settle()
    }

    /// A cough or a door: 150 ms of loud noise.
    var cough: Data { Clip.room(seconds: 0.6) + Clip.room(seconds: 0.15, level: 3000) + Clip.room(seconds: 1.2) }

    func eventually(_ seconds: Double = 2, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    func awake(_ host: FakeHost, _ presence: Presence) async throws -> HandsFree {
        let handsFree = HandsFree(host: host, presence: presence)
        handsFree.startWithoutMic()
        try say(handsFree, "hey-glance")
        #expect(await eventually { handsFree.isActive }, "\(host.log)")
        return handsFree
    }

    @Test("“Hey Glance” starts a session; then each thing said is a talk-key press with its audio; “thanks” ends it")
    func fullSession() async throws {
        let host = FakeHost([Said(text: "Hey Glance,", partials: [(0.6, "Hey"), (1.0, "Hey Glance,")])])
        let presence = quietPresence()
        let handsFree = try await awake(host, presence)
        #expect(host.log == ["transcribing", "finish"])
        #expect(presence.listening)

        #expect(presence.commandsHeard == 0)
        try say(handsFree, "hey-glance-command")
        #expect(host.log.suffix(2) == ["key down", "key up"])
        #expect(presence.commandsHeard == 1)            // the pop: point at the next window
        let words = try Clip.pcm("hey-glance-command").count
        #expect(host.audio.first ?? 0 >= words, "the command got \(host.audio) bytes; the words are \(words)")
        #expect(host.targets == ["look 2"])

        #expect(handsFree.filter("Hey Glance, make it red") == "make it red")
        #expect(handsFree.filter("make it red") == "make it red")
        #expect(handsFree.filter("Thanks, Glance.") == nil)
        #expect(await eventually { !handsFree.isActive })
        #expect(!presence.listening)
    }

    @Test("Talk that isn't for Glance stops sending at the second word, and nothing happens")
    func notForGlance() async throws {
        let host = FakeHost([Said(text: "Can you take a look at the logs later?", partials: [(0.6, "Can"), (0.9, "Can you")])])
        let handsFree = HandsFree(host: host, presence: quietPresence())
        handsFree.startWithoutMic()
        try say(handsFree, "not-for-glance")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(host.log == ["transcribing", "stopped sending"])
        #expect(Double(host.checked.first ?? 0) / 48_000 < 1.1, "sent \(host.checked) bytes")
        #expect(!handsFree.isActive)
    }

    @Test("With no words back yet (the connection still opening), at most 2 s of what is said is sent")
    func sendsTwoSecondsAtMost() async throws {
        let host = FakeHost([Said(text: "Can you take a look at the logs later? Can you")])
        let handsFree = HandsFree(host: host, presence: quietPresence())
        handsFree.startWithoutMic()
        let talk = try Clip.pcm("not-for-glance")
        play(handsFree, Clip.room(seconds: 0.6) + talk + Clip.room(seconds: 0.3) + talk + Clip.room(seconds: 1.2))
        #expect(await eventually { host.log == ["transcribing", "finish"] }, "\(host.log)")
        #expect(host.checked == [HandsFree.wakeFrames * VoiceActivity.frameBytes], "sent \(host.checked) bytes of 4.5 s")
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(!handsFree.isActive)
        #expect(host.audio.isEmpty)
    }

    @Test("“Hey Glance, make this button green” in one breath starts the session as the command begins, and runs it")
    func oneBreath() async throws {
        let host = FakeHost([Said(text: "Hey glance make this button green.", partials: [(0.9, "Hey glance make")])])
        let presence = quietPresence()
        let handsFree = HandsFree(host: host, presence: presence)
        handsFree.startWithoutMic()
        try say(handsFree, "hey-glance-command")
        #expect(presence.commandsHeard == 1)
        #expect(await eventually { host.log.contains("command: make this button green.") }, "\(host.log)")
        #expect(handsFree.isActive)
        #expect(host.checked.first ?? 0 >= (try Clip.pcm("hey-glance-command")).count, "sent \(host.checked)")
        #expect(host.targets == ["look 1"])
    }

    @Test("In one breath while the connection opens: only 2 s are checked, then all of it goes as a command")
    func oneBreathWhileConnecting() async throws {
        let host = FakeHost([Said(text: "Hey glance, make this")])
        let handsFree = HandsFree(host: host, presence: quietPresence())
        handsFree.startWithoutMic()
        try say(handsFree, "hey-glance-command")
        #expect(await eventually { host.log.suffix(2) == ["key down", "key up"] }, "\(host.log)")
        #expect(host.checked == [HandsFree.wakeFrames * VoiceActivity.frameBytes])
        #expect(host.audio.first ?? 0 >= (try Clip.pcm("hey-glance-command")).count, "the command got \(host.audio)")
        #expect(host.targets == ["look 1"])
        #expect(!host.log.contains { $0.hasPrefix("command:") })
        #expect(handsFree.isActive)
    }

    @Test("A command said after “Hey Glance” and a pause, before its transcript is back, waits and then runs")
    func pauseAfterWake() async throws {
        let host = FakeHost([Said(text: "Hey Glance.", delay: 0.5)])
        let handsFree = HandsFree(host: host, presence: quietPresence())
        handsFree.startWithoutMic()
        try say(handsFree, "hey-glance", after: 1.0)
        try say(handsFree, "not-for-glance")      // the command, said at once
        #expect(host.log == ["transcribing", "finish"])         // kept on the Mac meanwhile
        #expect(await eventually { host.log.suffix(2) == ["key down", "key up"] }, "\(host.log)")
        #expect(host.audio.first ?? 0 >= (try Clip.pcm("not-for-glance")).count, "the command got \(host.audio)")
        #expect(host.targets == ["look 2"])        // where you pointed as you said it
        #expect(handsFree.isActive)
    }

    @Test("Speech kept while other talk was checked gets its own “Hey Glance” check when that talk wasn't for Glance")
    func wakeAfterOtherTalk() async throws {
        let host = FakeHost([Said(text: "Can you take a look at the logs later?", delay: 0.5), Said(text: "Hey Glance.")])
        let handsFree = HandsFree(host: host, presence: quietPresence())
        handsFree.startWithoutMic()
        try say(handsFree, "not-for-glance", after: 1.0)
        try say(handsFree, "hey-glance")
        #expect(host.log == ["transcribing", "finish"])
        #expect(await eventually { handsFree.isActive }, "\(host.log)")
        #expect(host.log == ["transcribing", "finish", "transcribing", "finish"])
        #expect(host.audio.isEmpty)
    }

    @Test("A cough is not transcribed while Glance waits, and is no command in a session")
    func coughs() async throws {
        let host = FakeHost([Said(text: ""), Said(text: "Hey Glance.")])    // the cough's check is never finished
        let presence = quietPresence()
        let handsFree = HandsFree(host: host, presence: presence)
        handsFree.startWithoutMic()
        play(handsFree, cough)
        #expect(host.log == ["transcribing", "stopped sending"])
        try say(handsFree, "hey-glance")
        #expect(await eventually { handsFree.isActive }, "\(host.log)")
        play(handsFree, cough)
        #expect(host.log.suffix(2) == ["key down", "dropped"])
        #expect(presence.commandsHeard == 0)            // no pop for a cough
    }

    @Test("Esc ends the session and drops what is half said")
    func escape() async throws {
        let host = FakeHost([Said(text: "Hey Glance.")])
        let handsFree = try await awake(host, quietPresence())
        handsFree.listen(Clip.room(seconds: 0.6) + (try Clip.pcm("hey-glance-command")).prefix(48_000))   // 1 s of it
        handsFree.escape()
        handsFree.settle()
        #expect(host.log.suffix(2) == ["key down", "dropped"])
        #expect(!handsFree.isActive)
    }

    @Test("A session ends by itself after a while without speech")
    func idle() async throws {
        let host = FakeHost([Said(text: "Hey Glance.")])
        let handsFree = try await awake(host, quietPresence())
        handsFree.idleTimeout = 0.3
        #expect(await eventually { !handsFree.isActive })
    }

    @Test("The talk key takes the microphone: its audio goes to the key's command, not to the listener")
    func talkKey() throws {
        let host = FakeHost()
        let handsFree = HandsFree(host: host, presence: quietPresence())
        #expect(!handsFree.keyDown())          // not listening: the key works as before, with its own microphone
        handsFree.startWithoutMic()
        #expect(handsFree.keyDown())
        let words = try Clip.pcm("hey-glance")
        handsFree.listen(words)
        #expect(handsFree.keyUp())
        handsFree.settle()
        #expect(host.log == ["key down", "key up"])
        #expect(host.audio == [words.count])
    }

    @Test("With hands-free off, the talk key's words pass unchanged")
    func filterWhenOff() {
        let handsFree = HandsFree(host: FakeHost(), presence: quietPresence())
        #expect(handsFree.filter("Hey Glance, make it red") == "Hey Glance, make it red")
        #expect(handsFree.filter("Thanks, Glance.") == "Thanks, Glance.")
    }

    @Test("While Glance reads a result aloud, it does not listen to itself")
    func deafWhileSpeaking() throws {
        let host = FakeHost([Said(text: "Hey Glance.")])
        host.speaking = true
        let handsFree = HandsFree(host: host, presence: quietPresence())
        handsFree.startWithoutMic()
        try say(handsFree, "hey-glance")
        #expect(host.log.isEmpty)
    }
}
