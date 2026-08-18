import Foundation

/// Where the ingest endpoint listens, and what it refuses before it has read a
/// request body.
///
/// Every value here is a decision a later step inherits: the port ends up
/// written into the user's hook configuration, and the limits are what stop one
/// oversized payload from becoming an oversized allocation.
public struct IngestConfiguration: Sendable, Hashable {
    /// The only address AgentBar binds, spelled out rather than named.
    ///
    /// `localhost` is a name, and resolving it is the client's opinion. A
    /// listener on `127.0.0.1` does not answer on `::1` — verified on macOS 27,
    /// where the IPv6 connection is refused outright — so a client that tries
    /// IPv6 first pays a wasted round trip, or fails altogether if it does not
    /// fall back. Every URL AgentBar writes into a hook configuration therefore
    /// carries this literal, never a name.
    public static let host = "127.0.0.1"

    /// The first port tried.
    ///
    /// Deliberately below the ephemeral floor: macOS allocates outbound local
    /// ports from 49152 upward (`net.inet.ip.portrange.first`), so a fixed port
    /// inside that range is one an unrelated outbound connection can be holding
    /// by the time AgentBar starts. It is also clear of the ports development
    /// tooling habitually claims.
    public static let defaultPort: UInt16 = 47821

    /// The port preferred, and the first rung of the ladder.
    public var preferredPort: UInt16

    /// How many consecutive ports to try, counting `preferredPort`.
    ///
    /// A short ladder rather than an ephemeral port, and the difference is the
    /// installer's contract. The Claude Code hook URL lives in the user's
    /// `settings.json` alongside an `allowedHttpHookUrls` entry that must match
    /// it, so a port drawn fresh on every launch means rewriting a file the user
    /// owns on every launch. A ladder moves only when something else already
    /// holds the port, which is rare enough to be repaired once and reported.
    public var portAttempts: Int

    /// Unix socket the Codex helper connects to, or `nil` for TCP only.
    ///
    /// A preference, never a requirement: if the socket cannot be bound the
    /// endpoint still serves TCP, and the helper finds the port in the discovery
    /// file. A transport that could take the whole endpoint down with it would
    /// be a worse trade than the microseconds it saves.
    public var socketPath: URL?

    public var limits: IngestLimits

    /// How long a handler may take before the endpoint answers without it.
    ///
    /// Not a courtesy. Codex caps `SessionEnd` hooks at one second, and Claude
    /// Code gives every `SessionEnd` handler a 1.5-second shared budget, so an
    /// endpoint that thinks for longer is an endpoint that eats an agent's
    /// shutdown. On expiry the answer is "no opinion" — the only safe default,
    /// and the one the Approve/Deny backlog item inherits rather than replaces.
    public var responseDeadline: Duration

    public init(
        preferredPort: UInt16 = IngestConfiguration.defaultPort,
        portAttempts: Int = 8,
        socketPath: URL? = nil,
        limits: IngestLimits = IngestLimits(),
        responseDeadline: Duration = .milliseconds(750)
    ) {
        self.preferredPort = preferredPort
        self.portAttempts = max(1, portAttempts)
        self.socketPath = socketPath
        self.limits = limits
        self.responseDeadline = responseDeadline
    }

    /// The ports to try, in order, stopping short of wrapping past 65535.
    public var candidatePorts: [UInt16] {
        (0..<portAttempts).compactMap { offset in
            let port = Int(preferredPort) + offset
            guard port <= Int(UInt16.max) else { return nil }
            return UInt16(port)
        }
    }
}

/// The bounds one connection is held to.
///
/// The endpoint is reachable by anything running as this user, and a hook
/// payload can legitimately carry an entire file, so each of these caps what a
/// single peer can make AgentBar allocate.
public struct IngestLimits: Sendable, Hashable {
    /// Longest request line accepted, before the first header is read.
    public var maximumRequestLineBytes: Int
    /// Longest request head — request line and all headers together.
    public var maximumHeadBytes: Int
    public var maximumHeaderCount: Int

    /// Largest body accepted.
    ///
    /// Generous rather than tight, because refusing a body means dropping an
    /// event: `PostToolUse` carries `tool_result`, which for a large file read
    /// is megabytes, and a dropped heartbeat is a session that reads as quiet
    /// while it is working. The worst case stays bounded because
    /// `maximumConcurrentConnections` bounds how many of these can exist.
    public var maximumBodyBytes: Int

    /// Closed after this long with no byte arriving.
    ///
    /// Clients keep connections alive between events, and a connection nobody
    /// ever writes to again is indistinguishable from one whose process died.
    public var idleTimeout: Duration

    /// Connections served at once; further ones are closed immediately.
    ///
    /// Far above anything real traffic produces — a handful of agents keeping
    /// one connection each — so reaching it means something is wrong, and the
    /// diagnostic that fires is the point.
    public var maximumConcurrentConnections: Int

    public init(
        maximumRequestLineBytes: Int = 8 * 1024,
        maximumHeadBytes: Int = 64 * 1024,
        maximumHeaderCount: Int = 128,
        maximumBodyBytes: Int = 4 * 1024 * 1024,
        idleTimeout: Duration = .seconds(30),
        maximumConcurrentConnections: Int = 64
    ) {
        self.maximumRequestLineBytes = maximumRequestLineBytes
        self.maximumHeadBytes = maximumHeadBytes
        self.maximumHeaderCount = maximumHeaderCount
        self.maximumBodyBytes = maximumBodyBytes
        self.idleTimeout = idleTimeout
        self.maximumConcurrentConnections = maximumConcurrentConnections
    }
}

/// Where the endpoint keeps the files it owns.
///
/// One directory, created `0700`, holding a secret and a description of how to
/// reach the endpoint. The directory permission matters more than either file's:
/// a socket is created by the networking stack with the process umask applied,
/// so the only way to close that window is for the enclosing directory to have
/// been unreachable to other users all along.
public struct IngestPaths: Sendable, Hashable {
    /// Longest Unix socket path the kernel accepts, `sun_path` being 104 bytes
    /// with room for the terminator.
    public static let maximumSocketPathBytes = 103

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var tokenURL: URL { directory.appending(path: "ingest-token") }
    public var discoveryURL: URL { directory.appending(path: "endpoint.json") }
    public var socketURL: URL { directory.appending(path: "ingest.sock") }

    /// `~/Library/Application Support/AgentBar`.
    public static func applicationSupport(
        named name: String = "AgentBar",
        fileManager: FileManager = .default
    ) throws -> IngestPaths {
        let base = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: false)
        return IngestPaths(directory: base.appending(path: name, directoryHint: .isDirectory))
    }

    /// Whether `socketURL` fits in `sockaddr_un`.
    ///
    /// A home directory deep enough to overflow it is unusual but not
    /// impossible, and the failure it would otherwise cause — a truncated path
    /// bound successfully at the wrong location — is the kind that takes a day
    /// to diagnose.
    public var socketPathFits: Bool {
        socketURL.path(percentEncoded: false).utf8.count <= IngestPaths.maximumSocketPathBytes
    }
}
