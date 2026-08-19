import Foundation

/// Enough of TOML to read two tables out of a file AgentBar must never write.
///
/// `~/.codex/config.toml` holds the two facts nothing else can supply: whether
/// Codex has trusted a hook (`[hooks.state]`), and which hooks the user has of
/// their own (`[[hooks.<Event>]]`). Both have to be read from there, and neither
/// justifies a TOML dependency — this reads *tables and scalars* and skips
/// everything else it meets.
///
/// Three properties are load-bearing:
///
/// - **It never fails.** Any line it cannot make sense of is skipped. A
///   configuration file that has grown syntax this does not know must make
///   AgentBar less certain, never make it throw.
/// - **It reads only what it was asked for.** The caller takes two table paths;
///   everything else — including whatever credentials a `config.toml` may hold
///   for a model provider — is parsed into oblivion rather than into a value
///   somebody could log by accident.
/// - **It is not a writer.** There is no counterpart to this type anywhere in
///   the module, and there must never be one.
enum TOMLTables {
    /// One table, with its scalar keys rendered as text.
    struct Table: Sendable, Hashable {
        /// The dotted path, already unquoted: `["hooks", "state", "…:stop:0:0"]`.
        let path: [String]
        /// Whether it arrived as `[[an.array]]` element rather than `[a.table]`.
        let isArrayElement: Bool
        /// Scalars only: strings are unescaped, everything else is the literal
        /// text as written. Arrays and inline tables are absent.
        let values: [String: String]
    }

    /// Every table in the document, in the order they appear.
    ///
    /// Order matters for arrays of tables: `[[hooks.Stop.hooks]]` belongs to the
    /// most recent `[[hooks.Stop]]`, and reading them in sequence is what lets a
    /// caller pair the two without a full TOML value tree.
    static func tables(in text: String) -> [Table] {
        var tables: [Table] = []
        var path: [String] = []
        var isArrayElement = false
        var values: [String: String] = [:]
        var started = false

        func flush() {
            guard started else { return }
            tables.append(Table(path: path, isArrayElement: isArrayElement, values: values))
            values = [:]
        }

        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while let raw = lines.first {
            lines = lines.dropFirst()
            let line = stripComment(String(raw)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                flush()
                guard let header = parseHeader(line) else {
                    // An unreadable header would otherwise leave the keys that
                    // follow attributed to the table before it, which is how a
                    // foreign value gets read as one of ours.
                    started = false
                    path = []
                    continue
                }
                path = header.path
                isArrayElement = header.isArrayElement
                started = true
                continue
            }

            guard started, let (key, rest) = splitAssignment(line) else { continue }
            if let opening = multilineOpening(in: rest) {
                skipMultiline(closing: opening, in: &lines, startingWith: rest)
                continue
            }
            if let value = scalar(rest) { values[key] = value }
        }
        flush()
        return tables
    }

    // MARK: - Lines

    /// Removes a trailing comment, leaving `#` inside a string alone.
    private static func stripComment(_ line: String) -> String {
        var result = ""
        var quote: Character?
        var escaped = false
        for character in line {
            if let open = quote {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else if character == open {
                    quote = nil
                }
                continue
            }
            if character == "#" { break }
            if character == "\"" || character == "'" { quote = character }
            result.append(character)
        }
        return result
    }

    /// `[a.b."c"]` or `[[a.b]]`, unquoted.
    private static func parseHeader(_ line: String) -> (path: [String], isArrayElement: Bool)? {
        let isArrayElement = line.hasPrefix("[[")
        let opening = isArrayElement ? 2 : 1
        guard line.hasSuffix(isArrayElement ? "]]" : "]") else { return nil }
        let inner = String(line.dropFirst(opening).dropLast(opening))
            .trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }
        let components = splitPath(inner)
        guard !components.isEmpty else { return nil }
        return (components, isArrayElement)
    }

    /// Splits on dots that are not inside quotes, and unquotes each component.
    private static func splitPath(_ text: String) -> [String] {
        var components: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case ".":
                components.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default: current.append(character)
            }
        }
        // An unterminated quote is a line this reader does not understand.
        guard quote == nil else { return [] }
        components.append(current.trimmingCharacters(in: .whitespaces))
        return components.contains(where: \.isEmpty) ? [] : components
    }

    /// `key = value`, split at the first `=` outside a quoted key.
    private static func splitAssignment(_ line: String) -> (key: String, value: String)? {
        var quote: Character?
        for (offset, character) in line.enumerated() {
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            guard character == "=" else { continue }
            let index = line.index(line.startIndex, offsetBy: offset)
            let key = String(line[line.startIndex..<index]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: index)...])
                .trimmingCharacters(in: .whitespaces)
            let unquoted = unquoteKey(key)
            guard !unquoted.isEmpty, !value.isEmpty else { return nil }
            return (unquoted, value)
        }
        return nil
    }

    private static func unquoteKey(_ key: String) -> String {
        guard key.count >= 2, let first = key.first, first == "\"" || first == "'",
            key.last == first
        else { return key }
        return String(key.dropFirst().dropLast())
    }

    // MARK: - Values

    /// A scalar as text, or `nil` for an array, an inline table or an empty
    /// value — none of which this reader has any use for.
    private static func scalar(_ text: String) -> String? {
        guard let first = text.first else { return nil }
        switch first {
        case "\"": return basicString(text)
        case "'": return literalString(text)
        case "[", "{": return nil
        default: return text
        }
    }

    private static func basicString(_ text: String) -> String? {
        var result = ""
        var escaped = false
        for character in text.dropFirst() {
            if escaped {
                switch character {
                case "n": result.append("\n")
                case "t": result.append("\t")
                case "r": result.append("\r")
                case "\\": result.append("\\")
                case "\"": result.append("\"")
                // `\u` and friends are left as written rather than guessed at.
                default: result.append(character)
                }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "\"" { return result }
            result.append(character)
        }
        return nil
    }

    private static func literalString(_ text: String) -> String? {
        let body = text.dropFirst()
        guard let end = body.firstIndex(of: "'") else { return nil }
        return String(body[body.startIndex..<end])
    }

    private static func multilineOpening(in text: String) -> String? {
        for delimiter in ["\"\"\"", "'''"] where text.hasPrefix(delimiter) {
            return delimiter
        }
        return nil
    }

    /// Consumes a multi-line string without reading it.
    ///
    /// The value itself is of no interest; what matters is that its contents —
    /// which may contain anything, including something shaped like a table
    /// header — are not read as configuration.
    private static func skipMultiline(
        closing delimiter: String, in lines: inout ArraySlice<Substring>, startingWith first: String
    ) {
        if first.dropFirst(delimiter.count).contains(delimiter) { return }
        while let line = lines.first {
            lines = lines.dropFirst()
            if line.contains(delimiter) { return }
        }
    }
}
