import Foundation

/// Renders a `JSONValue` the way the tools that own these files render theirs.
///
/// Two spaces of indent, a space after each colon, no escaped solidus and no
/// `\u` escaping of characters that do not need it — which is what
/// `JSON.stringify(value, null, 2)` produces, and therefore what
/// `~/.claude/settings.json` already looks like. Matching it means the file
/// AgentBar writes differs from the file it read only where AgentBar changed
/// something, and a diff stays readable instead of covering every line.
public enum JSONWriter {
    public static func render(_ value: JSONValue) -> String {
        var output = ""
        write(value, depth: 0, into: &output)
        output.append("\n")
        return output
    }

    public static func data(_ value: JSONValue) -> Data {
        Data(render(value).utf8)
    }

    private static func write(_ value: JSONValue, depth: Int, into output: inout String) {
        switch value {
        case .object(let object):
            guard !object.isEmpty else {
                output.append("{}")
                return
            }
            output.append("{\n")
            let inner = indent(depth + 1)
            for (index, pair) in object.pairs.enumerated() {
                output.append(inner)
                writeString(pair.key, into: &output)
                output.append(": ")
                write(pair.value, depth: depth + 1, into: &output)
                output.append(index == object.count - 1 ? "\n" : ",\n")
            }
            output.append(indent(depth))
            output.append("}")

        case .array(let elements):
            guard !elements.isEmpty else {
                output.append("[]")
                return
            }
            output.append("[\n")
            let inner = indent(depth + 1)
            for (index, element) in elements.enumerated() {
                output.append(inner)
                write(element, depth: depth + 1, into: &output)
                output.append(index == elements.count - 1 ? "\n" : ",\n")
            }
            output.append(indent(depth))
            output.append("]")

        case .string(let text):
            writeString(text, into: &output)

        case .number(let text):
            output.append(text)

        case .bool(let flag):
            output.append(flag ? "true" : "false")

        case .null:
            output.append("null")
        }
    }

    private static func indent(_ depth: Int) -> String {
        String(repeating: "  ", count: depth)
    }

    /// Escapes only what JSON requires: the quote, the backslash and the C0
    /// controls. A path with a `/` in it stays readable, and a name in a
    /// non-Latin script survives as itself rather than as a row of `\u` escapes.
    private static func writeString(_ text: String, into output: inout String) {
        output.append("\"")
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output.append("\\\"")
            case "\\": output.append("\\\\")
            case "\n": output.append("\\n")
            case "\r": output.append("\\r")
            case "\t": output.append("\\t")
            case Unicode.Scalar(0x08): output.append("\\b")
            case Unicode.Scalar(0x0C): output.append("\\f")
            case let other where other.value < 0x20:
                output.append(String(format: "\\u%04x", other.value))
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output.append("\"")
    }
}
