import Foundation
import Network
import Testing
@testable import Glance

/// Quest Desk: terminal text cleanup, what speech becomes, and a real shell on a pseudo terminal.
/// Serialized: every hub answers discovery on the same UDP port, as the one real app does.
@Suite(.serialized)
struct QuestDeskTests {

    @Test func ansiIsStripped() {
        #expect(TerminalText.stripANSI("\u{1b}[32mok\u{1b}[0m!") == "ok!")
        #expect(TerminalText.stripANSI("\u{1b}]8;;https://example.com\u{07}link\u{1b}]8;;\u{07}") == "link")
        #expect(TerminalText.stripANSI("plain") == "plain")
    }

    @Test func terminalTextAppliesReturnsAndKeepsTail() {
        var text = TerminalText()
        text.append("one\ntwo\rTWO\nthree")
        #expect(text.snapshot() == "one\nTWO\nthree")
        text.append("\u{1b}[1m bold\u{1b}[0m")
        #expect(text.snapshot().hasSuffix("three bold"))
    }

    @Test func speechBecomesCommandsAndKeys() {
        #expect(QuestSpeech.injection(for: "ls -la") == "ls -la\r")
        #expect(QuestSpeech.injection(for: "control c") == "\u{03}")
        #expect(QuestSpeech.injection(for: "Enter.") == "\r")
        #expect(QuestSpeech.injection(for: "type hello world") == "hello world")
        #expect(QuestSpeech.injection(for: "   ") == nil)
    }

    @Test func questHubServesATerminalOverWebSocket() async throws {
        let hub = QuestHub(token: nil)
        hub.start(port: 47991)
        defer { hub.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:47991")!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        // Collect text messages until one matches, or time runs out.
        func next(matching needle: String) async -> String {
            for _ in 0..<30 {
                guard let message = try? await socket.receive(),
                      case .string(let text) = message else { continue }
                if text.contains(needle) { return text }
            }
            return ""
        }
        func send(_ text: String) async {
            try? await socket.send(.string(text))
        }

        await send(#"{"type":"hello","app":"test"}"#)
        #expect(await next(matching: #""type":"hello""#).contains("quest-desk-1"))
        await send(#"{"type":"term_create","title":"WS Test"}"#)
        var listed = await next(matching: "term_list")
        while !listed.contains("WS Test") { // the hello reply also carries a (then empty) list
            let more = await next(matching: "term_list")
            if more.isEmpty { break }
            listed = more
        }
        #expect(listed.contains("WS Test"))
        guard let data = listed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terms = json["terms"] as? [[String: Any]],
              let id = terms.first?["id"] as? String else {
            Issue.record("No terminal id in \(listed)")
            return
        }
        _ = await next(matching: "term_output")
        await send("{\"type\":\"term_input\",\"id\":\"\(id)\",\"text\":\"echo via-websocket\\r\"}")
        #expect(await next(matching: "via-websocket").contains("via-websocket"))
    }

    /// Reviewer setup is two steps (launch the app, open the Quest app), so with no token the
    /// headset must be able to find the Mac and get floating windows without typing anything.
    @Test func discoveryAnswersAndWindowsNeedNoToken() async throws {
        let hub = QuestHub(token: nil)
        hub.start(port: 47992)
        defer { hub.stop() }
        try await Task.sleep(for: .milliseconds(300))

        let reply: String = await withCheckedContinuation { continuation in
            let connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: QuestHub.discoveryPort)!, using: .udp)
            connection.stateUpdateHandler = { state in
                if case .ready = state {
                    connection.send(content: Data("GLANCE_DISCOVER".utf8), completion: .contentProcessed { _ in })
                }
            }
            // Another hub from a parallel test may answer first; keep asking until this hub does.
            var tries = 0
            var receiveAgain: (() -> Void)!
            receiveAgain = {
                connection.receiveMessage { data, _, _, _ in
                    let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                    tries += 1
                    if text.contains("47992") || tries > 10 {
                        continuation.resume(returning: text)
                        connection.cancel()
                    } else {
                        connection.send(content: Data("GLANCE_DISCOVER".utf8), completion: .contentProcessed { _ in })
                        receiveAgain()
                    }
                }
            }
            receiveAgain()
            connection.start(queue: DispatchQueue(label: "glance.test.discovery"))
        }
        // A glance_mac reply is success. The exact port is this hub's when it is the only Glance
        // running; a Glance the user already launched answers with its own port instead, which
        // is equally proof the headset would find a Mac. (The windows check below is this hub's.)
        #expect(reply.contains("\"type\":\"glance_mac\""))
        #expect(reply.contains("\"port\":"))

        let socket = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:47992")!)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        try? await socket.send(.string(#"{"type":"hello","app":"test","proto":2}"#))
        var hello = ""
        for _ in 0..<30 {
            guard let message = try? await socket.receive(), case .string(let text) = message else { continue }
            if text.contains("\"type\":\"hello\"") { hello = text; break }
        }
        #expect(hello.contains("\"windows\":true"))
    }

    @Test func realShellRunsAndReplies() async throws {
        let hub = TermHub()
        let created = hub.create(title: "Test")
        let info = try #require(created)
        defer { hub.closeAll() }
        // Wait for the prompt, then send the marker line; the marker proves the shell ran it.
        var seen = ""
        for attempt in 0..<30 {
            try await Task.sleep(for: .milliseconds(200))
            seen = hub.snapshot(id: info.id)?.text ?? ""
            if seen.contains("quest-desk-ok") { break }
            if attempt % 5 == 0 { #expect(hub.input(id: info.id, "echo quest-desk-ok\r")) }
        }
        #expect(seen.contains("quest-desk-ok"))
    }
}
