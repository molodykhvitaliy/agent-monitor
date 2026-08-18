import Foundation
import Testing

@testable import AgentBarCore

/// Duplicates are ordinary. Hooks are delivered asynchronously and may be
/// retried, and AgentBar coexists with hooks the user already had — a handler
/// registered twice delivers every event twice.
@Suite("Duplicate deliveries")
struct DeduplicationTests {

    @Test("The same tool call delivered twice is counted once")
    func repeatedToolStartIsIgnored() async {
        let store = SessionStore(clock: ManualTimeSource())
        let start = Fixture.event(.toolStarted, tool: Fixture.bash, toolUseId: "tool-1")

        await store.apply(start)
        let second = await store.apply(start)

        #expect(second.ignoreReason == .duplicate)
        #expect(await store.snapshot().onlySession?.currentTool == Fixture.bash)
    }

    /// Subagents are counted in a set, so a repeat costs nothing and needs no
    /// fingerprint. Fingerprinting them would be worse than useless: an
    /// `agent_id` that recurs across invocations would silently lose the second
    /// start and the panel would show a subagent that is not running.
    @Test("A second start for the same subagent does not inflate the count")
    func repeatedSubagentStartIsHarmless() async {
        let store = SessionStore(clock: ManualTimeSource())
        let start = Fixture.event(.subagentStarted, agent: Fixture.subagent("a"))

        await store.apply(start)
        let second = await store.apply(start)

        #expect(second.isUnchanged)
        #expect(await store.snapshot().onlySession?.activeSubagentCount == 1)
    }

    @Test("A subagent may run again after it has stopped")
    func subagentIdMayRecur() async {
        let store = SessionStore(clock: ManualTimeSource())
        let agent = Fixture.subagent("a")
        await store.apply(Fixture.event(.subagentStarted, at: 1, agent: agent))
        await store.apply(Fixture.event(.subagentStopped, at: 2, agent: agent))
        await store.apply(Fixture.event(.subagentStarted, at: 3, agent: agent))

        #expect(await store.snapshot().onlySession?.activeSubagentCount == 1)
    }

    @Test("A second stop for the same subagent cannot drive the count negative")
    func repeatedSubagentStopIsHarmless() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.subagentStarted, agent: Fixture.subagent("a")))
        let stop = Fixture.event(.subagentStopped, at: 1, agent: Fixture.subagent("a"))

        await store.apply(stop)
        await store.apply(stop)

        #expect(await store.snapshot().onlySession?.activeSubagentCount == 0)
    }

    @Test("Distinct tool calls are not confused for each other")
    func distinctToolCallsAreKept() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(
            Fixture.event(.toolStarted, at: 1, tool: Fixture.bash, toolUseId: "tool-1"))
        let other = await store.apply(
            Fixture.event(.toolStarted, at: 2, tool: Fixture.edit, toolUseId: "tool-2"))

        #expect(other.ignoreReason == nil)
        #expect(await store.snapshot().onlySession?.currentTool == Fixture.edit)
    }

    @Test("Two prompts in a row are two prompts, not one delivered twice")
    func repeatedPromptsAreBothApplied() async {
        let store = SessionStore(clock: ManualTimeSource())
        await store.apply(Fixture.event(.turnStarted, at: 1))
        await store.apply(Fixture.event(.turnFinished, at: 2))
        let second = await store.apply(Fixture.event(.turnStarted, at: 3))

        #expect(second.ignoreReason == nil)
        #expect(await store.snapshot().onlySession?.state == .working)
    }

    /// A duplicate proves a process is still posting, but it says nothing new,
    /// and the event it repeats already fed the watchdog. Letting it renew the
    /// clock would mean a session whose every delivery is refused could be
    /// believed for ever — the one thing the watchdog exists to prevent.
    @Test("A stream of duplicates cannot keep a dead session believed")
    func duplicatesDoNotRenewTheWatchdog() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        let start = Fixture.event(.toolStarted, tool: Fixture.bash, toolUseId: "tool-1")
        await store.apply(start)

        clock.advance(by: .minutes(40))
        #expect(await store.apply(start).ignoreReason == .duplicate)
        clock.advance(by: .minutes(40))

        #expect(await store.snapshot().onlySession?.state == .unknown)
    }

    @Test("Fingerprints of a finished session do not crowd out live ones")
    func endedSessionsAreForgotten() async {
        let store = SessionStore(clock: ManualTimeSource())
        let start = Fixture.event(.toolStarted, tool: Fixture.bash, toolUseId: "tool-1")
        await store.apply(start)
        await store.apply(Fixture.event(.sessionEnded, at: 1))

        // A brand new session reusing the same tool id is not a duplicate.
        let readmitted = await store.apply(
            Fixture.event(.toolStarted, at: 2, tool: Fixture.bash, toolUseId: "tool-1"))
        #expect(readmitted.ignoreReason == nil)
    }
}
