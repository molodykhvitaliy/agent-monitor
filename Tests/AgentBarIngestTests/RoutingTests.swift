import Foundation
import Network
import Testing

@testable import AgentBarCore
@testable import AgentBarIngest

@Suite("Routing and authentication")
struct IngestRouterTests {
    static let token = IngestToken.generate()

    private func router(
        handlers: [any IngestHandling] = [HealthHandler()],
        deadline: Duration = .seconds(1),
        diagnostics: any IngestDiagnosticSink = SilentDiagnostics()
    ) -> IngestRouter {
        IngestRouter(
            token: IngestRouterTests.token, handlers: handlers, deadline: deadline,
            diagnostics: diagnostics)
    }

    private func head(
        method: String = "GET", path: String = "/v1/health", headers: [(String, String)]
    ) -> HTTPRequestHead {
        HTTPRequestHead(
            method: method, path: path, query: nil, version: "HTTP/1.1",
            headers: HTTPHeaders(headers))
    }

    private func authorised() -> [(String, String)] {
        [("Authorization", "Bearer \(IngestRouterTests.token.value)")]
    }

    private func respond(
        _ router: IngestRouter, _ head: HTTPRequestHead, body: Data = Data()
    ) async -> IngestResponse {
        await router.respond(to: head, body: body, transport: .loopback, receivedAt: Date())
    }

    @Test("An authenticated request reaches its handler")
    func acceptsAuthenticated() async {
        let response = await respond(router(), head(headers: authorised()))
        #expect(response.status == .ok)
        #expect(response.body.isEmpty)
    }

    @Test(
        "Refuses anything that is not the token, and says why only in a diagnostic",
        arguments: [
            ([(String, String)](), AuthenticationFailure.headerMissing),
            ([("Authorization", "Basic abc")], AuthenticationFailure.schemeNotBearer),
            ([("Authorization", "Bearer")], AuthenticationFailure.schemeNotBearer),
            ([("Authorization", "Bearer wrong")], AuthenticationFailure.tokenMismatch),
        ]
    )
    func refusesUnauthenticated(headers: [(String, String)], expected: AuthenticationFailure) async
    {
        let diagnostics = CollectingDiagnostics()
        let response = await respond(router(diagnostics: diagnostics), head(headers: headers))
        #expect(response.status == .unauthorized)
        #expect(response.body.isEmpty)
        #expect(
            diagnostics.contains {
                guard case .unauthorized(_, _, let reason) = $0 else { return false }
                return reason == expected
            })
    }

    /// Authentication runs before the route table, so the difference between
    /// 404 and 405 cannot be used to map what exists.
    @Test("An unauthenticated caller cannot tell a real route from a made-up one")
    func revealsNoRoutes() async {
        let real = await respond(router(), head(path: "/v1/health", headers: []))
        let fake = await respond(router(), head(path: "/v1/nope", headers: []))
        #expect(real.status == .unauthorized)
        #expect(fake.status == .unauthorized)
    }

    @Test("An unknown path is 404 and a wrong method is 405")
    func distinguishesPathFromMethod() async {
        let unknown = await respond(router(), head(path: "/v1/nope", headers: authorised()))
        #expect(unknown.status == .notFound)
        let wrongMethod = await respond(
            router(), head(method: "POST", path: "/v1/health", headers: authorised()))
        #expect(wrongMethod.status == .methodNotAllowed)
    }

    /// The deadline is what makes the reserved synchronous path safe: whatever
    /// the handler is doing, the answer at the deadline is "no opinion".
    @Test("A handler that overruns its deadline is answered past")
    func boundsSlowHandlers() async {
        let diagnostics = CollectingDiagnostics()
        let slow = ScriptedHandler(
            routes: [.events], delay: .seconds(30),
            response: IngestResponse(status: .badRequest))
        let router = router(
            handlers: [slow], deadline: .milliseconds(50), diagnostics: diagnostics)

        let response = await respond(
            router, head(method: "POST", path: "/v1/events", headers: authorised()))

        // Promptness is asserted in `DeadlineTests.expiresPromptly`, on a median
        // that a single scheduling stall cannot move. Bounding elapsed time here
        // as well would only re-add the flake that assertion exists to avoid,
        // and would catch nothing `abandonsUncancellableHandlers` does not.
        #expect(response == .noOpinion)
        #expect(
            diagnostics.contains {
                if case .handlerTimedOut = $0 { return true }
                return false
            })
    }

    /// `boundsSlowHandlers` uses a handler that respects cancellation, so it
    /// would still pass if the deadline waited for its work instead of
    /// abandoning it. This one cannot be cancelled at all.
    ///
    /// Asserted as an ordering rather than an elapsed time, and in both halves —
    /// started, and not finished — for the reasons
    /// `DeadlineTests.abandonsUncancellableWork` records.
    @Test(
        "A handler that cannot be cancelled still does not delay the answer",
        .timeLimit(.minutes(1)))
    func abandonsUncancellableHandlers() async {
        let diagnostics = CollectingDiagnostics()
        let stubborn = UncooperativeHandler(
            routes: [.events], seconds: 10, response: IngestResponse(status: .badRequest))
        let router = router(
            handlers: [stubborn], deadline: .milliseconds(50), diagnostics: diagnostics)

        let response = await respond(
            router, head(method: "POST", path: "/v1/events", headers: authorised()))
        let finishedBeforeAnswer = stubborn.completed.isSet

        #expect(response == .noOpinion)
        #expect(!finishedBeforeAnswer, "the router waited for work it should have abandoned")
        #expect(
            await stubborn.started.waitUntilSet(),
            "the handler never ran, so the test proved nothing")
        #expect(
            diagnostics.contains {
                if case .handlerTimedOut = $0 { return true }
                return false
            })
    }

    /// A handler that answers promptly must never be reported as an overrun:
    /// the answer and the timer race on every call, and losing that race used to
    /// discard the answer.
    @Test("A prompt handler is never mistaken for one that overran")
    func neverReportsAFalseTimeout() async {
        let diagnostics = CollectingDiagnostics()
        let router = router(handlers: [HealthHandler()], diagnostics: diagnostics)
        for _ in 0..<400 {
            let response = await respond(router, head(headers: authorised()))
            #expect(response.status == .ok)
        }
        #expect(
            !diagnostics.contains {
                if case .handlerTimedOut = $0 { return true }
                return false
            })
    }

    @Test("A handler that answers in time keeps its answer")
    func keepsFastAnswers() async {
        let handler = ScriptedHandler(
            routes: [.events], response: .decision(Data(#"{"ok":true}"#.utf8)))
        let response = await respond(
            router(handlers: [handler]),
            head(method: "POST", path: "/v1/events", headers: authorised()))
        #expect(response.status == .ok)
        #expect(response.contentType == "application/json")
    }
}

@Suite("Loopback guard")
struct LoopbackGuardTests {

    @Test("Accepts only the addresses that cannot be reached from another machine")
    func acceptsLoopbackOnly() {
        #expect(throws: Never.self) {
            try IngestListener.verifyLoopback(.hostPort(host: .ipv4(.loopback), port: 47821))
        }
        #expect(throws: Never.self) {
            try IngestListener.verifyLoopback(.hostPort(host: .ipv6(.loopback), port: 47821))
        }
        #expect(throws: Never.self) {
            try IngestListener.verifyLoopback(.unix(path: "/tmp/x.sock"))
        }
    }

    @Test(
        "Refuses anything else, including a name that could resolve anywhere",
        arguments: [
            NWEndpoint.hostPort(host: .ipv4(.broadcast), port: 47821),
            NWEndpoint.hostPort(host: NWEndpoint.Host("localhost"), port: 47821),
            NWEndpoint.hostPort(host: NWEndpoint.Host("192.168.0.1"), port: 47821),
        ]
    )
    func refusesEverythingElse(endpoint: NWEndpoint) {
        #expect(throws: (any Error).self) { try IngestListener.verifyLoopback(endpoint) }
    }

    @Test("Refuses an unspecified endpoint rather than assuming loopback")
    func refusesUnspecified() {
        #expect(throws: (any Error).self) { try IngestListener.verifyLoopback(nil) }
    }
}
