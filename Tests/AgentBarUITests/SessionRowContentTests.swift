import AgentBarCore
import Testing

@testable import AgentBarUI

/// Every domain state has to have a representation, and the detail line is
/// where most of them differ.
@Suite("Session row content")
struct SessionRowContentTests {

    private func content(_ session: Session, label: String = "agentbar") -> SessionRowContent {
        SessionRowContent(session: session, projectLabel: label)
    }

    @Test("A working row shows the tool call in monospace")
    func workingShowsTheTool() {
        let row = content(
            UIFixture.session(
                state: .working,
                tool: ToolRef(name: "Bash", invocation: "swift test --parallel")))
        #expect(row.detail?.text == "swift test --parallel")
        #expect(row.detail?.isMonospaced == true)
    }

    /// `ToolInvocation.summarise` has no rule for `TodoWrite`, `ExitPlanMode` or
    /// anything it does not recognise — and `TodoWrite` is among the most
    /// frequently called. The bare name beats dropping the line.
    @Test("A tool with no summary falls back to its own name")
    func fallsBackToTheToolName() {
        let row = content(
            UIFixture.session(state: .working, tool: ToolRef(name: "TodoWrite")))
        #expect(row.detail?.text == "TodoWrite")
    }

    /// `currentTool` is nil from `turnStarted` until the first call opens, and
    /// again between every `toolFinished` and the next `toolStarted` — many
    /// times a second. The line stays, empty, so the row does not jump.
    @Test("A working row with no tool keeps the line and leaves it empty")
    func workingReservesTheLine() {
        let row = content(UIFixture.session(state: .working, tool: nil))
        #expect(row.detail != nil, "the line must be reserved")
        #expect(row.detail?.text == nil, "and nothing may be invented to fill it")
    }

    /// An ordinary working day is mostly idle rows, and the design has to be
    /// calm at that.
    @Test("An idle row is one line tall")
    func idleHasNoLine() {
        #expect(content(UIFixture.session(state: .idle)).detail == nil)
    }

    @Test("A failed row shows the reason, in monospace")
    func failedShowsTheReason() {
        let row = content(UIFixture.session(state: .failed(reason: "Rate limit reached")))
        #expect(row.detail?.text == "Rate limit reached")
        #expect(row.detail?.isMonospaced == true)
    }

    /// The waiting row is complete without a second line: the full-row wash is
    /// what makes it unmissable.
    @Test("A waiting row with no question has no line")
    func waitingWithoutAQuestion() {
        #expect(content(UIFixture.session(state: .waitingInput(question: nil))).detail == nil)
    }

    /// ADR-0005. Proportional, not monospace: a question is text a person will
    /// read, not something a machine printed.
    @Test("A waiting row shows the question when there is one")
    func waitingWithAQuestion() {
        let row = content(
            UIFixture.session(state: .waitingInput(question: "Which database?")))
        #expect(row.detail?.text == "Which database?")
        #expect(row.detail?.isMonospaced == false)
    }

    /// `waitingPermission` collapses to the same row on purpose: from the user's
    /// side both mean "go look at that agent".
    @Test("A permission wait renders as an ordinary waiting row")
    func permissionWaitIsTheSameRow() {
        let session = UIFixture.session(
            state: .waitingPermission(PermissionRequestRef(id: PermissionRequestID("p"))))
        #expect(content(session).stateLabel == "Waiting")
        #expect(content(session).detail == nil)
    }

    /// The corner shows how long it has *read* as unknown; the line shows the
    /// full silence. They are different numbers and must not be swapped.
    @Test("An unknown row explains the silence, and the two numbers differ")
    func unknownExplainsTheSilence() {
        let row = content(
            UIFixture.session(
                state: .unknown, timeInState: .seconds(180), silence: .seconds(1080)))
        #expect(row.duration == "3m")
        #expect(row.detail?.text == "Stopped reporting · last seen 18m ago")
        #expect(row.detail?.isMonospaced == false)
    }

    @Test("The subagent pill appears only when there is something to count")
    func subagentPill() {
        #expect(content(UIFixture.session(subagents: 0)).subagentPill == nil)
        #expect(content(UIFixture.session(subagents: 2)).subagentPill == "+2")
    }

    /// `4m 12s` is read out as letters, so the label spells the duration.
    @Test("The accessibility label carries provider, state, project and duration")
    func accessibilityLabel() {
        let row = content(
            UIFixture.session(state: .waitingInput(question: nil), subagents: 2),
            label: "agentbar-web")
        #expect(
            row.accessibilityLabel
                == "Claude Code, Waiting, agentbar-web, 38 seconds, 2 subagents")
    }

    /// `ProjectRef.root` is a directory, so `NSWorkspace.open` reaches Finder
    /// unless the user changed the handler. The copy says exactly that rather
    /// than promising an editor AgentBar cannot identify.
    @Test("The row promises only what it can deliver")
    func openCopyIsHonest() {
        let row = content(UIFixture.session(), label: "agentbar-web")
        #expect(row.openHint == "Open agentbar-web in the default application")
        #expect(row.tooltip.contains("Started"))
        #expect(row.tooltip.contains("running 10m"))
    }
}

/// The card row and the footer read the same fact rather than each deriving it,
/// so the mapping from condition to action, indicator and copy is pinned here.
@Suite("Integration conditions")
struct IntegrationConditionTests {

    /// AgentBar refuses to write over a file it could not read, and the UI must
    /// not offer to.
    @Test("An unreadable settings file gets no write action")
    func unreadableOffersNoWrite() {
        #expect(IntegrationCondition.settingsUnreadable.action == .revealInFinder)
    }

    @Test("A healthy integration offers nothing to press")
    func healthyOffersNothing() {
        #expect(IntegrationCondition.connected.action == nil)
    }

    @Test(
        "Every other condition offers exactly one action",
        arguments: [
            (IntegrationCondition.notConnected, IntegrationAction.connect),
            (.needsRepair, .repair),
            (.notTrusted, .trust),
            (.notReceiving, .retry),
        ])
    func actionsPerCondition(condition: IntegrationCondition, action: IntegrationAction) {
        #expect(condition.action == action)
    }

    /// Colour never carries state alone. `notConnected` is the one row with no
    /// indicator, because nothing has happened yet to indicate.
    @Test("Every condition that shows an indicator pairs it with a shape")
    func indicatorsCarryShapes() {
        for condition in IntegrationCondition.allCases where condition != .notConnected {
            #expect(condition.indicator != nil, "\(condition) has no indicator")
        }
        #expect(IntegrationCondition.notConnected.indicator == nil)
    }

    /// Only `connected` counts towards the footer's `N of N`.
    @Test("Exactly one condition counts as healthy")
    func onlyConnectedIsHealthy() {
        #expect(IntegrationCondition.allCases.filter(\.isHealthy) == [.connected])
    }

    /// Every degraded condition guarantees silence by default; the app target
    /// overrides only `needsRepair`, where a drift may or may not silence the
    /// handlers.
    @Test("Only a connected integration is assumed to be delivering")
    func preventsEventsByDefault() {
        for condition in IntegrationCondition.allCases {
            #expect(condition.preventsEventsByDefault == (condition != .connected))
        }
    }
}
