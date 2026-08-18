import Foundation

public enum JSONParsingError: Error, Sendable, Hashable, CustomStringConvertible {
    case empty
    case unexpectedByte(offset: Int)
    case unexpectedEnd
    case invalidNumber(offset: Int)
    case invalidEscape(offset: Int)
    case invalidUnicode(offset: Int)
    case invalidUTF8(offset: Int)
    case trailingContent(offset: Int)
    case tooDeep(offset: Int)

    public var description: String {
        switch self {
        case .empty: "no JSON value in the document"
        case .unexpectedByte(let offset): "unexpected byte at \(offset)"
        case .unexpectedEnd: "document ended in the middle of a value"
        case .invalidNumber(let offset): "malformed number at \(offset)"
        case .invalidEscape(let offset): "unknown string escape at \(offset)"
        case .invalidUnicode(let offset): "malformed \\u escape at \(offset)"
        case .invalidUTF8(let offset): "string is not valid UTF-8 at \(offset)"
        case .trailingContent(let offset): "content after the top-level value at \(offset)"
        case .tooDeep(let offset): "nesting deeper than \(JSONParser.maximumDepth) at \(offset)"
        }
    }
}

/// A recursive-descent JSON reader.
///
/// Bounded on purpose. It parses hook payloads, which arrive from a socket any
/// local process can reach, so nesting is capped: recursion that follows the
/// input's own depth is an unbounded stack, and a stack overflow kills the
/// process past every `catch`.
public struct JSONParser {
    /// Deeper than any real hook payload — `tool_input` for an MCP tool is the
    /// worst case and stays in single digits — and shallow enough that the
    /// recursion cannot exhaust a thread's stack.
    public static let maximumDepth = 64

    private let bytes: [UInt8]
    private var offset = 0
    private var depth = 0

    private init(_ data: Data) {
        bytes = [UInt8](data)
    }

    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(data)
        parser.skipWhitespace()
        guard parser.offset < parser.bytes.count else { throw JSONParsingError.empty }
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.offset == parser.bytes.count else {
            throw JSONParsingError.trailingContent(offset: parser.offset)
        }
        return value
    }

    // MARK: - Values

    private mutating func parseValue() throws -> JSONValue {
        guard let byte = peek() else { throw JSONParsingError.unexpectedEnd }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"):
            try expect("true")
            return .bool(true)
        case UInt8(ascii: "f"):
            try expect("false")
            return .bool(false)
        case UInt8(ascii: "n"):
            try expect("null")
            return .null
        default: return try parseNumber()
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        offset += 1
        var object = JSONObject()
        skipWhitespace()
        if peek() == UInt8(ascii: "}") {
            offset += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else {
                throw JSONParsingError.unexpectedByte(offset: offset)
            }
            let key = try parseString()
            skipWhitespace()
            try consume(UInt8(ascii: ":"))
            skipWhitespace()
            object[key] = try parseValue()
            skipWhitespace()
            guard let byte = peek() else { throw JSONParsingError.unexpectedEnd }
            if byte == UInt8(ascii: ",") {
                offset += 1
                continue
            }
            if byte == UInt8(ascii: "}") {
                offset += 1
                return .object(object)
            }
            throw JSONParsingError.unexpectedByte(offset: offset)
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        offset += 1
        var elements: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") {
            offset += 1
            return .array(elements)
        }
        while true {
            skipWhitespace()
            elements.append(try parseValue())
            skipWhitespace()
            guard let byte = peek() else { throw JSONParsingError.unexpectedEnd }
            if byte == UInt8(ascii: ",") {
                offset += 1
                continue
            }
            if byte == UInt8(ascii: "]") {
                offset += 1
                return .array(elements)
            }
            throw JSONParsingError.unexpectedByte(offset: offset)
        }
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = offset
        if peek() == UInt8(ascii: "-") { offset += 1 }
        // JSON has no leading zeros, and accepting them would let `08` through
        // as a number this writer would then render back unchanged.
        let firstDigit = offset
        try consumeDigits(from: start)
        if bytes[firstDigit] == UInt8(ascii: "0"), offset - firstDigit > 1 {
            throw JSONParsingError.invalidNumber(offset: start)
        }
        if peek() == UInt8(ascii: ".") {
            offset += 1
            try consumeDigits(from: start)
        }
        if peek() == UInt8(ascii: "e") || peek() == UInt8(ascii: "E") {
            offset += 1
            if peek() == UInt8(ascii: "+") || peek() == UInt8(ascii: "-") { offset += 1 }
            try consumeDigits(from: start)
        }
        guard let text = String(bytes: bytes[start..<offset], encoding: .utf8), !text.isEmpty
        else {
            throw JSONParsingError.invalidNumber(offset: start)
        }
        return .number(text)
    }

    private mutating func consumeDigits(from start: Int) throws {
        let before = offset
        while let byte = peek(), byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") {
            offset += 1
        }
        guard offset > before else { throw JSONParsingError.invalidNumber(offset: start) }
    }

    private mutating func parseString() throws -> String {
        offset += 1
        var scalars = String.UnicodeScalarView()
        var literal: [UInt8] = []

        func flushLiteral() throws {
            guard !literal.isEmpty else { return }
            guard let text = String(bytes: literal, encoding: .utf8) else {
                throw JSONParsingError.invalidUTF8(offset: offset)
            }
            scalars.append(contentsOf: text.unicodeScalars)
            literal.removeAll(keepingCapacity: true)
        }

        while true {
            guard let byte = peek() else { throw JSONParsingError.unexpectedEnd }
            switch byte {
            case UInt8(ascii: "\""):
                offset += 1
                try flushLiteral()
                return String(scalars)
            case UInt8(ascii: "\\"):
                try flushLiteral()
                offset += 1
                scalars.append(contentsOf: try parseEscape())
            case 0x00...0x1F:
                throw JSONParsingError.unexpectedByte(offset: offset)
            default:
                literal.append(byte)
                offset += 1
            }
        }
    }

    /// The escape after the backslash, as scalars: a `\u` pair for a character
    /// outside the basic plane produces one scalar from two escapes.
    private mutating func parseEscape() throws -> String.UnicodeScalarView {
        guard let byte = peek() else { throw JSONParsingError.unexpectedEnd }
        offset += 1
        var scalars = String.UnicodeScalarView()
        switch byte {
        case UInt8(ascii: "\""): scalars.append("\"")
        case UInt8(ascii: "\\"): scalars.append("\\")
        case UInt8(ascii: "/"): scalars.append("/")
        case UInt8(ascii: "b"): scalars.append(Unicode.Scalar(0x08))
        case UInt8(ascii: "f"): scalars.append(Unicode.Scalar(0x0C))
        case UInt8(ascii: "n"): scalars.append("\n")
        case UInt8(ascii: "r"): scalars.append("\r")
        case UInt8(ascii: "t"): scalars.append("\t")
        case UInt8(ascii: "u"):
            let first = try parseHexQuad()
            if first >= 0xD800, first <= 0xDBFF {
                // A high surrogate is only half a character. Its partner must
                // follow, or the document is malformed rather than merely odd.
                guard peek() == UInt8(ascii: "\\"), peek(1) == UInt8(ascii: "u") else {
                    throw JSONParsingError.invalidUnicode(offset: offset)
                }
                offset += 2
                let second = try parseHexQuad()
                guard second >= 0xDC00, second <= 0xDFFF else {
                    throw JSONParsingError.invalidUnicode(offset: offset)
                }
                let combined = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
                guard let scalar = Unicode.Scalar(combined) else {
                    throw JSONParsingError.invalidUnicode(offset: offset)
                }
                scalars.append(scalar)
            } else {
                guard let scalar = Unicode.Scalar(first) else {
                    throw JSONParsingError.invalidUnicode(offset: offset)
                }
                scalars.append(scalar)
            }
        default:
            throw JSONParsingError.invalidEscape(offset: offset - 1)
        }
        return scalars
    }

    private mutating func parseHexQuad() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = peek(), let digit = JSONParser.hexDigit(byte) else {
                throw JSONParsingError.invalidUnicode(offset: offset)
            }
            value = value << 4 | UInt32(digit)
            offset += 1
        }
        return value
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    // MARK: - Scanning

    private mutating func enter() throws {
        depth += 1
        guard depth <= JSONParser.maximumDepth else {
            throw JSONParsingError.tooDeep(offset: offset)
        }
    }

    private func peek(_ ahead: Int = 0) -> UInt8? {
        let index = offset + ahead
        return index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = peek(), byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            offset += 1
        }
    }

    private mutating func consume(_ byte: UInt8) throws {
        guard peek() == byte else { throw JSONParsingError.unexpectedByte(offset: offset) }
        offset += 1
    }

    private mutating func expect(_ literal: String) throws {
        for byte in literal.utf8 {
            guard peek() == byte else { throw JSONParsingError.unexpectedByte(offset: offset) }
            offset += 1
        }
    }
}
