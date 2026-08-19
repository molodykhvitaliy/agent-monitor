import Testing

@testable import AgentBarUI

/// The footer's Caffeine button and the settings section read the same value,
/// so what that value says is the whole of the surface's correctness.
@MainActor
@Suite("Caffeine indicator")
struct CaffeineIndicatorTests {

    @Test("Holding, armed, off and failed are four distinct silhouettes")
    func appearancesAreDistinguishable() {
        let indicators = [
            CaffeineIndicator(setting: .whileWorking, isHolding: true, workingSessionCount: 1),
            CaffeineIndicator(setting: .whileWorking, isHolding: false),
            CaffeineIndicator(setting: .never, isHolding: false),
            CaffeineIndicator(setting: .whileWorking, failure: "IOKit said no"),
        ]
        let appearances = indicators.map(\.appearance)
        #expect(appearances == [.holding, .armed, .off, .failed])
        // Colour never carries a state on its own here any more than it does in
        // a session row: every appearance has its own symbol.
        #expect(Set(indicators.map(\.symbolName)).count == 4)
    }

    /// "On and holding" and "on and nothing needs it" are different facts. An
    /// indicator that showed the same thing for both would tell a user the Mac
    /// is being kept awake when it is not.
    @Test("On with nothing working does not read as holding")
    func armedIsNotHolding() {
        let armed = CaffeineIndicator(setting: .whileWorking, isHolding: false)
        #expect(armed.appearance == .armed)
        #expect(
            armed.summary
                != CaffeineIndicator(
                    setting: .whileWorking, isHolding: true, workingSessionCount: 1
                ).summary)
    }

    /// A refused assertion must never be drawn as a held one: the only other
    /// symptom is a Mac that fell asleep during a build, hours later.
    @Test("A fault outranks everything, even while something is still held")
    func faultOutranksHolding() {
        let indicator = CaffeineIndicator(
            setting: .whileWorking, isHolding: true, workingSessionCount: 1,
            failure: "IOPMAssertionSetProperty failed")
        #expect(indicator.appearance == .failed)
        #expect(indicator.summary == "IOPMAssertionSetProperty failed")
        #expect(indicator.tint == .stateFailed)
    }

    @Test("`always` says it is keeping the Mac awake without claiming a session")
    func alwaysDoesNotInventSessions() {
        let indicator = CaffeineIndicator(
            setting: .always, isHolding: true, workingSessionCount: 0)
        #expect(indicator.appearance == .holding)
        #expect(!indicator.summary.contains("0"))
    }

    @Test("The button says what pressing it will do, both ways round")
    func toggleLabelFollowsTheSetting() {
        #expect(
            CaffeineIndicator(setting: .never).toggleLabel
                != CaffeineIndicator(setting: .whileWorking).toggleLabel)
        #expect(
            CaffeineIndicator(setting: .always).toggleLabel
                == CaffeineIndicator(setting: .whileWorking).toggleLabel)
    }

    /// The design brief lists this among the limitations the interface must
    /// state rather than hide, and the settings section is where it lives.
    @Test("The limitation names the lid, the display and the battery")
    func limitationIsHonest() {
        let text = CaffeineIndicator.limitation
        #expect(text.contains("lid"))
        #expect(text.contains("display"))
        #expect(text.contains("battery"))
    }

    @Test("The panel forwards the footer button to the assembly")
    func panelForwardsTheToggle() {
        let services = StubServices()
        let model = PanelModel(services: services)
        model.toggleCaffeine()
        #expect(services.caffeineToggles == 1)
    }

    @Test("The settings window writes a new setting through, once")
    func settingsWritesThrough() {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        model.setCaffeine(.always)
        #expect(services.caffeineWrites == [.always])
        #expect(model.caffeine.setting == .always)

        // Choosing what is already chosen writes nothing: every other setting
        // in this window behaves that way, and a Picker re-reports its value.
        model.setCaffeine(.always)
        #expect(services.caffeineWrites == [.always])
    }
}
