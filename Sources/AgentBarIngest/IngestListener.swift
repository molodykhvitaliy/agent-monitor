import Foundation
import Network
import Synchronization

public enum IngestTransportError: Error, Sendable, Hashable, CustomStringConvertible {
    case noPortAvailable(tried: [UInt16])
    case socketPathTooLong(bytes: Int)
    case socketInUse(path: String)
    case listenerFailed(reason: String)
    case notLoopback(endpoint: String)

    public var description: String {
        switch self {
        case .noPortAvailable(let tried):
            "every candidate port is in use: \(tried.map(String.init).joined(separator: ", "))"
        case .socketPathTooLong(let bytes):
            "socket path is \(bytes) bytes, over the \(IngestPaths.maximumSocketPathBytes) allowed"
        case .socketInUse(let path):
            "another process is already listening on \(path)"
        case .listenerFailed(let reason):
            "listener failed: \(reason)"
        case .notLoopback(let endpoint):
            "refusing to serve a non-loopback endpoint: \(endpoint)"
        }
    }
}

/// Binds the two listeners the endpoint serves on.
///
/// Three things here were established by experiment rather than from the
/// documentation, and each would have been a silent failure:
///
/// - `newConnectionHandler` must be set **before** `start(queue:)`, or the bind
///   fails with `EINVAL` and reads like a bad address.
/// - A Unix listener does not remove its socket file when it is cancelled, and
///   binding over a leftover file fails with `EADDRINUSE` exactly as if the
///   endpoint were live. The two are told apart by connecting: a socket nobody
///   is listening on refuses with `ECONNREFUSED`.
/// - A listener on `127.0.0.1` is not reachable on `::1`, which is refused, nor
///   on any other local address. That is the loopback-only guarantee, and it is
///   also why every URL AgentBar writes names the address literally.
enum IngestListener {
    /// Binds the first free port in the ladder.
    static func loopback(
        candidates: [UInt16],
        diagnostics: any IngestDiagnosticSink,
        accept: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> (listener: NWListener, port: UInt16) {
        for port in candidates {
            guard let endpointPort = NWEndpoint.Port(rawValue: port) else { continue }
            let parameters = NWParameters.tcp
            // Never `allowLocalEndpointReuse`: two AgentBars sharing one port
            // would split an agent's events between them at random. Address
            // already in use is the answer this ladder is built on.
            parameters.requiredLocalEndpoint = .hostPort(
                host: .ipv4(.loopback), port: endpointPort)
            guard let listener = try? NWListener(using: parameters) else { continue }
            do {
                try await bind(listener, accept: accept)
            } catch let failure as BindFailure {
                guard failure.isAddressInUse else {
                    throw IngestTransportError.listenerFailed(reason: failure.reason)
                }
                diagnostics.record(.portUnavailable(port))
                continue
            }
            try verifyLoopback(parameters.requiredLocalEndpoint)
            return (listener, port)
        }
        throw IngestTransportError.noPortAvailable(tried: candidates)
    }

    /// Binds the helper's Unix socket, clearing a socket an earlier run left.
    static func unixSocket(
        at url: URL,
        diagnostics: any IngestDiagnosticSink,
        accept: @escaping @Sendable (NWConnection) -> Void
    ) async throws -> NWListener {
        let path = url.path(percentEncoded: false)
        let byteCount = path.utf8.count
        guard byteCount <= IngestPaths.maximumSocketPathBytes else {
            throw IngestTransportError.socketPathTooLong(bytes: byteCount)
        }
        try clearStaleSocket(at: path, diagnostics: diagnostics)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: path)
        guard let listener = try? NWListener(using: parameters) else {
            throw IngestTransportError.listenerFailed(
                reason: "cannot create a listener for \(path)")
        }
        do {
            try await bind(listener, accept: accept)
        } catch let failure as BindFailure {
            throw IngestTransportError.listenerFailed(reason: failure.reason)
        }
        // The networking stack creates the socket with the process umask
        // applied, which on a default macOS account is world-connectable. The
        // `0700` directory above it is what makes the window between bind and
        // this chmod harmless.
        chmod(path, 0o600)
        return listener
    }

    /// Removes a socket file with nothing behind it, and refuses to touch one
    /// that still answers — taking that over would steal a live endpoint's
    /// traffic and leave both halves confused about who is serving.
    private static func clearStaleSocket(
        at path: String, diagnostics: any IngestDiagnosticSink
    ) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        if isAnybodyListening(at: path) {
            throw IngestTransportError.socketInUse(path: path)
        }
        try? FileManager.default.removeItem(atPath: path)
        diagnostics.record(.staleSocketRemoved(path))
    }

    private static func isAnybodyListening(at path: String) -> Bool {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = withUnsafeMutablePointer(to: &address.sun_path) { field in
            path.withCString { source in
                strlcpy(
                    UnsafeMutableRawPointer(field).assumingMemoryBound(to: CChar.self), source,
                    capacity)
            }
        }
        guard copied < capacity else { return false }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                connect(descriptor, rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }

    /// Defence in depth for the one property ADR-0002 rests on. The endpoint is
    /// built loopback-only by construction; this is what stops a future edit
    /// from making that untrue without anything noticing.
    static func verifyLoopback(_ endpoint: NWEndpoint?) throws {
        guard let endpoint else {
            throw IngestTransportError.notLoopback(endpoint: "unspecified")
        }
        switch endpoint {
        case .unix:
            return
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address) where address == .loopback: return
            case .ipv6(let address) where address == .loopback: return
            default: throw IngestTransportError.notLoopback(endpoint: "\(endpoint)")
            }
        default:
            throw IngestTransportError.notLoopback(endpoint: "\(endpoint)")
        }
    }

    private static func bind(
        _ listener: NWListener,
        accept: @escaping @Sendable (NWConnection) -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: VoidContinuation) in
            let box = Mutex<VoidContinuation?>(continuation)
            let settle: @Sendable ((any Error)?) -> Void = { error in
                let pending = box.withLock { current -> VoidContinuation? in
                    defer { current = nil }
                    return current
                }
                guard let pending else { return }
                if let error {
                    pending.resume(throwing: error)
                } else {
                    pending.resume()
                }
            }
            // Before `start`, not after: a listener started without one fails
            // to bind with EINVAL, which looks nothing like the cause.
            listener.newConnectionHandler = accept
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    settle(nil)
                case .failed(let error), .waiting(let error):
                    settle(BindFailure(error: error))
                case .cancelled:
                    settle(CancellationError())
                default:
                    break
                }
            }
            listener.start(queue: IngestListener.queue)
        }
    }

    static let queue = DispatchQueue(
        label: "com.molodykhvitalii.AgentBar.ingest", qos: .userInitiated, attributes: .concurrent)
}

/// A bind that did not take, carrying the reason in a form worth branching on.
///
/// The ladder turns on telling "this port is taken" apart from every other
/// failure, and reading that off a formatted description would be a string
/// comparison against a system error message.
private struct BindFailure: Error {
    let error: NWError

    var isAddressInUse: Bool {
        guard case .posix(let code) = error else { return false }
        return code == .EADDRINUSE
    }

    var reason: String { "\(error)" }
}
