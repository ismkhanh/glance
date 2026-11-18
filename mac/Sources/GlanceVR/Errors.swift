/// An error with a message for the user (window capture, permissions).
struct ScriptError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
