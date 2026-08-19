import AgentBarCore
import Testing

@testable import AgentBarUI

/// The footer's condition table is ordered and the first match wins. Several
/// conditions can hold at once, so the order is the whole specification.
@Suite("Footer status")
struct FooterStatusTests {

    private func text(_ integrations: [IntegrationStatus]) -> String {
        FooterStatus.summarise(integrations).text
    }

    /// A user who has installed nothing needs to be told that before being told
    /// the endpoint is not receiving events they were never going to send.
    @Test("Nothing set up at all comes first")
    func nothingInstalled() {
        #expect(text([]) == "Not connected")
        #expect(text([UIFixture.status(.claudeCode, .notConnected)]) == "Not connected")
        #expect(
            text([
                UIFixture.status(.claudeCode, .notConnected),
                UIFixture.status(.codex, .notConnected),
            ]) == "Not connected")
    }

    /// `endpointUnavailable` *is* the nil-endpoint case by definition, so it
    /// sits on the red rung rather than the amber one.
    @Test("A dead endpoint outranks every repairable state")
    func notReceivingOutranksRepair() {
        #expect(
            text([
                UIFixture.status(.claudeCode, .needsRepair),
                UIFixture.status(.codex, .notReceiving),
            ]) == "Not receiving events")
    }

    /// A file AgentBar cannot read is not a repair it can offer, and without a
    /// rung of its own it would silently deflate the connected count.
    @Test("An unreadable settings file is a fault of its own")
    func unreadableSettings() {
        #expect(
            text([
                UIFixture.status(.claudeCode, .settingsUnreadable),
                UIFixture.status(.codex, .needsRepair),
            ]) == "Can't read settings")
    }

    @Test("Drift is reported once, not per provider")
    func repairNeeded() {
        #expect(text([UIFixture.status(.claudeCode, .needsRepair)]) == "Repair needed")
    }

    @Test("An untrusted provider is named")
    func untrustedIsNamed() {
        #expect(
            text([
                UIFixture.status(.claudeCode, .connected),
                UIFixture.status(.codex, .notTrusted),
            ]) == "Codex not trusted")
    }

    /// Rule 6 only bites with several integrations — with one, rule 1 has
    /// already covered it.
    @Test("One provider of several missing is named")
    func missingOfSeveralIsNamed() {
        #expect(
            text([
                UIFixture.status(.claudeCode, .notConnected),
                UIFixture.status(.codex, .connected),
            ]) == "Claude Code not connected")
    }

    /// Both numbers come from the integrations actually registered, never from a
    /// constant: a hardcoded denominator would show a permanent `1 of 2` and
    /// report an unbuilt feature as a broken install.
    @Test("Healthy counts what is registered, not what is planned")
    func healthyCountIsHonest() {
        #expect(text([UIFixture.status(.claudeCode, .connected)]) == "1 of 1 connected")
        #expect(
            text([
                UIFixture.status(.claudeCode, .connected),
                UIFixture.status(.codex, .connected),
            ]) == "2 of 2 connected")
    }

    /// Colour never carries state alone, in the footer as anywhere else.
    @Test("Every rung carries a shape as well as a colour")
    func everyRungHasAShape() {
        let cases: [[IntegrationStatus]] = [
            [],
            [UIFixture.status(.claudeCode, .notReceiving)],
            [UIFixture.status(.claudeCode, .settingsUnreadable)],
            [UIFixture.status(.claudeCode, .needsRepair)],
            [UIFixture.status(.claudeCode, .connected), UIFixture.status(.codex, .notTrusted)],
            [UIFixture.status(.claudeCode, .connected)],
        ]
        for integrations in cases {
            let status = FooterStatus.summarise(integrations)
            #expect([.working, .waiting, .failed].contains(status.shape))
        }
    }
}

/// An empty list and "not installed" are different facts, and conflating them
/// turns a quiet morning into a broken app.
@Suite("Panel content")
struct PanelContentTests {

    @Test("A non-empty snapshot always shows the list, whatever the integrations say")
    func sessionsWin() {
        let snapshot = UIFixture.snapshot([UIFixture.session()])
        #expect(
            PanelContent.decide(
                snapshot: snapshot,
                integrations: [UIFixture.status(.claudeCode, .notConnected)]) == .sessions)
    }

    @Test(
        "An empty snapshot plus a state that guarantees silence shows the card",
        arguments: [
            IntegrationCondition.notConnected, .notReceiving, .settingsUnreadable,
        ])
    func silenceShowsTheCard(condition: IntegrationCondition) {
        #expect(
            PanelContent.decide(
                snapshot: .empty,
                integrations: [UIFixture.status(.claudeCode, condition)]) == .onboarding)
    }

    /// A repairable drift is not by itself a reason to claim nothing can
    /// arrive — except `urlNotAllowed`, where every handler is configured and
    /// none of them will run. The app target sets the flag; this is the rule it
    /// feeds.
    @Test("Repairable drift only shows the card when it actually silences everything")
    func repairShowsTheCardOnlyWhenItSilences() {
        #expect(
            PanelContent.decide(
                snapshot: .empty,
                integrations: [
                    UIFixture.status(.claudeCode, .needsRepair, preventsEvents: false)
                ]) == .allQuiet)
        #expect(
            PanelContent.decide(
                snapshot: .empty,
                integrations: [
                    UIFixture.status(.claudeCode, .needsRepair, preventsEvents: true)
                ]) == .onboarding)
    }

    @Test("Empty and healthy is All quiet")
    func allQuiet() {
        #expect(
            PanelContent.decide(
                snapshot: .empty,
                integrations: [UIFixture.status(.claudeCode, .connected)]) == .allQuiet)
    }

    /// Unreachable in the app — every launch path registers Claude Code, with
    /// or without an endpoint — and pinned anyway so the vacuous case is a
    /// decision rather than an accident. An empty card would be worse than a
    /// quiet one, and the footer's rule 1 says `Not connected` beside it.
    @Test("No integrations at all is quiet rather than an empty card")
    func noIntegrations() {
        #expect(PanelContent.decide(snapshot: .empty, integrations: []) == .allQuiet)
    }
}
