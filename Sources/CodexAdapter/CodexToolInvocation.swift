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

    /// The canonical local function tool emitted by current Codex clients when
    /// the model asks the user one or more structured questions.
    static let requestUserInputTool = "request_user_input"

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

    /// The first usable question in `request_user_input`, plus how many other
    /// usable questions the same prompt contains.
    ///
    /// The nested shape is provider data and stops here. A malformed or future
    /// shape still produces a neutral wait line rather than becoming an
    /// ordinary tool call and hiding that Codex needs the user.
    static func question(input: JSONValue?) -> String {
        guard let questions = input?.object?["questions"]?.array else {
            return "Codex needs your input"
        }
        func firstLine(for key: String) -> String? {
            questions.lazy.compactMap { value -> String? in
                guard let text = value.object?[key]?.string else { return nil }
                let line = condense(text)
                return line.isEmpty ? nil : line
            }.first
        }
        guard let first = firstLine(for: "question") ?? firstLine(for: "header") else {
            return "Codex needs your input"
        }
        let remaining = max(0, questions.count - 1)
        guard remaining > 0 else { return first }
        let suffix = " (+\(remaining) more)"
        return condense(first, limit: max(1, limit - suffix.count)) + suffix
    }

    /// One line naming what Codex is asking permission to do.
    ///
    /// `description` has priority only on permission requests: it is Codex's
    /// human-readable approval reason. Ordinary tool rows still prefer the
    /// concrete command or path in `summarise`.
    static func approvalSummary(tool: String?, input: JSONValue?) -> String {
        if let description = input?.object?["description"]?.string {
            let line = condense(description)
            if !line.isEmpty, !containsCredentialShape(line) { return line }
        }
        if let line = safeApprovalInvocation(input: input) { return line }
        if let tool {
            let line = condense(tool)
            if !line.isEmpty { return line }
        }
        return "Codex requested approval"
    }

    /// A deliberately lossy command/path line for a lock-screen surface.
    /// Ordinary tool rows may show the bounded invocation; an approval can be
    /// visible before the Mac is unlocked, so it keeps only an executable plus
    /// a harmless-looking subcommand, or a path's final component.
    private static func safeApprovalInvocation(input: JSONValue?) -> String? {
        guard let object = input?.object else { return nil }
        for key in ["command", "cmd"] {
            guard let value = object[key], let text = scalar(value) else { continue }
            if let summary = safeCommandSummary(text) { return summary }
        }
        for key in ["file_path", "path", "filename", "file"] {
            guard let text = object[key]?.string else { continue }
            let path = URL(filePath: text).lastPathComponent
            if !path.isEmpty { return condense(path) }
        }
        return nil
    }

    private static func safeCommandSummary(_ text: String) -> String? {
        let line = condense(text)
        guard !line.isEmpty, !containsCredentialShape(line) else { return nil }
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = parts.first, !first.contains("=") else { return nil }
        let executable = URL(filePath: first.trimmingCharacters(in: .shellQuotes)).lastPathComponent
        guard !executable.isEmpty else { return nil }

        guard parts.count > 1 else { return executable }
        let subcommand = parts[1].trimmingCharacters(in: .shellQuotes)
        let allowedSubcommands: [String: Set<String>] = [
            "git": [
                "add", "branch", "checkout", "clone", "commit", "diff", "fetch", "log", "merge",
                "pull", "push", "rebase", "restore", "status", "switch", "tag",
            ],
            "swift": ["build", "package", "run", "test"],
        ]
        return allowedSubcommands[executable]?.contains(subcommand) == true
            ? condense("\(executable) \(subcommand)") : executable
    }

    private static func containsCredentialShape(_ text: String) -> Bool {
        let lower = text.lowercased()
        return [
            "authorization:", "bearer ", "token=", "secret=", "password=",
            "passwd=", "api-key", "api_key", "apikey", "cookie:", "credential=",
            "sk-", "ghp_", "xoxb-", "akia",
        ].contains { lower.contains($0) }
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
    static func condense(_ text: String, limit: Int = limit) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        guard limit > 1 else { return "…" }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}

extension CharacterSet {
    fileprivate static let shellQuotes = CharacterSet(charactersIn: "'\"")
}
