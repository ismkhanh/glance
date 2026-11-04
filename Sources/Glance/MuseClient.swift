import Foundation

struct FunctionCall {
    let callID: String
    let name: String
    let arguments: [String: Any]
}

/// Anything that answers a Responses request: Muse itself, or a scripted stand-in in the tests.
protocol MuseResponding: AnyObject {
    func respond(_ body: [String: Any]) async throws -> [String: Any]
}

/// Minimal client for the Meta Model API Responses endpoint.
final class MuseClient: MuseResponding {
    private let key: String
    private let endpoint = URL(string: "https://api.meta.ai/v1/responses")!

    init(key: String) {
        self.key = key
    }

    /// Sends one Responses request. Retries once on a server error (we saw 1 in 11 calls fail on 31 Oct).
    func respond(_ body: [String: Any]) async throws -> [String: Any] {
        var lastError: Error = ScriptError(message: "Muse was not called")
        for attempt in 0..<2 {
            var request = URLRequest(url: endpoint, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let result: (Data, URLResponse)
            do {
                result = try await URLSession.shared.data(for: request)
            } catch {
                lastError = error
                if attempt == 0 {
                    print("  (network error, retrying once: \(error.localizedDescription))")
                    continue
                }
                throw error
            }
            let (data, response) = result
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
            let failed = (json["status"] as? String) == "failed"
            if status == 200 && !failed { return json }

            let text = String(data: data, encoding: .utf8) ?? ""
            lastError = ScriptError(message: "Muse returned HTTP \(status): \(text.prefix(300))")
            let retryable = status >= 500 || failed || text.contains("server_error")
            if retryable && attempt == 0 {
                print("  (Muse error, retrying once: \(text.prefix(120)))")
                continue
            }
            throw lastError
        }
        throw lastError
    }

    static func text(_ response: [String: Any]) -> String {
        if let t = response["output_text"] as? String, !t.isEmpty { return t }
        var parts: [String] = []
        for item in (response["output"] as? [[String: Any]]) ?? [] where (item["type"] as? String) == "message" {
            for content in (item["content"] as? [[String: Any]]) ?? [] {
                if let t = content["text"] as? String { parts.append(t) }
            }
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func functionCalls(_ response: [String: Any]) -> [FunctionCall] {
        let items = (response["output"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> FunctionCall? in
            guard (item["type"] as? String) == "function_call",
                  let name = item["name"] as? String,
                  let callID = item["call_id"] as? String else { return nil }
            let argsText = item["arguments"] as? String ?? "{}"
            let args = ((try? JSONSerialization.jsonObject(with: Data(argsText.utf8))) as? [String: Any]) ?? [:]
            return FunctionCall(callID: callID, name: name, arguments: args)
        }
    }
}
