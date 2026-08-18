import Foundation

/// The request line and headers of one HTTP/1.1 request.
struct HTTPRequestHead: Sendable, Hashable {
    let method: String
    let path: String
    let query: String?
    let version: String
    let headers: HTTPHeaders

    /// Whether the client asked to be told to go ahead before sending a body.
    ///
    /// Answering matters more than it looks: a client that waits for `100
    /// Continue` and never gets one stalls until its own timeout, and that
    /// timeout is inside an agent's tool call.
    var expectsContinue: Bool {
        headers["expect"]?.lowercased().contains("100-continue") ?? false
    }

    /// Whether the connection should stay open after this request.
    var keepsAlive: Bool {
        let connection = headers["connection"]?.lowercased()
        if version == "HTTP/1.0" { return connection?.contains("keep-alive") ?? false }
        return !(connection?.contains("close") ?? false)
    }
}

/// Why a request could not be read, and the status it is answered with.
///
/// Every case here is a fault in the request rather than in AgentBar, which is
/// why they carry 4xx: the caller sent something unreadable, and saying so is
/// more useful than pretending to have understood it. A body we can read but
/// cannot decode is the opposite case and never reaches this type — see
/// `EventIngestHandler`.
public enum HTTPParseError: Error, Sendable, Hashable, CustomStringConvertible {
    case requestLineTooLong
    case headTooLarge
    case tooManyHeaders
    case malformedRequestLine
    case unsupportedVersion(String)
    case malformedHeader
    case obsoleteLineFolding
    case conflictingContentLength
    case ambiguousBodyFraming
    case unsupportedTransferEncoding(String)
    case malformedChunk
    case bodyTooLarge(declared: Int?)

    var status: IngestStatus {
        switch self {
        case .requestLineTooLong: .uriTooLong
        case .headTooLarge, .tooManyHeaders: .headerFieldsTooLarge
        case .bodyTooLarge: .payloadTooLarge
        default: .badRequest
        }
    }

    public var description: String {
        switch self {
        case .requestLineTooLong: "request line too long"
        case .headTooLarge: "request head too large"
        case .tooManyHeaders: "too many headers"
        case .malformedRequestLine: "malformed request line"
        case .unsupportedVersion(let version): "unsupported HTTP version \(version)"
        case .malformedHeader: "malformed header"
        case .obsoleteLineFolding: "obsolete header line folding"
        case .conflictingContentLength: "conflicting Content-Length headers"
        case .ambiguousBodyFraming: "both Content-Length and Transfer-Encoding"
        case .unsupportedTransferEncoding(let encoding): "unsupported Transfer-Encoding \(encoding)"
        case .malformedChunk: "malformed chunked body"
        case .bodyTooLarge(let declared):
            declared.map { "body of \($0) bytes exceeds the limit" } ?? "body exceeds the limit"
        }
    }
}

/// Reads HTTP/1.1 requests out of a byte stream.
///
/// Hand-rolled rather than adopted, and that is the cheaper side of the trade.
/// The platform ships no HTTP *server*, so the alternative is a package
/// dependency — and ADR-0002's guarantee that no remote HTTP client exists in
/// the dependency graph is much easier to keep when the graph has nothing in it.
/// What has to be handled is one shape of request from two clients that both
/// speak HTTP correctly, and the parser's real job is refusing everything else
/// in bounded memory.
///
/// Strict about framing on purpose. Two `Content-Length` headers that disagree,
/// or a `Content-Length` next to a `Transfer-Encoding`, are refused rather than
/// resolved: those are the ambiguities request smuggling is built out of, and
/// nothing that legitimately talks to AgentBar produces them.
struct HTTPRequestParser {
    private enum Phase {
        case head
        case fixedBody(HTTPRequestHead, expected: Int)
        case chunkedBody(HTTPRequestHead, ChunkedBodyDecoder)
    }

    private static let crlf: [UInt8] = [0x0D, 0x0A]
    private static let headTerminator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]

    private let limits: IngestLimits
    private var buffer = ByteBuffer()
    private var phase = Phase.head

    init(limits: IngestLimits) {
        self.limits = limits
    }

    /// True once a head has been read and only its body is outstanding — the
    /// point at which `100 Continue` is owed, if it was asked for.
    var awaitingBody: HTTPRequestHead? {
        switch phase {
        case .head: nil
        case .fixedBody(let head, _): head
        case .chunkedBody(let head, _): head
        }
    }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    /// The next complete request, or `nil` while more bytes are needed.
    ///
    /// Called in a loop after every read, so a client that pipelines two
    /// requests into one packet has both handled rather than one stranded.
    mutating func next() throws -> (head: HTTPRequestHead, body: Data)? {
        while true {
            switch phase {
            case .head:
                guard let head = try readHead() else { return nil }
                switch try framing(of: head) {
                case .empty:
                    return (head, Data())
                case .fixed(let expected):
                    phase = .fixedBody(head, expected: expected)
                case .chunked:
                    phase = .chunkedBody(head, ChunkedBodyDecoder())
                }
            case .fixedBody(let head, let expected):
                guard buffer.readableBytes >= expected else { return nil }
                phase = .head
                return (head, buffer.take(expected))
            case .chunkedBody(let head, let decoder):
                var progress = decoder
                let complete = try progress.consume(
                    from: &buffer, limit: limits.maximumBodyBytes)
                guard complete else {
                    phase = .chunkedBody(head, progress)
                    return nil
                }
                phase = .head
                return (head, progress.body)
            }
        }
    }

    // MARK: - Head

    private mutating func readHead() throws -> HTTPRequestHead? {
        let searchLimit = limits.maximumHeadBytes + HTTPRequestParser.headTerminator.count
        guard
            let terminator = buffer.offset(
                ofFirst: HTTPRequestParser.headTerminator, searchingAtMost: searchLimit)
        else {
            guard buffer.readableBytes <= limits.maximumHeadBytes else {
                throw HTTPParseError.headTooLarge
            }
            return nil
        }
        guard terminator <= limits.maximumHeadBytes else { throw HTTPParseError.headTooLarge }
        let headBytes = buffer.take(terminator)
        buffer.discard(HTTPRequestParser.headTerminator.count)
        return try HTTPRequestParser.parseHead(headBytes, limits: limits)
    }

    static func parseHead(_ data: Data, limits: IngestLimits) throws -> HTTPRequestHead {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HTTPParseError.malformedHeader
        }
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw HTTPParseError.malformedRequestLine }
        let requestLine = lines.removeFirst()
        guard requestLine.utf8.count <= limits.maximumRequestLineBytes else {
            throw HTTPParseError.requestLineTooLong
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw HTTPParseError.malformedRequestLine
        }
        let version = String(parts[2])
        guard version == "HTTP/1.1" || version == "HTTP/1.0" else {
            throw HTTPParseError.unsupportedVersion(version)
        }

        let target = String(parts[1])
        let separator = target.firstIndex(of: "?")
        let path = separator.map { String(target[target.startIndex..<$0]) } ?? target
        let query = separator.map { String(target[target.index(after: $0)...]) }

        guard lines.count <= limits.maximumHeaderCount else { throw HTTPParseError.tooManyHeaders }
        var headers = HTTPHeaders()
        for line in lines where !line.isEmpty {
            // A leading space is a continuation of the previous header, a form
            // removed from HTTP/1.1 precisely because parsers disagreed on it.
            guard !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                throw HTTPParseError.obsoleteLineFolding
            }
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformedHeader }
            let name = String(line[line.startIndex..<colon])
            guard !name.isEmpty, !name.contains(" ") else { throw HTTPParseError.malformedHeader }
            let value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)
            headers.append(name: name, value: value)
        }

        return HTTPRequestHead(
            method: String(parts[0]).uppercased(), path: path, query: query, version: version,
            headers: headers)
    }

    // MARK: - Body framing

    private enum Framing {
        case empty
        case fixed(Int)
        case chunked
    }

    private func framing(of head: HTTPRequestHead) throws -> Framing {
        let lengths = head.headers.values(for: "content-length")
        let encodings = head.headers.values(for: "transfer-encoding")

        if !encodings.isEmpty {
            guard lengths.isEmpty else { throw HTTPParseError.ambiguousBodyFraming }
            let last = encodings.last?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard last == "chunked" else {
                throw HTTPParseError.unsupportedTransferEncoding(last)
            }
            return .chunked
        }

        guard let declared = lengths.first else { return .empty }
        guard Set(lengths).count == 1 else { throw HTTPParseError.conflictingContentLength }
        guard let length = Int(declared), length >= 0 else { throw HTTPParseError.malformedHeader }
        guard length <= limits.maximumBodyBytes else {
            throw HTTPParseError.bodyTooLarge(declared: length)
        }
        return length == 0 ? .empty : .fixed(length)
    }
}
