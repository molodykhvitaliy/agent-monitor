import AgentBarCore
import Foundation
import Network

/// Where the endpoint ended up listening.
///
/// The port is a result rather than a setting, because the ladder may have
/// moved it. Whoever installs a hook configuration reads it from here.
public struct BoundEndpoint: Sendable, Hashable {
    public let host: String
    public let port: UInt16
    public let socketPath: URL?

    public init(host: String = IngestConfiguration.host, port: UInt16, socketPath: URL?) {
        self.host = host
        self.port = port
        self.socketPath = socketPath
    }

    /// Always a literal address — see `IngestConfiguration.host`.
    public var hookURLPrefix: String { "http://\(host):\(port)/v1/hooks" }
}

public enum IngestEndpointError: Error, Sendable, Hashable, CustomStringConvertible {
    case alreadyRunning
    /// The service was asked to stop while this start was still binding, so the
    /// listeners it had just brought up were taken down again.
    case stoppedWhileStarting

    public var description: String {
        switch self {
        case .alreadyRunning: "the endpoint is already running"
        case .stoppedWhileStarting: "the endpoint was stopped while it was starting"
        }
    }
}

/// The loopback endpoint: two listeners, a bounded number of connections, and
/// nothing above them that knows which provider is talking.
public actor IngestEndpoint {
    private struct Served {
        let channel: IngestChannel
        let task: Task<Void, Never>
    }

    private let configuration: IngestConfiguration
    private let router: IngestRouter
    private let clock: any TimeSource
    private let diagnostics: any IngestDiagnosticSink

    private var loopbackListener: NWListener?
    private var socketListener: NWListener?
    private var boundSocketPath: URL?
    private var connections: [UUID: Served] = [:]
    private var isRunning = false

    public init(
        configuration: IngestConfiguration,
        token: IngestToken,
        handlers: [any IngestHandling],
        clock: any TimeSource = SystemTimeSource(),
        diagnostics: any IngestDiagnosticSink = SilentDiagnostics()
    ) {
        self.configuration = configuration
        self.clock = clock
        self.diagnostics = diagnostics
        router = IngestRouter(
            token: token,
            handlers: handlers + [HealthHandler()],
            deadline: configuration.responseDeadline,
            diagnostics: diagnostics)
    }

    /// Binds and begins serving.
    ///
    /// The Unix socket is allowed to fail on its own: it is the helper's
    /// shortcut, not the endpoint, and taking the whole endpoint down because a
    /// socket file was in a bad state would lose Claude Code's events too.
    @discardableResult
    public func start() async throws -> BoundEndpoint {
        guard !isRunning else { throw IngestEndpointError.alreadyRunning }
        let bound = try await IngestListener.loopback(
            candidates: configuration.candidatePorts,
            diagnostics: diagnostics,
            accept: { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                Task { await self.accept(connection, transport: .loopback) }
            })
        loopbackListener = bound.listener
        if bound.port != configuration.preferredPort {
            diagnostics.record(.portMoved(from: configuration.preferredPort, to: bound.port))
        }

        if let socketPath = configuration.socketPath {
            do {
                socketListener = try await IngestListener.unixSocket(
                    at: socketPath,
                    diagnostics: diagnostics,
                    accept: { [weak self] connection in
                        guard let self else {
                            connection.cancel()
                            return
                        }
                        Task { await self.accept(connection, transport: .unixSocket) }
                    })
                boundSocketPath = socketPath
            } catch {
                diagnostics.record(.unixSocketUnavailable(reason: "\(error)"))
            }
        }

        isRunning = true
        let socketDescription = boundSocketPath?.path(percentEncoded: false)
        diagnostics.record(.started(port: bound.port, socketPath: socketDescription))
        return BoundEndpoint(port: bound.port, socketPath: boundSocketPath)
    }

    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        loopbackListener?.cancel()
        loopbackListener = nil
        socketListener?.cancel()
        socketListener = nil

        let served = Array(connections.values)
        connections.removeAll()
        for entry in served {
            // Closing first, cancelling second: a task waiting on a socket read
            // does not notice cancellation, because the pending callback lives
            // inside Network.framework rather than in the task.
            entry.channel.close()
            entry.task.cancel()
        }
        for entry in served {
            await entry.task.value
        }

        if let path = boundSocketPath {
            // Cancelling a Unix listener leaves its socket file behind, and a
            // file that outlives its listener is one the next launch has to tell
            // apart from a live endpoint.
            try? FileManager.default.removeItem(at: path)
            boundSocketPath = nil
        }
        diagnostics.record(.stopped)
    }

    /// Sessions in flight, exposed for the suites and for a future diagnostics
    /// panel.
    public var openConnectionCount: Int { connections.count }

    private func accept(_ connection: NWConnection, transport: IngestTransport) {
        guard isRunning else {
            connection.cancel()
            return
        }
        guard connections.count < configuration.limits.maximumConcurrentConnections else {
            diagnostics.record(
                .connectionsAtCapacity(limit: configuration.limits.maximumConcurrentConnections))
            connection.cancel()
            return
        }
        let identifier = UUID()
        let channel = IngestChannel(connection)
        let served = IngestConnection(
            channel: channel,
            transport: transport,
            router: router,
            limits: configuration.limits,
            clock: clock,
            diagnostics: diagnostics)
        let task = Task { [weak self] in
            await served.serve(on: IngestListener.queue)
            await self?.release(identifier)
        }
        connections[identifier] = Served(channel: channel, task: task)
    }

    private func release(_ identifier: UUID) {
        connections[identifier] = nil
    }
}
