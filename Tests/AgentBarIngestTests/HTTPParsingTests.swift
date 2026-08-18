import Foundation
import Testing

@testable import AgentBarIngest

@Suite("Byte buffer")
struct ByteBufferTests {

    @Test("Reads back what was appended, across several appends")
    func accumulates() {
        var buffer = ByteBuffer()
        buffer.append(Data("abc".utf8))
        buffer.append(Data("def".utf8))
        #expect(buffer.readableBytes == 6)
        #expect(String(data: buffer.take(4), encoding: .utf8) == "abcd")
        #expect(buffer.readableBytes == 2)
        #expect(String(data: buffer.take(2), encoding: .utf8) == "ef")
        #expect(buffer.isEmpty)
    }

    @Test("Finds a needle relative to the cursor, not to the start")
    func searchesFromCursor() {
        var buffer = ByteBuffer(Data("xx\r\nyy\r\n".utf8))
        let crlf: [UInt8] = [0x0D, 0x0A]
        #expect(buffer.offset(ofFirst: crlf, searchingAtMost: 64) == 2)
        buffer.discard(4)
        #expect(buffer.offset(ofFirst: crlf, searchingAtMost: 64) == 2)
    }

    @Test("Refuses to look past the search limit")
    func honoursSearchLimit() {
        let buffer = ByteBuffer(Data("aaaaa\r\n".utf8))
        #expect(buffer.offset(ofFirst: [0x0D, 0x0A], searchingAtMost: 4) == nil)
        #expect(buffer.offset(ofFirst: [0x0D, 0x0A], searchingAtMost: 7) == 5)
    }

    @Test("Taking more than is readable takes what there is")
    func clampsToReadable() {
        var buffer = ByteBuffer(Data("ab".utf8))
        #expect(buffer.take(10).count == 2)
        #expect(buffer.isEmpty)
    }

    /// A keep-alive connection feeds one buffer for its whole life, so consumed
    /// bytes have to be reclaimed or a long-lived connection grows without bound.
    @Test("Reclaims consumed bytes without disturbing the unread ones")
    func compacts() {
        var buffer = ByteBuffer()
        for _ in 0..<40 {
            buffer.append(Data(repeating: 0x41, count: 4096))
            buffer.discard(4096)
        }
        buffer.append(Data("tail".utf8))
        #expect(buffer.readableBytes == 4)
        #expect(String(data: buffer.take(4), encoding: .utf8) == "tail")
    }
}

@Suite("HTTP request parsing")
struct HTTPRequestParserTests {
    static let limits = IngestLimits()

    private func parser() -> HTTPRequestParser {
        HTTPRequestParser(limits: HTTPRequestParserTests.limits)
    }

    @Test("Reads a well-formed POST")
    func readsPost() throws {
        var parser = parser()
        parser.append(
            Data(
                "POST /v1/events?x=1 HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\nhello".utf8))
        let request = try #require(try parser.next())
        #expect(request.head.method == "POST")
        #expect(request.head.path == "/v1/events")
        #expect(request.head.query == "x=1")
        #expect(String(data: request.body, encoding: .utf8) == "hello")
    }

    @Test("A request split across reads is assembled")
    func assemblesAcrossReads() throws {
        var parser = parser()
        let whole = Array("POST /v1/events HTTP/1.1\r\nContent-Length: 9\r\n\r\n{\"a\": 1}!".utf8)
        for byte in whole.dropLast() {
            parser.append(Data([byte]))
            #expect(try parser.next() == nil)
        }
        parser.append(Data([whole[whole.count - 1]]))
        let request = try #require(try parser.next())
        #expect(request.body.count == 9)
    }

    @Test("Two requests in one packet are both read")
    func readsPipelined() throws {
        var parser = parser()
        let one = "POST /a HTTP/1.1\r\nContent-Length: 1\r\n\r\nx"
        let two = "POST /b HTTP/1.1\r\nContent-Length: 1\r\n\r\ny"
        parser.append(Data((one + two).utf8))
        #expect(try parser.next()?.head.path == "/a")
        #expect(try parser.next()?.head.path == "/b")
        #expect(try parser.next() == nil)
    }

    @Test("A request with no body framing has an empty body")
    func readsBodyless() throws {
        var parser = parser()
        parser.append(Data("GET /v1/health HTTP/1.1\r\nHost: h\r\n\r\n".utf8))
        let request = try #require(try parser.next())
        #expect(request.head.method == "GET")
        #expect(request.body.isEmpty)
    }

    @Test("Header names are matched without regard to case")
    func matchesHeadersCaseInsensitively() throws {
        var parser = parser()
        parser.append(Data("GET /x HTTP/1.1\r\nAUTHORIZATION: Bearer t\r\n\r\n".utf8))
        let request = try #require(try parser.next())
        #expect(request.head.headers["authorization"] == "Bearer t")
        #expect(request.head.headers["Authorization"] == "Bearer t")
    }

    @Test(
        "Refuses a request it cannot frame unambiguously",
        arguments: [
            (
                "POST /x HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\nabc",
                HTTPParseError.conflictingContentLength
            ),
            (
                "POST /x HTTP/1.1\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\nabc",
                HTTPParseError.ambiguousBodyFraming
            ),
            (
                "POST /x HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n",
                HTTPParseError.unsupportedTransferEncoding("gzip")
            ),
            (
                "POST /x HTTP/1.1\r\nA: 1\r\n B: 2\r\n\r\n",
                HTTPParseError.obsoleteLineFolding
            ),
            ("POST /x\r\n\r\n", HTTPParseError.malformedRequestLine),
            ("POST /x HTTP/2\r\n\r\n", HTTPParseError.unsupportedVersion("HTTP/2")),
            ("POST /x HTTP/1.1\r\nnocolon\r\n\r\n", HTTPParseError.malformedHeader),
            (
                "POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
                HTTPParseError.malformedHeader
            ),
        ]
    )
    func refusesAmbiguousFraming(source: String, expected: HTTPParseError) {
        var parser = parser()
        parser.append(Data(source.utf8))
        #expect(throws: expected) { try parser.next() }
    }

    @Test("Refuses a declared body larger than the limit")
    func refusesOversizedBody() {
        var parser = HTTPRequestParser(limits: IngestLimits(maximumBodyBytes: 8))
        parser.append(Data("POST /x HTTP/1.1\r\nContent-Length: 9\r\n\r\n".utf8))
        #expect(throws: HTTPParseError.bodyTooLarge(declared: 9)) { try parser.next() }
    }

    @Test("Refuses a head larger than the limit without buffering all of it")
    func refusesOversizedHead() {
        var parser = HTTPRequestParser(limits: IngestLimits(maximumHeadBytes: 128))
        parser.append(Data("POST /x HTTP/1.1\r\n".utf8))
        parser.append(Data("X-Pad: \(String(repeating: "p", count: 400))\r\n".utf8))
        #expect(throws: HTTPParseError.headTooLarge) { try parser.next() }
    }

    @Test("Refuses more headers than the limit allows")
    func refusesTooManyHeaders() {
        var parser = HTTPRequestParser(limits: IngestLimits(maximumHeaderCount: 3))
        let headers = (0..<8).map { "H\($0): v\r\n" }.joined()
        parser.append(Data("POST /x HTTP/1.1\r\n\(headers)\r\n".utf8))
        #expect(throws: HTTPParseError.tooManyHeaders) { try parser.next() }
    }

    @Test("Refuses a request line longer than the limit")
    func refusesLongRequestLine() {
        var parser = HTTPRequestParser(limits: IngestLimits(maximumRequestLineBytes: 32))
        parser.append(Data("POST /\(String(repeating: "p", count: 64)) HTTP/1.1\r\n\r\n".utf8))
        #expect(throws: HTTPParseError.requestLineTooLong) { try parser.next() }
    }

    @Test("Keep-alive follows the version and the Connection header")
    func decidesKeepAlive() throws {
        func head(_ source: String) throws -> HTTPRequestHead {
            var parser = parser()
            parser.append(Data(source.utf8))
            return try #require(try parser.next()).head
        }
        #expect(try head("GET /x HTTP/1.1\r\n\r\n").keepsAlive)
        #expect(try !head("GET /x HTTP/1.1\r\nConnection: close\r\n\r\n").keepsAlive)
        #expect(try !head("GET /x HTTP/1.0\r\n\r\n").keepsAlive)
        #expect(try head("GET /x HTTP/1.0\r\nConnection: keep-alive\r\n\r\n").keepsAlive)
    }

    @Test("Notices a client waiting to be told to continue")
    func detectsExpectContinue() throws {
        var parser = parser()
        parser.append(
            Data(
                "POST /x HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n".utf8))
        #expect(try parser.next() == nil)
        let awaited = try #require(parser.awaitingBody)
        #expect(awaited.expectsContinue)
        parser.append(Data("abcd".utf8))
        #expect(try parser.next()?.body.count == 4)
    }
}

@Suite("Chunked bodies")
struct ChunkedBodyTests {

    private func parse(_ source: String, limits: IngestLimits = IngestLimits()) throws -> Data? {
        var parser = HTTPRequestParser(limits: limits)
        parser.append(Data(source.utf8))
        return try parser.next()?.body
    }

    @Test("Reassembles chunks in order")
    func reassembles() throws {
        let body = try parse(
            "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
                + "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
        #expect(String(data: try #require(body), encoding: .utf8) == "hello world")
    }

    @Test("Ignores a chunk extension and reads trailers")
    func toleratesExtensionsAndTrailers() throws {
        let body = try parse(
            "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
                + "3;name=value\r\nabc\r\n0\r\nX-Trailer: 1\r\n\r\n")
        #expect(String(data: try #require(body), encoding: .utf8) == "abc")
    }

    @Test("A chunked body split across reads is assembled")
    func assemblesAcrossReads() throws {
        var parser = HTTPRequestParser(limits: IngestLimits())
        parser.append(Data("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nab".utf8))
        #expect(try parser.next() == nil)
        parser.append(Data("\r\n0\r\n\r\n".utf8))
        #expect(String(data: try #require(try parser.next()).body, encoding: .utf8) == "ab")
    }

    @Test("Refuses a chunk size that is not hexadecimal")
    func refusesBadSize() {
        #expect(throws: HTTPParseError.malformedChunk) {
            try parse("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nab\r\n0\r\n\r\n")
        }
    }

    @Test("Refuses a chunk not followed by its terminator")
    func refusesMissingTerminator() {
        #expect(throws: HTTPParseError.malformedChunk) {
            try parse("POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nabXX0\r\n\r\n")
        }
    }

    /// A chunk size is whatever the caller wrote, and the obvious spelling of
    /// the limit check — `body.count + size <= limit` — overflows on `Int.max`.
    /// An overflow in Swift is a trap, not an error, so this arrived as an
    /// unauthenticated process kill: the body is framed before the router ever
    /// looks at the token.
    @Test(
        "Refuses an enormous chunk size instead of trapping on it",
        arguments: ["7fffffffffffffff", "7ffffffffffffffe", "fffffffffffffff"]
    )
    func refusesEnormousChunkSize(size: String) {
        #expect(throws: HTTPParseError.self) {
            try parse(
                "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
                    + "1\r\nA\r\n\(size)\r\n")
        }
    }

    /// The first chunk is what makes it overflow rather than merely exceed:
    /// with an empty body the addition still fits.
    @Test("Refuses an enormous chunk size as the very first chunk too")
    func refusesEnormousFirstChunk() {
        #expect(throws: HTTPParseError.self) {
            try parse(
                "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\n")
        }
    }

    /// The fixed-length path refuses an oversized body from its header. Chunked
    /// declares nothing up front, so the same ceiling has to be enforced as the
    /// bytes arrive or it is not enforced at all.
    @Test("Refuses a chunked body that grows past the limit")
    func refusesOversizedChunkedBody() {
        #expect(throws: HTTPParseError.bodyTooLarge(declared: nil)) {
            try parse(
                "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
                    + "4\r\nabcd\r\n4\r\nefgh\r\n0\r\n\r\n",
                limits: IngestLimits(maximumBodyBytes: 6))
        }
    }
}
