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

    @Test("A quiet room, a click and a short knock are not speech")
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

    @Test("Glance's own voice is not speech, but it can end speech")
    func ignoredFrames() {
        var vad = VoiceActivity()
        for _ in 0..<50 { #expect(vad.ignore() == nil) }
        #expect(!vad.speaking)
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
          arguments: ["Take a glance at the logs", "Hey, can you glance at this?", "Glancing at it now", "Hey there"])
    func notWakePhrase(said: String) {
        #expect(!WakePhrase.split(said).woke)
    }

    @Test("Glance stops sending as soon as the first two words can't be “Hey Glance”")
    func stopsEarly() {
        #expect(WakePhrase.mightStart(""))
        #expect(WakePhrase.mightStart("Hey"))
        #expect(WakePhrase.mightStart("Hey Glance, make"))
        #expect(!WakePhrase.mightStart("Can you"))
        #expect(!WakePhrase.mightStart("Hey can"))
    }

    @Test("“Thanks, Glance” and “stop listening” end a session; a command that starts like one does not")
    func goodbyes() {
        for said in ["Thanks, Glance.", "That's all.", "Stop listening", "thank you", "Bye Glance!"] {
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
}

/// Stands in for Glance: records the key presses hands-free makes, and answers "Hey Glance" transcriptions with
/// scripted words.
final class FakeHost: HandsFreeHost, @unchecked Sendable {
    final class Heard: Transcription, @unchecked Sendable {
        let text: String
        let host: FakeHost
        init(_ text: String, host: FakeHost) { self.text = text; self.host = host }
        func finish() async -> String { host.record("finish"); return text }
        func cancel() { host.record("stopped sending") }
    }

    private let lock = NSLock()
    private var said: [(text: String, partials: [String])]
    private var entries: [String] = []
    private var received: [Int] = []
    var speaking = false

    init(_ said: [(String, [String])] = []) {
        self.said = said.map { (text: $0.0, partials: $0.1) }
    }

    func record(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    /// Bytes of audio each key press got.
    var audio: [Int] { lock.lock(); defer { lock.unlock() }; return received }

    func keyDown(feed: AudioFeed?) {
        record("key down")
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
    func runTyped(_ command: String) async { record("command: \(command)") }
    var isSpeaking: Bool { lock.lock(); defer { lock.unlock() }; return speaking }

    func transcribe(_ feed: AudioFeed, onPartial: @escaping (String) -> Void) -> Transcription? {
        record("transcribing")
        lock.lock()
        let next = said.isEmpty ? (text: "", partials: []) : said.removeFirst()
        lock.unlock()
        feed.attach { _ in }
        for p in next.partials { onPartial(p) }
        return Heard(next.text, host: self)
    }
}

/// The hands-free session from "Hey Glance" to Esc, "thanks, Glance" or silence, with the clips as the microphone.
@Suite(.serialized) struct HandsFreeSessionTests {
    func quietPresence() -> Presence {
        let p = Presence()
        p.soundsOn = false
        return p
    }

    /// The clip in a quiet room, as the microphone brings it (80 ms chunks).
    func say(_ handsFree: HandsFree, _ clip: String, after: Double = 1.2) throws {
        let audio = Clip.room(seconds: 0.6) + (try Clip.pcm(clip)) + Clip.room(seconds: after)
        let chunk = 24_000 * 2 * 80 / 1000
        var offset = 0
        while offset < audio.count {
            handsFree.listen(audio.subdata(in: offset..<min(offset + chunk, audio.count)))
            offset += chunk
        }
        handsFree.settle()
    }

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
        let host = FakeHost([("Hey Glance,", ["Hey", "Hey Glance,"])])
        let presence = quietPresence()
        let handsFree = try await awake(host, presence)
        #expect(host.log == ["transcribing", "finish"])
        #expect(presence.listening)

        try say(handsFree, "hey-glance-command")
        #expect(host.log.suffix(2) == ["key down", "key up"])
        let words = try Clip.pcm("hey-glance-command").count
        #expect(host.audio.first ?? 0 >= words, "the command got \(host.audio) bytes; the words are \(words)")

        #expect(handsFree.filter("Hey Glance, make it red") == "make it red")
        #expect(handsFree.filter("make it red") == "make it red")
        #expect(handsFree.filter("Thanks, Glance.") == nil)
        #expect(await eventually { !handsFree.isActive })
        #expect(!presence.listening)
    }

    @Test("Talk that isn't for Glance stops sending at the second word, and nothing happens")
    func notForGlance() async throws {
        let host = FakeHost([("Can you take a look at the logs later?", ["Can", "Can you"])])
        let handsFree = HandsFree(host: host, presence: quietPresence())
        handsFree.startWithoutMic()
        try say(handsFree, "not-for-glance")
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(host.log == ["transcribing", "stopped sending"])
        #expect(!handsFree.isActive)
    }

    @Test("“Hey Glance, make this button green” in one breath starts a session and runs the command")
    func oneBreath() async throws {
        let host = FakeHost([("Hey glance make this button green.", [])])
        let handsFree = HandsFree(host: host, presence: quietPresence())
        handsFree.startWithoutMic()
        try say(handsFree, "hey-glance-command")
        #expect(await eventually { host.log.contains("command: make this button green.") }, "\(host.log)")
        #expect(handsFree.isActive)
    }

    @Test("Esc ends the session and drops what is half said")
    func escape() async throws {
        let host = FakeHost([("Hey Glance.", [])])
        let handsFree = try await awake(host, quietPresence())
        handsFree.listen(Clip.room(seconds: 0.6) + (try Clip.pcm("hey-glance-command")).prefix(48_000))   // 1 s of it
        handsFree.escape()
        handsFree.settle()
        #expect(host.log.suffix(2) == ["key down", "dropped"])
        #expect(!handsFree.isActive)
    }

    @Test("A session ends by itself after a while without speech")
    func idle() async throws {
        let host = FakeHost([("Hey Glance.", [])])
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

    @Test("While Glance reads a result aloud, it does not listen to itself")
    func deafWhileSpeaking() throws {
        let host = FakeHost([("Hey Glance.", [])])
        host.speaking = true
        let handsFree = HandsFree(host: host, presence: quietPresence())
        handsFree.startWithoutMic()
        try say(handsFree, "hey-glance")
        #expect(host.log.isEmpty)
    }
}
