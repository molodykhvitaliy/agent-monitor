import Foundation

/// Reassembles a `Transfer-Encoding: chunked` body.
///
/// Neither client is known to chunk today — both send a `Content-Length` — so
/// this is defence against a client that changes, not a feature anyone asked
/// for. It earns its place because of how the alternative fails: a parser that
/// does not understand chunking refuses the request, and a refused request is a
/// silently missing heartbeat that makes a working session read as quiet. Every
/// bound the fixed-length path has, this one has too.
struct ChunkedBodyDecoder: Sendable, Hashable {
    /// A chunk-size line or a trailer is a few dozen bytes. Anything longer is
    /// a peer buffering into us rather than talking to us.
    private static let maximumControlLineBytes = 1024
    private static let maximumTrailerLines = 32
    private static let crlf: [UInt8] = [0x0D, 0x0A]

    private enum Step: Sendable, Hashable {
        case size
        case data(remaining: Int)
        case dataTerminator
        case trailer(seen: Int)
        case done
    }

    private var step = Step.size
    private(set) var body = Data()

    /// Consumes what it can, returning true once the body is complete.
    mutating func consume(from buffer: inout ByteBuffer, limit: Int) throws -> Bool {
        while true {
            switch step {
            case .size:
                guard let line = try ChunkedBodyDecoder.readLine(from: &buffer) else {
                    return false
                }
                let size = try ChunkedBodyDecoder.chunkSize(of: line)
                // Subtraction, never addition. A chunk size is whatever the
                // caller wrote, up to `Int.max`, and `body.count + size` on that
                // input overflows — which in Swift is a trap, not an error, so
                // it would kill the process from an unauthenticated request
                // rather than degrade to no opinion. `body.count` never exceeds
                // `limit`, so the difference cannot underflow.
                guard size <= limit - body.count else {
                    throw HTTPParseError.bodyTooLarge(declared: nil)
                }
                step = size == 0 ? .trailer(seen: 0) : .data(remaining: size)
            case .data(let remaining):
                guard buffer.readableBytes >= remaining else { return false }
                body.append(buffer.take(remaining))
                step = .dataTerminator
            case .dataTerminator:
                guard let line = try ChunkedBodyDecoder.readLine(from: &buffer) else {
                    return false
                }
                guard line.isEmpty else { throw HTTPParseError.malformedChunk }
                step = .size
            case .trailer(let seen):
                guard let line = try ChunkedBodyDecoder.readLine(from: &buffer) else {
                    return false
                }
                guard !line.isEmpty else {
                    step = .done
                    continue
                }
                guard seen < ChunkedBodyDecoder.maximumTrailerLines else {
                    throw HTTPParseError.malformedChunk
                }
                step = .trailer(seen: seen + 1)
            case .done:
                return true
            }
        }
    }

    /// The size field, ignoring any chunk extension after a semicolon.
    private static func chunkSize(of line: String) throws -> Int {
        let field = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
        guard let size = Int(field.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0
        else {
            throw HTTPParseError.malformedChunk
        }
        return size
    }

    private static func readLine(from buffer: inout ByteBuffer) throws -> String? {
        guard
            let index = buffer.offset(
                ofFirst: crlf, searchingAtMost: maximumControlLineBytes + crlf.count)
        else {
            guard buffer.readableBytes <= maximumControlLineBytes else {
                throw HTTPParseError.malformedChunk
            }
            return nil
        }
        let line = buffer.take(index)
        buffer.discard(crlf.count)
        guard let text = String(data: line, encoding: .utf8) else {
            throw HTTPParseError.malformedChunk
        }
        return text
    }
}
