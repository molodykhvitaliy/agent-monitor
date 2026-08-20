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
    ///
    /// Asserted as an *ordering* rather than a duration: when the deadline
    /// returns, the work must have started and must not have finished. An
    /// earlier version bounded the elapsed wall-clock at one second instead,
    /// which states the property only on an idle machine — under `swift test
    /// --parallel` a CI runner put 1.3 s between the two clock reads while the
    /// deadline itself had returned in milliseconds, and the test failed for the
    /// machine's reasons rather than the code's. A latch cannot be starved into
    /// a false failure: if the deadline waited, the work is finished, whatever
    /// the load.
    ///
    /// Both halves are needed. "The work had not finished" is also true of work
    /// the scheduler never started, and on the runner that motivated this test
    /// that is not hypothetical.
    @Test("Work that ignores cancellation is abandoned, not awaited", .timeLimit(.minutes(1)))
    func abandonsUncancellableWork() async {
        let started = CompletionFlag()
        let completed = CompletionFlag()
        let result: String? = await Deadline.run(within: .milliseconds(50)) {
            started.set()
            return await withCheckedContinuation { (continuation: StringContinuation) in
                // Far longer than the deadline and than any plausible scheduling
                // delay. It costs 10 s on the failing path, and on the passing
                // path only a suspended task and a pending timer that outlive
                // the test — nothing waits for either.
                DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                    completed.set()
                    continuation.resume(returning: "too late")
                }
            }
        }
        let finishedBeforeReturn = completed.isSet

        #expect(result == nil)
        #expect(!finishedBeforeReturn, "the deadline waited for work it should have abandoned")
        #expect(await started.waitUntilSet(), "the work never ran, so the test proved nothing")
    }

    /// Expiry must be *prompt*, not merely eventual. `responseDeadline` defaults
    /// to 750 ms because Codex caps `SessionEnd` at one second, so a deadline
    /// that expires late eats an agent's shutdown — and every other assertion in
    /// this suite passes just as well if `run` takes seconds to give up.
    ///
    /// Bounded on the *median* rather than the worst sample, deliberately. The
    /// single 1.3 s stall that broke the old assertions cannot move a median,
    /// while it fails any bound on the maximum.
    @Test(
        "Expiry lands near the deadline rather than merely eventually",
        .timeLimit(.minutes(1)))
    func expiresPromptly() async {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        for _ in 0..<21 {
            let started = clock.now
            let result: Int? = await Deadline.run(within: .milliseconds(50)) {
                try? await Task.sleep(for: .seconds(30))
                return 1
            }
            samples.append(clock.now - started)
            #expect(result == nil)
        }
        let median = samples.sorted()[samples.count / 2]
        #expect(median < .milliseconds(500), "expiry is drifting well past its deadline")
    }

    /// Asserted as an *ordering*, like the abandonment test above and for the
    /// same reason. The earlier version raced a 10 ms deadline against an answer
    /// 50 ms out and read `nil` as proof the late answer had been dropped. A
    /// 40 ms margin is no margin on a runner executing the whole suite in
    /// parallel: CI scheduled the timer task late three times over, the answer
    /// arrived first and won honestly, and the test failed for the machine's
    /// reasons rather than the code's.
    ///
    /// Here the answer cannot exist until the test releases it, and the test
    /// releases it only after `run` has already returned — so nothing but the
    /// deadline can have answered, whatever the load. The delivery that follows
    /// is the one under test: it lands in a slot the timer has already filled,
    /// and a mailbox that let it through would resume a continuation that was
    /// resumed once already, which traps rather than passing quietly.
    @Test(
        "A late answer cannot overwrite the expiry that was already reported",
        .timeLimit(.minutes(1)))
    func ignoresLateAnswers() async {
        for _ in 0..<50 {
            let release = DispatchSemaphore(value: 0)
            let answered = CompletionFlag()
            let result: String? = await Deadline.run(within: .milliseconds(10)) {
                await withCheckedContinuation { (continuation: StringContinuation) in
                    // Off the cooperative pool deliberately: the answer has to
                    // outlive the cancellation `run` issues on its way out, the
                    // way a handler that ignores cancellation would.
                    DispatchQueue.global().async {
                        release.wait()
                        answered.set()
                        continuation.resume(returning: "late")
                    }
                }
            }

            #expect(result == nil)
            release.signal()
            #expect(
                await answered.waitUntilSet(),
                "the work never answered, so nothing was dropped")
        }
    }

    /// The discard rule on its own, with no scheduler in the way: whichever
    /// racer reaches the slot first owns the answer, and the loser's is dropped
    /// rather than written over the winner's. Both directions matter — the
    /// deadline must survive a late answer, and an answer must survive the
    /// deadline that expires just behind it.
    @Test("A filled slot keeps what the winner put in it")
    func mailboxDropsTheLoser() async {
        let expired = Mailbox<String>()
        expired.deliver(nil)
        expired.deliver("late")
        #expect(await expired.take() == nil)

        let answered = Mailbox<String>()
        answered.deliver("answer")
        answered.deliver(nil)
        #expect(await answered.take() == "answer")
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
