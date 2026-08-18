import Foundation
import Testing

@testable import AgentBarIngest

/// The deadline is the one piece of this module the Approve/Deny backlog item
/// depends on being exactly right: it is what guarantees that "the timeout
/// expired" resolves to no decision rather than to a decision nobody watched
/// arrive.
@Suite("Deadline")
struct DeadlineTests {
    typealias StringContinuation = CheckedContinuation<String, Never>

    /// The work and the timer are unstructured tasks started before the caller
    /// reaches `take()`, so an answer routinely arrives while the slot is still
    /// empty. A mailbox with nowhere to put it turned roughly one in five of
    /// those into a false timeout — and a false timeout on the reserved path
    /// means discarding a decision and reporting that none was given.
    @Test("An answer that arrives before the taker parks is not lost")
    func neverLosesAFastAnswer() async {
        var losses = 0
        for index in 0..<2000 {
            let result = await Deadline.run(within: .seconds(30)) { index }
            if result != index { losses += 1 }
        }
        #expect(losses == 0)
    }

    @Test("An answer that arrives with the deadline far off is returned as-is")
    func returnsSlowerAnswers() async {
        let result = await Deadline.run(within: .seconds(30)) {
            try? await Task.sleep(for: .milliseconds(20))
            return "done"
        }
        #expect(result == "done")
    }

    @Test("The deadline expiring reports nothing rather than something")
    func reportsExpiry() async {
        let result: Int? = await Deadline.run(within: .milliseconds(30)) {
            try? await Task.sleep(for: .seconds(30))
            return 1
        }
        #expect(result == nil)
    }

    /// The property the type exists for, and the one a task-group implementation
    /// silently loses: work that cannot be cancelled is *abandoned*, not waited
    /// for. Written against a handler that ignores cancellation, because a
    /// cooperative one cannot tell the two implementations apart.
    @Test("Work that ignores cancellation is abandoned, not awaited")
    func abandonsUncancellableWork() async {
        let clock = ContinuousClock()
        let started = clock.now
        let result: String? = await Deadline.run(within: .milliseconds(50)) {
            await withCheckedContinuation { (continuation: StringContinuation) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    continuation.resume(returning: "too late")
                }
            }
        }
        let elapsed = clock.now - started
        #expect(result == nil)
        #expect(elapsed < .seconds(1), "the deadline waited for work it should have abandoned")
    }

    @Test("A late answer cannot overwrite the expiry that was already reported")
    func ignoresLateAnswers() async {
        for _ in 0..<50 {
            let result: String? = await Deadline.run(within: .milliseconds(10)) {
                await withCheckedContinuation { (continuation: StringContinuation) in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                        continuation.resume(returning: "late")
                    }
                }
            }
            #expect(result == nil)
        }
    }
}

@Suite("Diagnostics")
struct IngestDiagnosticTests {

    /// Every diagnostic is logged `.public`, and a request target is reachable
    /// before the token is checked. Splitting the head on CRLF leaves a bare
    /// newline inside a path intact, which in the unified log is a line the
    /// caller wrote.
    @Test("Caller-controlled text cannot forge a log line")
    func neutralisesControlCharacters() {
        let forged = "/v1/health\nrefused an unauthenticated request to /admin"
        let message = IngestDiagnostic.unauthorized(
            path: forged, transport: .loopback, reason: .tokenMismatch
        ).message
        #expect(!message.contains("\n"))
        #expect(!message.contains("\r"))
        #expect(message.contains("/v1/health"))
    }

    @Test("A caller cannot flood a log line with an enormous path")
    func boundsLength() {
        let message = IngestDiagnostic.routeNotFound(
            path: String(repeating: "p", count: 8000), method: "POST"
        ).message
        #expect(message.count < 300)
    }

    @Test("A parse error's caller-supplied text is neutralised too")
    func neutralisesParseErrorText() {
        let message = IngestDiagnostic.malformedRequest(
            .unsupportedVersion("HTTP/1.1\nforged"), transport: .loopback
        ).message
        #expect(!message.contains("\n"))
    }

    @Test("An ordinary path is left readable")
    func leavesOrdinaryTextAlone() {
        let message = IngestDiagnostic.eventsAccepted(
            path: "/v1/hooks/claude-code", applied: 3, ignored: 1
        ).message
        #expect(message.contains("/v1/hooks/claude-code"))
        #expect(message.contains("3 applied, 1 ignored"))
    }
}
