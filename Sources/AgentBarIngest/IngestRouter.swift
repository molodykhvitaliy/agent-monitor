import Foundation

/// Answers requests on one or more routes.
///
/// The response is a value the handler chooses rather than something the
/// transport decides, which is what keeps the Approve/Deny backlog item an
/// addition instead of a rewrite: a handler that needs to answer with a decision
/// already can.
public protocol IngestHandling: Sendable {
    var routes: Set<IngestRoute> { get }
    /// Must be cancellation-cooperative. A handler that overruns
    /// `IngestConfiguration.responseDeadline` is cancelled and its answer is
    /// discarded — see `Deadline`.
    func handle(_ request: IngestRequest) async -> IngestResponse
}

/// Liveness. Answers nothing but the fact that it answered.
public struct HealthHandler: IngestHandling {
    public init() {}
    public var routes: Set<IngestRoute> { [.health] }
    public func handle(_ request: IngestRequest) async -> IngestResponse { .noOpinion }
}

/// Authenticates a request, finds its handler, and bounds how long it may take.
///
/// Authentication happens before the route table is consulted, so an
/// unauthenticated caller cannot use the difference between 404 and 405 to
/// discover which routes exist.
struct IngestRouter: Sendable {
    private let token: IngestToken
    private let handlers: [IngestRoute: any IngestHandling]
    /// Which methods each known path answers on, so a wrong method is a 405
    /// rather than a misleading 404.
    private let methodsByPath: [String: Set<String>]
    private let deadline: Duration
    private let diagnostics: any IngestDiagnosticSink

    init(
        token: IngestToken,
        handlers: [any IngestHandling],
        deadline: Duration,
        diagnostics: any IngestDiagnosticSink
    ) {
        self.token = token
        self.deadline = deadline
        self.diagnostics = diagnostics
        var table: [IngestRoute: any IngestHandling] = [:]
        var methods: [String: Set<String>] = [:]
        for handler in handlers {
            for route in handler.routes {
                table[route] = handler
                methods[route.path, default: []].insert(route.method)
            }
        }
        self.handlers = table
        methodsByPath = methods
    }

    func respond(
        to head: HTTPRequestHead,
        body: Data,
        transport: IngestTransport,
        receivedAt: Date
    ) async -> IngestResponse {
        if let failure = authenticate(head.headers) {
            diagnostics.record(
                .unauthorized(path: head.path, transport: transport, reason: failure))
            return IngestResponse(status: .unauthorized)
        }
        guard let methods = methodsByPath[head.path] else {
            diagnostics.record(.routeNotFound(path: head.path, method: head.method))
            return IngestResponse(status: .notFound)
        }
        guard methods.contains(head.method) else {
            diagnostics.record(.methodNotAllowed(path: head.path, method: head.method))
            return IngestResponse(status: .methodNotAllowed)
        }
        let route = IngestRoute(method: head.method, path: head.path)
        guard let handler = handlers[route] else {
            diagnostics.record(.routeNotFound(path: head.path, method: head.method))
            return IngestResponse(status: .notFound)
        }

        let request = IngestRequest(
            route: route, query: head.query, headers: head.headers, body: body,
            transport: transport, receivedAt: receivedAt)
        let response = await Deadline.run(within: deadline) { await handler.handle(request) }
        guard let response else {
            diagnostics.record(.handlerTimedOut(path: head.path))
            return .noOpinion
        }
        return response
    }

    /// `Authorization: Bearer <token>`, and nothing else.
    ///
    /// The caller is told only that it was refused. Which of the three ways it
    /// was wrong is a diagnostic for the person running AgentBar, not a hint for
    /// whatever sent the request.
    private func authenticate(_ headers: HTTPHeaders) -> AuthenticationFailure? {
        guard let value = headers["authorization"] else { return .headerMissing }
        let parts = value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return .schemeNotBearer }
        guard token.matches(String(parts[1])) else { return .tokenMismatch }
        return nil
    }
}
