import AgentBarCore
import Testing

@testable import AgentBarPower

/// The whole decision, tested as a value. Everything else in the module either
/// produces its inputs or carries out its answer.
@Suite("Caffeine demand")
struct DemandTests {

    @Test("Working sessions are what the Mac is kept awake for")
    func holdsWhileWorking() {
        let demand = CaffeineDemand.decide(
            mode: .whileWorking, snapshot: Fixture.snapshot(states: [.working]))
        #expect(demand.shouldHold)
        #expect(demand.workingSessionCount == 1)
    }

    @Test(
        "No other state is worth keeping the Mac awake for",
        arguments: [
            SessionState.idle,
            .waitingInput(question: nil),
            .waitingPermission(PermissionRequestRef(id: PermissionRequestID("request-1"))),
            .failed(reason: "exit 1"),
            .unknown,
        ]
    )
    func releasesForEveryOtherState(state: SessionState) {
        let demand = CaffeineDemand.decide(
            mode: .whileWorking, snapshot: Fixture.snapshot(states: [state]))
        #expect(!demand.shouldHold)
        #expect(demand.workingSessionCount == 0)
    }

    /// `waiting` in particular: an agent blocked on a person is not one the Mac
    /// has to stay awake for, and a night spent awake because nobody answered a
    /// prompt is the failure this rules out.
    @Test("One working session among several holds; a list with none does not")
    func mixedSnapshots() {
        let mixed = CaffeineDemand.decide(
            mode: .whileWorking,
            snapshot: Fixture.snapshot(states: [.idle, .working, .waitingInput(question: nil)]))
        #expect(mixed.shouldHold)
        #expect(mixed.workingSessionCount == 1)

        let quiet = CaffeineDemand.decide(
            mode: .whileWorking, snapshot: Fixture.snapshot(states: [.idle, .unknown]))
        #expect(!quiet.shouldHold)
    }

    @Test("An empty store holds nothing")
    func emptySnapshot() {
        #expect(
            !CaffeineDemand.decide(mode: .whileWorking, snapshot: Fixture.snapshot(states: []))
                .shouldHold)
    }

    @Test("`never` refuses even a room full of working agents")
    func neverHolds() {
        let demand = CaffeineDemand.decide(
            mode: .never, snapshot: Fixture.snapshot(states: [.working, .working]))
        #expect(!demand.shouldHold)
        // Still counted: the interface says "2 working" beside a Caffeine that
        // is off, which is the whole point of the setting being visible.
        #expect(demand.workingSessionCount == 2)
    }

    @Test("`always` holds with nothing running at all")
    func alwaysHolds() {
        #expect(
            CaffeineDemand.decide(mode: .always, snapshot: Fixture.snapshot(states: []))
                .shouldHold)
    }

    /// The line `pmset -g assertions` shows. It is the only way to tell from
    /// outside the app why the Mac is awake, so it names the project when it
    /// can.
    @Test("The details line says why, and names the project when there is one")
    func detailsExplain() {
        #expect(
            CaffeineDemand.decide(
                mode: .whileWorking, snapshot: Fixture.snapshot(states: [.working])
            ).details == "1 agent session working in agentbar")
        #expect(
            CaffeineDemand.decide(
                mode: .whileWorking, snapshot: Fixture.snapshot(states: [.working, .working])
            ).details == "2 agent sessions working")
        #expect(
            CaffeineDemand.decide(
                mode: .whileWorking, snapshot: Fixture.snapshot(states: [.idle])
            ).details == "No agent is working")
        #expect(
            CaffeineDemand.decide(mode: .never, snapshot: Fixture.snapshot(states: [.working]))
                .details == "Caffeine is off")
    }
}
