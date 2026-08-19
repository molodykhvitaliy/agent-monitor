import Darwin
import Foundation

/// Where the relay sends one request.
enum RelayDestination: Sendable, Hashable {
    /// The Unix socket the endpoint prefers, when it managed to bind one.
    case unixSocket(path: String)
    case loopback(host: String, port: UInt16)
}

/// Why a relay attempt did not deliver.
enum RelaySocketError: Error, Sendable, Hashable, CustomStringConvertible {
    case addressUnusable(String)
    case notCreated(Int32)
    case refused(Int32)
    case timedOut
    case writeFailed(Int32)
    case readFailed(Int32)

    var description: String {
        switch self {
        case .addressUnusable(let detail): "address unusable: \(detail)"
        case .notCreated(let code): "socket(): \(String(cString: strerror(code)))"
        case .refused(let code): "connect(): \(String(cString: strerror(code)))"
        case .timedOut: "timed out"
        case .writeFailed(let code): "write(): \(String(cString: strerror(code)))"
        case .readFailed(let code): "read(): \(String(cString: strerror(code)))"
        }
    }
}

/// One blocking request-and-reply over a loopback socket, with deadlines.
///
/// **POSIX sockets, not Network.framework**, and the reason is not only speed.
/// `ModuleBoundaryTests` restricts `Network` to `AgentBarIngest` so that the
/// loopback-only guarantee in ADR-0002 is a failing test rather than a promise,
/// and the helper has no business widening that. What is left is three syscalls
/// and a `poll`, which is also the fastest thing available on a path that has to
/// finish inside a millisecond budget somebody else set.
///
/// Every path here is bounded. A hook that hangs is an agent that hangs, and the
/// helper would rather deliver nothing than be the reason a session waits.
enum RelaySocket {
    /// Sends `request` and returns whatever the peer said, up to `replyLimit`.
    static func exchange(
        _ request: Data,
        with destination: RelayDestination,
        timeouts: RelayTimeouts,
        replyLimit: Int = 512
    ) throws -> Data {
        let descriptor = try connect(to: destination, within: timeouts.connect)
        defer { close(descriptor) }
        try configure(descriptor, timeouts: timeouts)
        try write(request, to: descriptor)
        // The endpoint answers 200 with an empty body and closes, because the
        // request carries `Connection: close`. Reading the answer costs one
        // round trip on loopback and turns "the socket accepted our bytes" into
        // "the endpoint replied", which is the difference the relay reports.
        return read(from: descriptor, limit: replyLimit)
    }

    // MARK: - Connecting

    private static func connect(
        to destination: RelayDestination, within timeout: Duration
    ) throws -> Int32 {
        switch destination {
        case .unixSocket(let path):
            var address = try unixAddress(path: path)
            return try connect(&address, family: AF_UNIX, timeout: timeout)
        case .loopback(let host, let port):
            var address = try loopbackAddress(host: host, port: port)
            return try connect(&address, family: AF_INET, timeout: timeout)
        }
    }

    private static let unixSize = MemoryLayout<sockaddr_un>.size
    private static let inetSize = MemoryLayout<sockaddr_in>.size

    private static func unixAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(unixSize)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw RelaySocketError.addressUnusable("socket path is longer than \(capacity - 1)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
            destination[bytes.count] = 0
        }
        return address
    }

    private static func loopbackAddress(host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(inetSize)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw RelaySocketError.addressUnusable("\(host) is not an IPv4 address")
        }
        return address
    }

    /// Non-blocking `connect` bounded by `poll`.
    ///
    /// A blocking connect to a port nobody holds is refused immediately, which
    /// is the common case and costs nothing. The case this guards is the other
    /// one: something that accepts the connection and never speaks. The socket
    /// goes back to blocking afterwards, with send and receive timeouts, so the
    /// rest of the exchange is bounded by the kernel rather than by a loop here.
    private static func connect<Address>(
        _ address: inout Address, family: Int32, timeout: Duration
    ) throws -> Int32 {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RelaySocketError.notCreated(errno) }
        var succeeded = false
        defer { if !succeeded { close(descriptor) } }

        var noSignal: Int32 = 1
        // Per-socket rather than a process-wide `signal(SIGPIPE, SIG_IGN)`: the
        // helper must not change how anything else in the process behaves, and a
        // write to a peer that has gone must be an error, never a death.
        setsockopt(
            descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(descriptor, F_GETFL, 0)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)

        let size = socklen_t(MemoryLayout<Address>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                Darwin.connect(descriptor, address, size)
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { throw RelaySocketError.refused(errno) }
            var descriptors = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptors, 1, milliseconds(timeout))
            guard ready > 0 else {
                throw ready == 0 ? RelaySocketError.timedOut : RelaySocketError.refused(errno)
            }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0
            else {
                throw RelaySocketError.refused(failure == 0 ? errno : failure)
            }
        }
        _ = fcntl(descriptor, F_SETFL, flags)
        succeeded = true
        return descriptor
    }

    private static func configure(_ descriptor: Int32, timeouts: RelayTimeouts) throws {
        var send = timeval(for: timeouts.send)
        var receive = timeval(for: timeouts.reply)
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &send, size)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receive, size)
    }

    // MARK: - Transfer

    private static func write(_ data: Data, to descriptor: Int32) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < buffer.count {
                let written = Darwin.send(descriptor, base + sent, buffer.count - sent, 0)
                if written > 0 {
                    sent += written
                    continue
                }
                // `errno` says nothing unless the call actually failed, and a
                // zero-length write on a stream socket is not something to read
                // a stale error out of. Either way the loop ends here.
                let code = written < 0 ? errno : EIO
                if code == EINTR { continue }
                throw code == EAGAIN || code == EWOULDBLOCK
                    ? RelaySocketError.timedOut : RelaySocketError.writeFailed(code)
            }
        }
    }

    /// Reads until the peer closes, the limit is reached, or the receive timeout
    /// fires. A truncated or absent answer is not an error: the payload has
    /// already been delivered by then, and the helper's job is done.
    private static func read(from descriptor: Int32, limit: Int) -> Data {
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while reply.count < limit {
            let remaining = limit - reply.count
            let count = buffer.withUnsafeMutableBytes { destination in
                recv(descriptor, destination.baseAddress, min(destination.count, remaining), 0)
            }
            if count > 0 {
                reply.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        return reply
    }

    // MARK: - Durations

    private static func milliseconds(_ duration: Duration) -> Int32 {
        let components = duration.components
        let total = components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
        return Int32(clamping: total)
    }

    private static func timeval(for duration: Duration) -> Darwin.timeval {
        let components = duration.components
        return Darwin.timeval(
            tv_sec: Int(clamping: components.seconds),
            tv_usec: Int32(clamping: components.attoseconds / 1_000_000_000_000))
    }
}

/// How long each stage of one relay may take.
///
/// Small on purpose, and small in a particular direction: Codex caps a
/// `SessionEnd` hook at one second, and every millisecond spent here is a
/// millisecond the agent is not doing its own work. The sum of all three is
/// still under half the smallest budget either agent gives a hook.
public struct RelayTimeouts: Sendable, Hashable {
    public var connect: Duration
    public var send: Duration
    public var reply: Duration

    public init(
        connect: Duration = .milliseconds(100),
        send: Duration = .milliseconds(200),
        reply: Duration = .milliseconds(150)
    ) {
        self.connect = connect
        self.send = send
        self.reply = reply
    }
}
