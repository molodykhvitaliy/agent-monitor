import AgentBarJSON
import Foundation

/// Turns a Codex tool's arguments into the one line a session row shows.
///
/// The Claude Code version of this switches on the tool's name, because that
/// list is documented and stable. Codex's is neither: the tool set moves with
/// the model, a plugin or an MCP server can add one at any time, and a name
/// AgentBar has never heard of is the normal case rather than the exception. So
/// this looks at the *arguments* instead, taking the first identifying field it
/// recognises, and a tool nobody anticipated still shows its command or its path
/// rather than nothing.
///
/// The two rules from the Claude Code side hold unchanged: name *what* the agent
/// is doing, and never carry content. A patch or a file body in the arguments is
/// not something a menu-bar row displays, quite apart from the memory it would
/// cost to hold one for as long as the session lives.
enum CodexToolInvocation {
    /// Roughly two lines in the panel's monospace column at its narrowest. The
    /// same bound the Claude Code line uses — it is a property of the column,
    /// not of the provider.
    static let limit = 120

    /// Argument names that identify a call, in the order they are preferred.
    ///
    /// `command` first because the shell tool is the one that matters most, and
    /// paths before free text because a path says where the work is happening.
    /// Anything not on this list is ignored: an unrecognised argument is far
    /// more likely to be a file's contents than a description of the call.
    static let identifyingKeys = [
        "command", "cmd", "script",
        "file_path", "path", "filename", "file",
        "pattern", "query", "url",
        "description", "name",
    ]

    static func summarise(tool: String, input: JSONValue?) -> String? {
        guard let object = input?.object else { return nil }
        for key in identifyingKeys {
            guard let value = object[key], let text = scalar(value), !text.isEmpty else { continue }
            return condense(key == "url" ? stripQuery(text) : text)
        }
        return nil
    }

    /// A string, a number, or an array of them joined the way a shell would
    /// print it.
    ///
    /// The array case is the shell tool: Codex sends `command` as an argument
    /// vector, and `["bash", "-lc", "swift test"]` read back as a bare list
    /// would be less legible than the command line it stands for. Nested
    /// containers produce nothing rather than a rendering of their own — a line
    /// AgentBar cannot describe honestly is a line it does not show.
    private static func scalar(_ value: JSONValue) -> String? {
        if let text = value.string { return text }
        if let number = value.numberText { return number }
        if let array = value.array {
            let parts = array.compactMap { $0.string ?? $0.numberText }
            guard parts.count == array.count, !parts.isEmpty else { return nil }
            return parts.joined(separator: " ")
        }
        return nil
    }

    /// A query string is where a URL keeps its credentials often enough that
    /// showing one is not worth the information it adds.
    static func stripQuery(_ text: String) -> String {
        guard let index = text.firstIndex(where: { $0 == "?" || $0 == "#" }) else { return text }
        return String(text[text.startIndex..<index])
    }

    /// One line, whitespace collapsed, bounded.
    static func condense(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}
