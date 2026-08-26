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
    case notLoopback(String)
    case notCreated(Int32)
    case refused(Int32)
    case timedOut
    case pollFailed(Int32)
    case writeFailed(Int32)
    case readFailed(Int32)
    /// The kernel refused to arm a send or receive timeout, so the exchange
    /// would have been unbounded. Reported rather than ignored: an unbounded
    /// syscall in the helper is an agent that waits on it.
    case timeoutRefused(Int32)

    var description: String {
        switch self {
        case .addressUnusable(let detail): "address unusable: \(detail)"
        case .notLoopback(let host): "\(host) is not a loopback address"
        case .notCreated(let code): "socket(): \(String(cString: strerror(code)))"
        case .refused(let code): "connect(): \(String(cString: strerror(code)))"
        case .timedOut: "timed out"
        case .pollFailed(let code): "poll(): \(String(cString: strerror(code)))"
        case .writeFailed(let code): "write(): \(String(cString: strerror(code)))"
        case .readFailed(let code): "read(): \(String(cString: strerror(code)))"
        case .timeoutRefused(let code):
            "setsockopt(SO_SNDTIMEO/SO_RCVTIMEO): \(String(cString: strerror(code)))"
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
    ///
    /// `deadline` bounds the **whole exchange**, not each syscall. Socket
    /// timeouts alone would not: every partial `send` restarts `SO_SNDTIMEO`, so
    /// a peer that drains a large payload slowly but steadily could hold the
    /// helper open indefinitely, and a peer trickling one byte at a time could
    /// hold the read loop for as long as it liked. The one process that must
    /// never delay an agent is the one place that cannot be left to per-call
    /// timeouts.
    static func exchange(
        _ request: Data,
        with destination: RelayDestination,
        timeouts: RelayTimeouts,
        deadline: ContinuousClock.Instant,
        replyLimit: Int = 512
    ) throws -> Data {
        let descriptor = try connect(
            to: destination, within: min(timeouts.connect, remaining(until: deadline)))
        defer { close(descriptor) }
        try configure(descriptor, timeouts: timeouts, deadline: deadline)
        try write(request, to: descriptor, deadline: deadline)
        // The endpoint answers 200 with an empty body and closes, because the
        // request carries `Connection: close`. Reading the answer costs one
        // round trip on loopback and turns "the socket accepted our bytes" into
        // "the endpoint replied", which is the difference the relay reports.
        return read(from: descriptor, limit: replyLimit, deadline: deadline)
    }

    /// What is left of the budget, never negative.
    static func remaining(until deadline: ContinuousClock.Instant) -> Duration {
        let left = ContinuousClock.now.duration(to: deadline)
        return left > .zero ? left : .zero
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

    /// The address, **only** if it is on the loopback network.
    ///
    /// The host is read from a file, and a file can say anything. ADR-0002's
    /// guarantee is that AgentBar talks to loopback and to nothing else, and
    /// this is the one place in the project that turns text into a destination —
    /// so this is where the guarantee has to be enforced rather than assumed. A
    /// payload carries a prompt, a working directory and a tool's arguments; the
    /// request carries a bearer token. Neither may leave this machine.
    private static func loopbackAddress(host: String, port: UInt16) throws -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_len = UInt8(inetSize)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else {
            throw RelaySocketError.addressUnusable("\(host) is not an IPv4 address")
        }
        // 127.0.0.0/8, tested on the network-order first octet.
        guard UInt8(truncatingIfNeeded: address.sin_addr.s_addr.littleEndian) == 127 else {
            throw RelaySocketError.notLoopback(host)
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
            var ready = poll(&descriptors, 1, milliseconds(timeout))
            // A signal is not a refusal. Retrying once inside the same budget
            // costs nothing and stops an interrupted wait from being reported as
            // an endpoint that said no.
            if ready < 0, errno == EINTR {
                ready = poll(&descriptors, 1, milliseconds(timeout))
            }
            guard ready > 0 else {
                throw ready == 0 ? RelaySocketError.timedOut : RelaySocketError.pollFailed(errno)
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

    /// Arms the kernel's own send and receive timeouts for what is left of the
    /// budget.
    ///
    /// > **A spent budget is a refusal, not a zero.** POSIX documents a
    /// > `SO_SNDTIMEO` or `SO_RCVTIMEO` of `{0, 0}` as *no timeout at all*, so
    /// > rounding a sub-microsecond remainder down to zero would arm the exact
    /// > inverse of what was asked — an unbounded blocking call on the one
    /// > process that must never outlive the agent that spawned it. `timeval`
    /// > floors at one microsecond and this throws when there is genuinely
    /// > nothing left, so neither path can produce that value.
    /// Internal rather than private so `RelayTimeoutConversionTests` can drive
    /// it against a real descriptor: the guard below is unreachable through
    /// `exchange`, where `connect` gives up on a spent budget first, and a
    /// guard nothing can reach is a guard nothing proves.
    static func configure(
        _ descriptor: Int32, timeouts: RelayTimeouts, deadline: ContinuousClock.Instant
    ) throws {
        let left = remaining(until: deadline)
        guard left > .zero else { throw RelaySocketError.timedOut }
        var send = timeval(for: min(timeouts.send, left))
        var receive = timeval(for: min(timeouts.reply, left))
        let size = socklen_t(MemoryLayout<timeval>.size)
        // Both results are checked. A refused `setsockopt` leaves the socket
        // blocking with no timeout, which is the failure this whole function
        // exists to prevent, and it must not be invisible.
        guard setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &send, size) == 0 else {
            throw RelaySocketError.timeoutRefused(errno)
        }
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &receive, size) == 0 else {
            throw RelaySocketError.timeoutRefused(errno)
        }
    }

    // MARK: - Transfer

    private static func write(
        _ data: Data, to descriptor: Int32, deadline: ContinuousClock.Instant
    ) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < buffer.count {
                // Checked per iteration, because a partial write restarts the
                // socket's own timeout and a steady trickle would otherwise
                // never trip it.
                guard remaining(until: deadline) > .zero else {
                    throw RelaySocketError.timedOut
                }
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
    private static func read(
        from descriptor: Int32, limit: Int, deadline: ContinuousClock.Instant
    ) -> Data {
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 512)
        while reply.count < limit, remaining(until: deadline) > .zero {
            // Not named `remaining`: the loop condition above calls the static
            // `remaining(until:)`, and a local of that name in the same scope
            // leaves the reader working out which one each line means.
            let wanted = limit - reply.count
            let count = buffer.withUnsafeMutableBytes { destination in
                recv(descriptor, destination.baseAddress, min(destination.count, wanted), 0)
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

    /// Milliseconds, saturating rather than trapping.
    ///
    /// `RelayTimeouts` is public with a public initialiser, so the number came
    /// from a caller — and this repository has a rule about arithmetic on those:
    /// compare and convert without ever letting the multiplication overflow.
    static func milliseconds(_ duration: Duration) -> Int32 {
        let components = duration.components
        let (product, overflowed) = components.seconds.multipliedReportingOverflow(by: 1000)
        guard !overflowed else { return Int32.max }
        let (total, carried) = product.addingReportingOverflow(
            components.attoseconds / 1_000_000_000_000_000)
        return carried ? Int32.max : Int32(clamping: total)
    }

    /// A socket timeout, floored at one microsecond.
    ///
    /// The floor is the whole point. `{0, 0}` means *block for ever* to
    /// `SO_SNDTIMEO` and `SO_RCVTIMEO`, so truncating a duration shorter than a
    /// microsecond would turn the tightest budget into no budget — the one
    /// direction this conversion may not fail in. The sibling
    /// `milliseconds(_:)` truncates to `0` safely because `poll` reads that as
    /// *return immediately*, which is the safe direction there.
    static func timeval(for duration: Duration) -> Darwin.timeval {
        let components = duration.components
        let seconds = Int(clamping: components.seconds)
        let microseconds = Int32(clamping: components.attoseconds / 1_000_000_000_000)
        guard seconds > 0 || microseconds > 0 else {
            return Darwin.timeval(tv_sec: 0, tv_usec: 1)
        }
        return Darwin.timeval(tv_sec: seconds, tv_usec: microseconds)
    }
}

/// How long a relay may take, in total and by stage.
///
/// Small on purpose, and small in a particular direction: Codex caps a
/// `SessionEnd` hook at one second, and every millisecond spent here is a
/// millisecond the agent is not doing its own work.
///
/// `total` is the one that actually bounds the run. The three stage timeouts are
/// what each syscall is given, and syscall timeouts do not compose — a partial
/// write restarts the clock, a read loop restarts it per chunk, and the
/// destination ladder would pay for both rungs. `total` is taken once, at the
/// top of the relay, and every stage is clamped to what is left of it.
public struct RelayTimeouts: Sendable, Hashable {
    public var total: Duration
    public var connect: Duration
    public var send: Duration
    public var reply: Duration

    public init(
        total: Duration = .milliseconds(400),
        connect: Duration = .milliseconds(100),
        send: Duration = .milliseconds(200),
        reply: Duration = .milliseconds(150)
    ) {
        self.total = total
        self.connect = connect
        self.send = send
        self.reply = reply
    }
}
