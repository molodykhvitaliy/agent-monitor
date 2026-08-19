import Foundation

/// Turns a tool's arguments into the one line a session row shows.
///
/// Two rules decide what comes out. It names *what* the agent is doing, so the
/// field chosen per tool is the identifying one — a command, a path, a pattern.
/// And it never carries content: `Write` and `Edit` arrive with the whole file
/// in `tool_input`, and a menu-bar row is not where a file belongs, quite apart
/// from the memory it would cost to keep one for as long as the session lives.
enum ToolInvocation {
    /// Roughly two lines in the panel's monospace column at its narrowest.
    static let limit = 120

    static func summarise(tool: String, input: JSONValue?) -> String? {
        guard let object = input?.object else { return nil }

        func string(_ key: String) -> String? {
            guard let value = object[key]?.string, !value.isEmpty else { return nil }
            return value
        }

        let raw: String?
        switch tool {
        case "Bash", "PowerShell", "BashOutput", "KillShell":
            raw = string("command") ?? string("shell_id")
        case "Read", "Write", "Edit", "NotebookEdit":
            raw = string("file_path").map(shortenPath)
        case "Glob", "Grep":
            raw = string("pattern")
        case "WebFetch":
            raw = string("url").map(stripQuery)
        case "WebSearch":
            raw = string("query")
        case "Agent", "Task":
            raw = string("description") ?? string("subagent_type")
        case "Skill":
            raw = string("skill")
        case "AskUserQuestion":
            // The one tool whose arguments *are* the thing worth showing: this
            // is the line the Waiting row and the `Question` notification carry
            // (ADR-0005). `question` is the sentence a person answers; `header`
            // is its two-word label and stands in only if the sentence is
            // absent. A multi-question call shows the first — one bounded line
            // is the whole budget, and the first is the one being asked.
            raw = firstQuestion(in: object["questions"])
        case "TodoWrite", "ExitPlanMode":
            // Nothing in the arguments reads better than the tool's own name.
            raw = nil
        default:
            raw = nil
        }
        return raw.map(condense)
    }

    /// `tool_input.questions[0].question`, as Claude Code 2.1.233 sends it —
    /// verified against seven recorded local payloads and recorded in
    /// docs/dev/platform-integration.md.
    ///
    /// Read defensively like every other field here: a `questions` that arrives
    /// as something else, or an entry with neither key, makes the row slightly
    /// less informative rather than making the payload fail.
    private static func firstQuestion(in value: JSONValue?) -> String? {
        guard let first = value?.array?.first?.object else { return nil }
        for key in ["question", "header"] {
            if let text = first[key]?.string, !text.isEmpty { return text }
        }
        return nil
    }

    /// The last two path components, which is enough to tell two files apart
    /// without spending the row on a home directory.
    private static func shortenPath(_ path: String) -> String {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count > 2 else { return path }
        return "…/" + components.suffix(2).joined(separator: "/")
    }

    /// A query string is where a URL keeps its credentials often enough that
    /// displaying one is not worth the information it adds.
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
