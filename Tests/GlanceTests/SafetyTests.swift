import CoreGraphics
import Foundation
import Testing
@testable import Glance

/// The rules that decide what Glance asks before doing, and what it never sends to Muse.
@Suite struct SafetyTests {
    // Fake keys, split in two so secret scanners don't take them for real ones.
    @Test("Secrets on screen are hidden before window text goes to Muse",
          arguments: [
              "export OPENAI_API_KEY=sk-" + "proj-AbCdEfGhIjKlMnOpQrStUv",
              "token: ghp_" + "16C7e42F292c6912E7710c838347Ae178B4a",
              "aws_access_key_id = AKIA" + "IOSFODNN7EXAMPLE",
              "Bearer eyJ" + "hbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9eyJzdWIiOiIxMjM0NTY3ODkwIn0",
              "SLACK=xoxb-" + "123456789012-abcdefghijkl",
          ])
    func secretsAreMasked(line: String) {
        let masked = maskSecrets(line)
        #expect(masked.contains("[hidden]"), "\(masked)")
        #expect(!masked.contains("AbCdEfGhIjKlMnOpQrStUv") && !masked.contains("IOSFODNN7EXAMPLE") && !masked.contains("16C7e42F"))
    }

    @Test("Ordinary terminal output is left as it is")
    func ordinaryTextIsKept() {
        let text = "Tests: 1 failed, 12 passed\nexpect(total).toBe(90) // received 81\ncommit 3f2a9c1 Fix the cart"
        #expect(maskSecrets(text) == text)
    }

    @Test("Buttons that delete, send, pay or quit are confirmed first",
          arguments: ["Delete", "Send message", "Buy now", "Pay $12", "Sign out", "Place order", "Quit", "Move to Trash", "Deleted items"])
    func riskyLabels(label: String) {
        #expect(looksRisky(label))
    }

    @Test("Words that only contain a risky word are not risky",
          arguments: ["Border radius", "Display settings", "More information", "Open", "Next", "Save draft", "Recorder"])
    func harmlessLabels(label: String) {
        #expect(!looksRisky(label))
    }

    @Test("Keys that quit, close, trash or interrupt are confirmed however they are written",
          arguments: ["cmd+q", "Command + Q", "q+cmd", "⌘+W", "cmd+shift+w", "cmd+delete", "cmd+backspace",
                      "control+c", "ctrl + C", "ctrl+d", "cmd+option+esc"])
    func riskyKeys(combo: String) {
        #expect(keysAreRisky(["combo": combo]))
        #expect(TerminalAdapter.needsConfirmation("press_keys", ["combo": combo]))
    }

    @Test("Everyday keys are not", arguments: ["cmd+t", "space", "return", "cmd+shift+t", "tab", "ctrl+a", "down"])
    func everydayKeys(combo: String) {
        #expect(!keysAreRisky(["combo": combo]))
    }

    @Test("Key combinations read the same whatever the order, case or alias")
    func keyCombosNormalise() {
        #expect(KeyCombo("Command + Shift + T") == KeyCombo("shift+cmd+t"))
        #expect(KeyCombo("esc") == KeyCombo("escape"))
        #expect(KeyCombo("opt+left").modifiers == ["option"])
        #expect(KeyCombo("backspace").key == "delete")
    }

    @Test("Every line typed into a terminal is confirmed, whatever it is")
    func terminalLinesAreConfirmed() {
        for line in ["ls", "git status", "y", "rm -rf build"] {
            #expect(TerminalAdapter.needsConfirmation("type_in_terminal", ["text": line]))
        }
    }
}

@Suite struct ParsingTests {
    @Test("The key comes from the environment first, else from .env in the Glance folder")
    func museKey() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("glance-\(UUID().uuidString).env")
        try "OTHER=1\nexport MUSE_API_KEY=\"abc123\"\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(GlanceMain.museKey(environment: [:], envFile: file.path) == "abc123")
        #expect(GlanceMain.museKey(environment: ["MUSE_API_KEY": "env"], envFile: file.path) == "env")
        #expect(GlanceMain.museKey(environment: [:], envFile: file.path + ".missing") == nil)
    }

    @Test("The brain gets the app's key, so it works from any folder; a key already set is kept")
    func brainGetsTheKey() {
        let env = BrainLink.environment(["PATH": "/usr/bin"], token: "t", museKey: "found")
        #expect(env["MUSE_API_KEY"] == "found")
        #expect(env["GLANCE_TOKEN"] == "t" && env["PATH"] == "/usr/bin")
        #expect(BrainLink.environment(["MUSE_API_KEY": "mine"], token: "t", museKey: "found")["MUSE_API_KEY"] == "mine")
        #expect(BrainLink.environment([:], token: "t", museKey: nil)["MUSE_API_KEY"] == nil)
    }

    @Test("Tool calls and text are read the same way as the brain's client")
    func readsMuseResponses() {
        let response: [String: Any] = ["output": [
            ["type": "message", "content": [["type": "output_text", "text": "Committing."]]],
            ["type": "function_call", "call_id": "c1", "name": "type_in_terminal", "arguments": "{\"text\":\"git commit -m wip\"}"],
            ["type": "function_call", "call_id": "c2", "name": "bad", "arguments": "{not json"],
            ["type": "function_call", "name": "no_call_id", "arguments": "{}"],
        ]]
        #expect(MuseClient.text(response) == "Committing.")
        let calls = MuseClient.functionCalls(response)
        #expect(calls.map(\.name) == ["type_in_terminal", "bad"])
        #expect(calls[0].arguments["text"] as? String == "git commit -m wip")
        #expect(calls[1].arguments.isEmpty)
    }

    @Test("Numbers may come as 2, 2.0 or \"2\"")
    func numbers() {
        #expect(Agent.number(2) == 2)
        #expect(Agent.number(2.0) == 2)
        #expect(Agent.number(" 2 ") == 2)
        #expect(Agent.number("two") == nil)
        #expect(Agent.number(nil) == nil)
    }

    @Test("A failed tool sends Muse round again; a success does not")
    func failures() {
        #expect(Agent.isFailure("Could not type into the terminal"))
        #expect(Agent.isFailure("No element with number 7. Numbers go from 1 to 3."))
        #expect(!Agent.isFailure("Typed: git status"))
    }

    @Test("Where another element is, from the highlighted one")
    func directions() {
        let a = CGRect(x: 100, y: 100, width: 40, height: 20)
        #expect(Snap.direction(from: a, to: a) == "same place")
        #expect(Snap.direction(from: a, to: a.offsetBy(dx: 60, dy: 0)) == "about 60 pt right")
        #expect(Snap.direction(from: a, to: a.offsetBy(dx: -30, dy: -40)) == "about 50 pt left and above")
        #expect(Snap.distance(CGPoint(x: 110, y: 110), a) == 0)
        #expect(Snap.distance(CGPoint(x: 150, y: 110), a) == 10)
    }
}
