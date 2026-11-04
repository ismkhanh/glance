import AppKit
import Foundation

/// Glance as a menu-bar app, started from a terminal (which keeps showing the log and takes typed commands).
///
///   the glow follows the window and element under the pointer (mouse, or your head with Head pointer)
///   hold the talk key (Left Option) anywhere → speak → let go
///   Muse asks before risky actions → hold the key and say yes or no (or type y here)
///   Figma: each command becomes a task for the Glance brain; tasks run in parallel, and the mascot lists them
@main
struct GlanceMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    /// MUSE_API_KEY (or MODEL_API_KEY) from the environment, else from .env in the Glance folder (where `swift run`
    /// starts, like ./brain). The brain reads the same file.
    static func museKey(environment env: [String: String] = ProcessInfo.processInfo.environment,
                        envFile: String = FileManager.default.currentDirectoryPath + "/.env") -> String? {
        if let k = env["MUSE_API_KEY"], !k.isEmpty { return k }
        if let k = env["MODEL_API_KEY"], !k.isEmpty { return k }
        guard let text = try? String(contentsOfFile: envFile, encoding: .utf8) else { return nil }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard line.hasPrefix("MUSE_API_KEY=") else { continue }
            let value = line.dropFirst("MUSE_API_KEY=".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if !value.isEmpty { return value }
        }
        return nil
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var glance: Glance?
    private var highlighter: Highlighter?
    private var talkKey: TalkKey?
    private var statusItem: NSStatusItem?
    private var brain: BrainLink?
    private var tasksUI: TasksUI?
    private var speechItem: NSMenuItem?
    private var gaze: GazeInput?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Glance: talk to the window under your pointer.")
        guard let key = GlanceMain.museKey() else {
            print("No MUSE_API_KEY found in the environment or in .env (run Glance from its folder; see .env.example).")
            NSApp.terminate(nil)
            return
        }
        if !AX.isTrusted(prompt: true) {
            print("Note: allow your terminal app in System Settings > Privacy & Security > Accessibility, then run again.")
        }
        let highlighter = Highlighter()
        highlighter.start()
        self.highlighter = highlighter
        setUpMenu()

        // The brain (orchestrator + parallel workers + reviewer) for Figma, and its tooltips, toasts and mascot.
        let brain = BrainLink()
        let tasksUI = TasksUI()
        self.brain = brain
        self.tasksUI = tasksUI
        brain.onMessage = { [weak self] msg in
            self?.tasksUI?.handle(msg)
            if (msg["type"] as? String) == "ack", let text = msg["text"] as? String {
                print("\n  → \(text)")
                Glance.prompt()
            }
        }
        brain.onConnection = { [weak self] up in
            self?.tasksUI?.brainConnection(up)
            print(up ? "\n(Glance brain connected)" : "\n(Glance brain disconnected; trying again)")
            Glance.prompt()
        }
        tasksUI.start(send: { [weak brain] msg in brain?.send(msg) })
        brain.start()

        Task {
            let micAllowed = await MicCapture.requestAccess()
            self.finishStart(key: key, micAllowed: micAllowed, highlighter: highlighter)
        }
    }

    private func finishStart(key: String, micAllowed: Bool, highlighter: Highlighter) {
        if !micAllowed {
            print("Microphone is off for your terminal app (Privacy & Security > Microphone). Typed commands still work.")
        }
        let glance = Glance(key: key, micAllowed: micAllowed,
                            speak: CommandLine.arguments.contains("--say"), ui: highlighter,
                            brain: brain, tips: tasksUI?.tips)
        self.glance = glance
        tasksUI?.speak = { [weak glance] text in glance?.announce(text) }
        glance.tasks.onChange = { [weak self] tasks in self?.tasksUI?.updateLocal(tasks) }
        SpeechSwitch.shared.onChange = { [weak self] on in
            self?.speechItem?.state = on ? .on : .off
            self?.tasksUI?.speechChanged(on)
        }
        speechItem?.state = SpeechSwitch.shared.on ? .on : .off
        tasksUI?.speechChanged(SpeechSwitch.shared.on)

        if let port = GazeInput.portFromArguments() {
            let g = GazeInput()
            g.start(port: port)
            gaze = g
        }

        let choice = TalkKeyChoice.fromArguments()
        let talkKey = TalkKey(choice)
        self.talkKey = talkKey
        var keyWorks = false
        if micAllowed {
            keyWorks = talkKey.start(onDown: { glance.keyDown() }, onUp: { glance.keyUp() })
        }
        if keyWorks {
            print("Hold \(choice.label) from any app, speak, and let go. Other keys: --talk-key right-option | right-command | right-control | fn")
        } else if micAllowed {
            print("Could not watch the \(choice.label) key: allow your terminal app in Privacy & Security > Input Monitoring, then reopen it.")
        }
        print("""
        The blue glow shows the window and element under your pointer; "this" in a command means that element.
        Figma: open Plugins > Development > Glance Bridge once per file. Then point at a layer and talk; commands
        run in parallel. Questions appear where you pointed. Click the mascot (bottom right) for the task list.
        You can also type a command here and press Enter. Type quit to stop. Menu bar: ◉ Glance.
        """)
        Glance.prompt()

        // Typed commands and typed yes/no answers come from the terminal on their own thread.
        let reader = Thread {
            while let line = readLine() {
                let typed = line.trimmingCharacters(in: .whitespaces)
                if glance.answerPending(typed) { continue }
                if typed.lowercased() == "quit" {
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                    return
                }
                if typed.isEmpty {
                    Glance.prompt()
                    continue
                }
                Task.detached { await glance.runTyped(typed) }
            }
        }
        reader.start()
    }

    private func setUpMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "◉ Glance"
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Highlight what I point at", action: #selector(toggleHighlight(_:)), keyEquivalent: "")
        toggle.target = self
        toggle.state = .on
        menu.addItem(toggle)
        let speech = NSMenuItem(title: "Read results aloud", action: #selector(toggleSpeech(_:)), keyEquivalent: "")
        speech.target = self
        menu.addItem(speech)
        speechItem = speech
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Glance", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    @objc private func toggleHighlight(_ sender: NSMenuItem) {
        guard let h = highlighter else { return }
        h.enabled.toggle()
        sender.state = h.enabled ? .on : .off
    }

    @objc private func toggleSpeech(_ sender: NSMenuItem) {
        SpeechSwitch.shared.on.toggle()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        glance?.shutDown()
        brain?.stop()
    }
}

/// A Figma command on its way to the brain: the id ties the pointing (key down) to the words (key up).
struct BrainCommand {
    let id: String
    let answerTo: String?
}

/// A yes/no question asked before a risky action, for one task in one window.
final class PendingAnswer {
    let semaphore = DispatchSemaphore(value: 0)
    var yes = false
    let taskId: String
    let frame: CGRect

    init(taskId: String, frame: CGRect) {
        self.taskId = taskId
        self.frame = frame
    }
}

/// Whether finished tasks and questions are read aloud. `--say` turns it on; the menu and the task list switch it.
final class SpeechSwitch: @unchecked Sendable {
    static let shared = SpeechSwitch()
    var onChange: ((Bool) -> Void)?
    private let lock = NSLock()
    private var value = false

    var on: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
            DispatchQueue.main.async { self.onChange?(newValue) }
        }
    }
}

/// Commands for windows other than Figma, as tasks: they run side by side and show in the mascot's list
/// next to the brain's Figma tasks (same fields, plus "local").
final class LocalTasks: @unchecked Sendable {
    var onChange: (([[String: Any]]) -> Void)?
    private let lock = NSLock()
    private var tasks: [String: [String: Any]] = [:]

    func add(_ id: String, title: String, window: TargetWindow) {
        let name = window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title.prefix(32))"
        let now = Date().timeIntervalSince1970 * 1000
        update {
            $0[id] = ["id": id, "title": title, "status": "running", "detail": "Working…", "local": true,
                      "target": ["name": name], "createdAt": now, "updatedAt": now]
        }
    }

    func set(_ id: String, _ status: String, detail: String) {
        update {
            $0[id]?["status"] = status
            $0[id]?["detail"] = detail
            $0[id]?["updatedAt"] = Date().timeIntervalSince1970 * 1000
        }
    }

    private func update(_ change: (inout [String: [String: Any]]) -> Void) {
        lock.lock()
        change(&tasks)
        let views = tasks.values.sorted { ($0["createdAt"] as? Double ?? 0) > ($1["createdAt"] as? Double ?? 0) }
        lock.unlock()
        DispatchQueue.main.async { self.onChange?(views) }
    }
}

/// Runs commands: talk key → Muse Voice → Muse Spark → action. Each command is a task of its own, so you can
/// point at the next window and talk while the last one still works. Background threads; UI on the main thread.
final class Glance: @unchecked Sendable {
    let tasks = LocalTasks()
    private let key: String
    private let agent: Agent
    private let micAllowed: Bool
    private weak var ui: Highlighter?
    private let cards = TaskCards()             // used on the main thread only
    private let lock = NSLock()
    private let askGate = DispatchSemaphore(value: 1)     // one yes/no question on screen at a time
    private let speech = DispatchQueue(label: "glance.speech")
    private var keyHeld = false
    private var spare: VoiceSession?
    private var keySession: VoiceSession?
    private var keyTarget: TargetWindow?
    private var keyElement: PointedElement?
    private var keyNearby: [PointedElement] = []
    private var keyAnswering = false
    private var keyDownAt = Date()
    private var pending: PendingAnswer?
    private var speaker: Process?
    private let brain: BrainLink?
    private let tips: QuestionTips?
    private var keyBrain: BrainCommand?

    init(key: String, micAllowed: Bool, speak: Bool, ui: Highlighter, brain: BrainLink?, tips: QuestionTips?) {
        self.key = key
        self.agent = Agent(muse: MuseClient(key: key))
        self.micAllowed = micAllowed
        SpeechSwitch.shared.on = speak
        self.ui = ui
        self.brain = brain
        self.tips = tips
        if micAllowed {
            let s = VoiceSession(key: key)
            s.open()
            spare = s
        }
    }

    static func prompt() {
        print("\n> ", terminator: "")
        fflush(stdout)
    }

    private func onMain(_ work: @escaping (Highlighter) -> Void) {
        DispatchQueue.main.async { [weak self] in
            if let ui = self?.ui { work(ui) }
        }
    }

    // MARK: - Voice sessions

    /// Hands out the waiting voice session (or a new one if it closed) and opens the next one right away.
    private func takeVoice() -> VoiceSession {
        lock.lock()
        defer { lock.unlock() }
        var session = spare
        if let s = session, !s.isAlive || Date().timeIntervalSince(s.openedAt) > 30 * 60 {
            s.close()
            session = nil
        }
        if session == nil {
            let s = VoiceSession(key: key)
            s.open()
            session = s
        }
        let next = VoiceSession(key: key)
        next.open()
        spare = next
        return session!
    }

    private var pendingAnswer: PendingAnswer? {
        lock.lock()
        defer { lock.unlock() }
        return pending
    }

    private var isAsking: Bool { pendingAnswer != nil }

    private func card(_ id: String, _ text: String, near frame: CGRect, hideAfter seconds: Double? = nil) {
        DispatchQueue.main.async { self.cards.show(id, text, near: frame, hideAfter: seconds) }
    }

    private static func newTaskId() -> String {
        "w" + UUID().uuidString.prefix(8).lowercased()
    }

    // MARK: - Talk key (runs on the key's queue)

    func keyDown() {
        guard micAllowed else { return }
        lock.lock()
        keyHeld = true
        lock.unlock()
        let answering = isAsking
        // Figma, or a task's question tooltip under the pointer: the brain takes it. Nothing waits for the
        // last command, so you can point and talk again right away.
        if !answering, let brain = brain, brain.connected {
            let tip = tips?.taskUnderPointer()
            let window = AttentionBox.shared.get().window ?? WindowLocator.windowUnderPointer()
            if tip != nil || window.map(FigmaPointer.isFigma) == true {
                startBrainCommand(window: window, answerTo: tip)
                return
            }
        }
        stopSpeaking()

        let attention = AttentionBox.shared.get()
        let element = attention.element
        var target = attention.window ?? WindowLocator.windowUnderPointer()
        if answering {
            lock.lock()
            target = keyTarget ?? target
            lock.unlock()
        }
        guard let locked = target else {
            print("\n(no window under the pointer)")
            return
        }

        let session = takeVoice()
        session.onPartial = { [weak self] partial in
            print("\r  hearing: \(partial)        ", terminator: "")
            fflush(stdout)
            self?.onMain { $0.heard(partial) }
        }
        do {
            try session.startTalking()
        } catch {
            print("\nCould not start the microphone: \(error)")
            session.close()
            return
        }
        lock.lock()
        keySession = session
        keyTarget = locked
        keyElement = answering ? keyElement : element
        keyNearby = answering ? keyNearby : attention.nearby
        keyAnswering = answering
        keyDownAt = Date()
        lock.unlock()

        if answering, let p = pendingAnswer {
            card(p.taskId, "Listening for yes or no…", near: p.frame)
            print("\nListening for yes or no…")
        } else {
            let nearby = attention.nearby
            onMain { $0.lock(locked, element, nearby) }
            print("\nListening — talking to \(locked.appName)\(element.map { " (this = \($0.summary))" } ?? ""). Let go when you finish.")
            if nearby.count >= 2 {
                print("  \(nearby.count) clickable elements nearby are numbered on screen: say a number to pick another one.")
            }
        }
        if !session.readyWhenTalkStarted {
            print("  (the voice connection is still opening; your words are kept until it is ready)")
        }
    }

    private func startBrainCommand(window: TargetWindow?, answerTo: String?) {
        stopSpeaking()
        let command = BrainCommand(id: UUID().uuidString, answerTo: answerTo)
        if answerTo == nil {
            FigmaPointer.selectUnderPointer()       // Figma outlines the layer; the plugin tells the brain which one
        }
        brain?.send(FigmaPointer.pointMessage(id: command.id, window: window))

        let session = takeVoice()
        session.onPartial = { [weak self] partial in
            print("\r  hearing: \(partial)        ", terminator: "")
            fflush(stdout)
            self?.onMain { $0.heard(partial) }
        }
        do {
            try session.startTalking()
        } catch {
            print("\nCould not start the microphone: \(error)")
            session.close()
            return
        }
        lock.lock()
        keySession = session
        keyBrain = command
        keyTarget = window
        keyDownAt = Date()
        lock.unlock()
        if let w = window { onMain { $0.lock(w, nil) } }
        print(answerTo != nil ? "\nListening — your answer to the question under the pointer." :
              "\nListening — for the Figma layer under the pointer. Let go when you finish.")
    }

    /// Key up for a brain command: the words go to the brain, and Glance is free again at once.
    private func finishBrainCommand(_ command: BrainCommand, session: VoiceSession, held: TimeInterval) {
        Task.detached {
            if held < 0.3 {
                session.close()
                print("\n(too short: hold the key while you speak)")
                self.onMain { $0.finish(nil) }
                Glance.prompt()
                return
            }
            let text: String
            do {
                text = try await session.stopTalking()
            } catch {
                print("\nVoice error: \(error)")
                self.onMain { $0.finish("Sorry, I didn't catch that.") }
                Glance.prompt()
                return
            }
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if said.isEmpty {
                self.onMain { $0.finish(nil) }
                Glance.prompt()
                return
            }
            var msg: [String: Any] = ["type": "command", "id": command.id, "text": said]
            if let task = command.answerTo { msg["answerTo"] = task }
            self.brain?.send(msg)
            print("\nYou said: \"\(said)\"")
            self.onMain { $0.finish("“\(said)”") }
            Glance.prompt()
        }
    }

    func keyUp() {
        lock.lock()
        keyHeld = false
        if let command = keyBrain, let session = keySession {
            keyBrain = nil
            keySession = nil
            let held = Date().timeIntervalSince(keyDownAt)
            lock.unlock()
            finishBrainCommand(command, session: session, held: held)
            return
        }
        let heldSession = keySession
        let heldTarget = keyTarget
        let element = keyElement
        let nearby = keyNearby
        let answering = keyAnswering
        let held = Date().timeIntervalSince(keyDownAt)
        keySession = nil
        lock.unlock()
        guard let session = heldSession, let target = heldTarget else { return }

        Task.detached {
            if held < 0.3 {
                session.close()
                print("\n(too short: hold the key while you speak)")
                if !answering { self.onMain { $0.finish(nil) } }
                Glance.prompt()
                return
            }
            let stoppedAt = Date()
            let text: String
            do {
                text = try await session.stopTalking()
                print(String(format: "\nYou said: \"%@\"  (text ready %.1f s after you let go)",
                             text, Date().timeIntervalSince(stoppedAt)))
            } catch {
                print("\nVoice error: \(error)")
                if !answering { self.onMain { $0.finish("Sorry, I didn't catch that.") } }
                Glance.prompt()
                return
            }
            if answering {
                self.answerByVoice(text)
                return
            }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                self.onMain { $0.finish(nil) }
                Glance.prompt()
                return
            }
            // The command is now a task with its own card; the glow is free for the next window at once.
            let id = Glance.newTaskId()
            self.tasks.add(id, title: text, window: target)
            self.onMain { $0.finish(nil) }
            self.card(id, "“\(text)”\nWorking…", near: target.bounds)
            await self.run(text, on: target, pointed: element, nearby: nearby, taskId: id)
            Glance.prompt()
        }
    }

    // MARK: - Yes / no

    private static let yesWords: Set<String> = ["yes", "yeah", "yep", "sure", "approve", "approved", "confirm", "ok", "okay", "go"]
    private static let noWords: Set<String> = ["no", "nope", "cancel", "stop", "dont", "don't", "not", "never"]

    private func answerByVoice(_ text: String) {
        let plain = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let words = Set(plain.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty })
        let yes = !words.isDisjoint(with: Glance.yesWords) || plain.contains("do it")
        let no = !words.isDisjoint(with: Glance.noWords)
        if yes == no {
            print("(say yes or no)")
            if let p = pendingAnswer { card(p.taskId, "I didn't get a yes or no.\nHold the talk key and say yes or no.", near: p.frame) }
            Glance.prompt()
            return
        }
        _ = answerPending(yes ? "y" : "n")
    }

    /// Waits for a yes or no for one task: by voice (hold the talk key anywhere) or typed in the terminal.
    /// Questions from tasks running side by side wait their turn. No answer in 60 s means no.
    private func ask(_ action: String, taskId: String, target: TargetWindow) -> Bool {
        askGate.wait()
        defer { askGate.signal() }
        let p = PendingAnswer(taskId: taskId, frame: target.bounds)
        lock.lock()
        pending = p
        lock.unlock()
        tasks.set(taskId, "asking", detail: "Wants to: \(action)")
        card(taskId, "Muse wants to: \(action).\nHold the talk key and say yes or no.", near: target.bounds)
        announce("Should I \(action)?")
        print("\nMuse wants to: \(action).\nHold the talk key and say yes or no, or type y and press Enter here.")
        Glance.prompt()
        let answered = p.semaphore.wait(timeout: .now() + 60) == .success
        if !answered {
            lock.lock()
            if pending === p { pending = nil }
            lock.unlock()
            print("\n(no answer in 60 s, so not doing it)")
        }
        let go = answered && p.yes
        tasks.set(taskId, "running", detail: go ? "Doing it…" : "Cancelled.")
        card(taskId, go ? "Doing it…" : "Cancelled.", near: target.bounds)
        return go
    }

    /// Called with every line typed in the terminal. Returns true if it answered a pending question.
    func answerPending(_ line: String) -> Bool {
        lock.lock()
        let taken = pending
        pending = nil
        lock.unlock()
        guard let p = taken else { return false }
        p.yes = line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("y")
        p.semaphore.signal()
        return true
    }

    // MARK: - Typed commands

    func runTyped(_ command: String) async {
        if let brain = brain, brain.connected,
           let window = AttentionBox.shared.get().window ?? WindowLocator.windowUnderPointer(), FigmaPointer.isFigma(window) {
            let id = UUID().uuidString
            FigmaPointer.selectUnderPointer()
            brain.send(FigmaPointer.pointMessage(id: id, window: window))
            brain.send(["type": "command", "id": id, "text": command])
            Glance.prompt()
            return
        }
        let attention = AttentionBox.shared.get()
        guard let target = attention.window ?? WindowLocator.windowUnderPointer() else {
            print("No window under the pointer.")
            return
        }
        let id = Glance.newTaskId()
        tasks.add(id, title: command, window: target)
        card(id, "“\(command)”\nWorking…", near: target.bounds)
        await run(command, on: target, pointed: attention.element, nearby: attention.nearby, taskId: id)
        Glance.prompt()
    }

    // MARK: - Running a command

    /// One task: Muse Spark reads the window and acts in it. Many run at the same time, one per command.
    private func run(_ command: String, on target: TargetWindow, pointed: PointedElement?, nearby: [PointedElement],
                     taskId: String) async {
        let start = Date()
        print("Target: \(target.appName)\(target.title.isEmpty ? "" : " — \"\(target.title)\"")")
        do {
            let reply = try await agent.handle(command: command, target: target, pointed: pointed, nearby: nearby,
                                               confirm: { self.ask($0, taskId: taskId, target: target) },
                                               onPick: { picked in self.onMain { $0.pick(picked) } },
                                               log: { print("  \($0)") })
            print("Glance: \(reply)  (\(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
            tasks.set(taskId, "done", detail: reply)
            card(taskId, reply, near: target.bounds, hideAfter: 12)
            announce(reply)
        } catch {
            print("Error: \(error)")
            tasks.set(taskId, "failed", detail: "\(error)")
            card(taskId, "Something went wrong: \(error)", near: target.bounds, hideAfter: 12)
        }
    }

    /// Reads a result or question aloud, when that is switched on. Results that finish together take turns,
    /// and nothing is read while the talk key is held, so the microphone never hears Glance itself.
    func announce(_ text: String) {
        guard SpeechSwitch.shared.on else { return }
        speech.async {
            while true {
                self.lock.lock()
                let held = self.keyHeld
                self.lock.unlock()
                if !held { break }
                usleep(100_000)
            }
            guard SpeechSwitch.shared.on else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            p.arguments = [text]
            self.lock.lock()
            self.speaker = p
            self.lock.unlock()
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// Stops a spoken reply, so the microphone does not hear Glance itself.
    private func stopSpeaking() {
        lock.lock()
        let p = speaker
        speaker = nil
        lock.unlock()
        if let p = p, p.isRunning { p.terminate() }
    }

    func shutDown() {
        lock.lock()
        let s = spare
        lock.unlock()
        s?.close()
    }
}
