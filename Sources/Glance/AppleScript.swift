import Foundation

struct ScriptError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// Runs AppleScript through /usr/bin/osascript. macOS asks once per app ("Terminal wants to control Chrome").
enum AppleScript {
    @discardableResult
    static func run(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(source.utf8))
        try? input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: err, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown error"
            throw ScriptError(message: message)
        }
        return String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Makes a Swift string safe inside an AppleScript "..." literal.
    static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Finds which scripting window matches the window under the pointer, by comparing bounds.
/// `listScript` must return one line per window: "id|x1,y1,x2,y2".
func matchScriptWindow(listScript: String, target: TargetWindow) -> Int? {
    guard let text = try? AppleScript.run(listScript) else { return nil }
    var best: (id: Int, distance: Double)?
    for line in text.split(separator: "\n") {
        let parts = line.split(separator: "|")
        guard parts.count == 2, let id = Int(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
        let nums = parts[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard nums.count == 4 else { continue }
        let d = abs(nums[0] - Double(target.bounds.minX)) + abs(nums[1] - Double(target.bounds.minY))
            + abs(nums[2] - Double(target.bounds.maxX)) + abs(nums[3] - Double(target.bounds.maxY))
        if best == nil || d < best!.distance { best = (id: id, distance: d) }
    }
    guard let b = best, b.distance < 40 else { return nil }
    return b.id
}
