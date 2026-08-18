import AgentBarCore
import Foundation

/// The endpoint as the app uses it.
///
/// Assembly, and nothing else: a token loaded or created, listeners bound, and
/// a description of where they landed published so the installer and the helper
/// can find the port that was actually taken rather than the one that was
/// wanted. Splitting this from `IngestEndpoint` keeps the endpoint testable
/// without a filesystem.
public actor IngestService {
    private let paths: IngestPaths
    private let configuration: IngestConfiguration
    private let credentials: any IngestCredentialStoring
    private let discovery: any EndpointPublishing
    private let store: SessionStore
    private let decoders: [IngestRoute: any EventDecoding]
    private let resolver: any ProjectResolving
    private let clock: any TimeSource
    private let diagnostics: any IngestDiagnosticSink

    private var endpoint: IngestEndpoint?
    private var bound: BoundEndpoint?
    private var credentialOrigin: IngestCredentialOrigin?
    private var token: IngestToken?
    /// Set by `stop()`. An actor call suspends, so a stop issued while `start()`
    /// is waiting on a bind would otherwise be overtaken by the start it was
    /// meant to cancel — which republishes the discovery file the stop had just
    /// retracted, leaving a dead pid pointing at a port nobody holds.
    private var stopRequested = false

    /// Provider decoders passed in `decoders` are added to AgentBar's own native
    /// route rather than replacing it. Steps 04 and 09 register theirs here, and
    /// nothing else about the endpoint changes when they do.
    public init(
        paths: IngestPaths,
        store: SessionStore,
        configuration: IngestConfiguration? = nil,
        decoders: [IngestRoute: any EventDecoding] = [:],
        credentials: (any IngestCredentialStoring)? = nil,
        discovery: (any EndpointPublishing)? = nil,
        resolver: any ProjectResolving = PathProjectResolver(),
        clock: any TimeSource = SystemTimeSource(),
        diagnostics: any IngestDiagnosticSink = SystemDiagnostics()
    ) {
        self.paths = paths
        self.store = store
        self.resolver = resolver
        self.clock = clock
        self.diagnostics = diagnostics
        self.credentials =
            credentials ?? FileCredentialStore(url: paths.tokenURL, diagnostics: diagnostics)
        self.discovery = discovery ?? EndpointDiscoveryFile(url: paths.discoveryURL)
        self.configuration =
            configuration
            ?? IngestConfiguration(socketPath: paths.socketPathFits ? paths.socketURL : nil)
        self.decoders = decoders.merging([.events: NativeEventDecoder()]) { provided, _ in provided
        }
    }

    /// Whether the token was loaded, created, or replaced because the stored one
    /// was unusable.
    ///
    /// `replaced` is what the installer has to react to: the endpoint works, but
    /// every hook configuration already on disk is carrying the old secret.
    public var lastCredentialOrigin: IngestCredentialOrigin? { credentialOrigin }

    public var boundEndpoint: BoundEndpoint? { bound }

    /// Where the endpoint is and what proves a caller may reach it, together.
    ///
    /// The pair an installer needs: a hook configuration has to carry both, and
    /// reading the token file a second time behind this actor's back would be a
    /// second source of truth for a secret this one may have just replaced.
    public var boundCredential: (endpoint: BoundEndpoint, token: IngestToken)? {
        guard let bound, let token else { return nil }
        return (bound, token)
    }

    @discardableResult
    public func start() async throws -> BoundEndpoint {
        guard endpoint == nil else { throw IngestEndpointError.alreadyRunning }
        stopRequested = false
        if configuration.socketPath == nil, paths.socketPathFits == false {
            diagnostics.record(
                .unixSocketUnavailable(
                    reason: "path is longer than \(IngestPaths.maximumSocketPathBytes) bytes"))
        }

        let credential = try credentials.loadOrCreate()
        credentialOrigin = credential.origin

        let handler = EventIngestHandler(
            store: store, decoders: decoders, resolver: resolver, diagnostics: diagnostics)
        let service = IngestEndpoint(
            configuration: configuration,
            token: credential.token,
            handlers: [handler],
            clock: clock,
            diagnostics: diagnostics)
        let bound = try await service.start()
        guard !stopRequested else {
            // A stop arrived while the bind was in flight. Publishing now would
            // undo the retraction it already performed.
            await service.stop()
            throw IngestEndpointError.stoppedWhileStarting
        }
        endpoint = service
        self.bound = bound
        token = credential.token

        try discovery.publish(
            EndpointDescriptor(
                port: bound.port,
                socketPath: bound.socketPath?.path(percentEncoded: false),
                tokenPath: paths.tokenURL.path(percentEncoded: false),
                processIdentifier: ProcessInfo.processInfo.processIdentifier,
                startedAt: clock.wallTime))
        return bound
    }

    public func stop() async {
        stopRequested = true
        // Retracted before the listeners go down, so there is no window in which
        // a reader is told about an endpoint that has already stopped answering.
        try? discovery.retract()
        await endpoint?.stop()
        endpoint = nil
        bound = nil
        token = nil
    }
}
