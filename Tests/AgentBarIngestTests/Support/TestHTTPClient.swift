import Foundation
import Network

@testable import AgentBarIngest

/// A client that writes bytes, not requests.
///
/// `URLSession` would be the shorter way to make a well-formed request and the
/// wrong tool for this suite: half of what the endpoint has to get right is how
/// it answers requests no correct client would ever send — a body split across
/// packets, two `Content-Length` headers, a chunk size that is not hexadecimal.
/// A well-behaved client cannot produce any of those. Keeping the test client at
/// the byte level also keeps `URLSession` out of the package entirely, which is
/// one fewer way for a remote HTTP client to appear in the dependency graph.
final class TestHTTPClient {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    enum ClientError: Error {
        case closedEarly
        case malformedResponse
        case invalidPort(UInt16)
    }

    private let channel: IngestChannel
    private var pending = Data()

    private init(_ connection: NWConnection) {
        channel = IngestChannel(connection)
    }

    static func loopback(port: UInt16) throws -> TestHTTPClient {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ClientError.invalidPort(port)
        }
        return TestHTTPClient(
            NWConnection(to: .hostPort(host: .ipv4(.loopback), port: endpointPort), using: .tcp))
    }

    static func unixSocket(path: String) -> TestHTTPClient {
        TestHTTPClient(NWConnection(to: .unix(path: path), using: .tcp))
    }

    /// Connects to an arbitrary host, so a test can prove an address is *not*
    /// reachable.
    static func host(_ host: String, port: UInt16) throws -> TestHTTPClient {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw ClientError.invalidPort(port)
        }
        return TestHTTPClient(
            NWConnection(
                to: .hostPort(host: NWEndpoint.Host(host), port: endpointPort), using: .tcp)
        )
    }

    func open() async throws {
        try await channel.start(on: DispatchQueue(label: "test-client"))
    }

    func write(_ text: String) async throws {
        try await channel.send(Data(text.utf8))
    }

    func write(_ data: Data) async throws {
        try await channel.send(data)
    }

    func close() {
        channel.close()
    }

    /// Reads one response, transparently skipping a `100 Continue`.
    func readResponse() async throws -> Response {
        while true {
            let response = try await readOneResponse()
            guard response.status == 100 else { return response }
        }
    }

    private func readOneResponse() async throws -> Response {
        let head = try await readHead()
        let lines = head.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { throw ClientError.malformedResponse }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw ClientError.malformedResponse
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where line.contains(":") {
            let parts = line.split(separator: ":", maxSplits: 1)
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        while pending.count < length {
            guard let more = try await channel.receive(maximumLength: 65536) else {
                throw ClientError.closedEarly
            }
            pending.append(more)
        }
        let body = pending.prefix(length)
        pending = Data(pending.dropFirst(length))
        return Response(status: status, headers: headers, body: Data(body))
    }

    private func readHead() async throws -> String {
        let terminator = Data("\r\n\r\n".utf8)
        while true {
            if let range = pending.range(of: terminator) {
                let head = pending[pending.startIndex..<range.lowerBound]
                pending = Data(pending[range.upperBound...])
                guard let text = String(data: Data(head), encoding: .utf8) else {
                    throw ClientError.malformedResponse
                }
                return text
            }
            guard let more = try await channel.receive(maximumLength: 65536) else {
                throw ClientError.closedEarly
            }
            pending.append(more)
        }
    }

    /// A well-formed request, which is what most tests want.
    static func request(
        method: String = "POST",
        path: String,
        token: String?,
        body: String = "",
        extraHeaders: [(String, String)] = [],
        keepAlive: Bool = true
    ) -> String {
        var text = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n"
        if let token { text += "Authorization: Bearer \(token)\r\n" }
        if !keepAlive { text += "Connection: close\r\n" }
        for header in extraHeaders { text += "\(header.0): \(header.1)\r\n" }
        text += "Content-Length: \(body.utf8.count)\r\n"
        text += "Content-Type: application/json\r\n\r\n"
        text += body
        return text
    }
}
