import Foundation

/// Turns a response into the bytes that go back down the socket.
///
/// Minimal on purpose. A hook client reads a status, a length and a body;
/// anything else we volunteered would be one more thing that could be wrong on
/// a path where being invisible is the requirement.
enum HTTPResponseWriter {
    /// The interim answer owed to a client that sent `Expect: 100-continue`.
    ///
    /// Without it such a client waits for its own timeout before sending the
    /// body — a stall inside an agent's tool call, caused by us.
    static let continueResponse = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    static func bytes(for response: IngestResponse, keepAlive: Bool) -> Data {
        var head = "HTTP/1.1 \(response.status.rawValue) \(response.status.reasonPhrase)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        // Nothing here is ever worth storing, and a proxy has no business
        // between two processes on one machine in any case.
        head += "Cache-Control: no-store\r\n"
        if let contentType = response.contentType {
            head += "Content-Type: \(contentType)\r\n"
        }
        head += "\r\n"
        var bytes = Data(head.utf8)
        bytes.append(response.body)
        return bytes
    }
}
