import AgentBarCore
import Foundation
import Testing

@testable import AgentBarPower

/// The setting behind the footer's two-state button and the window's
/// three-state picker, and the arithmetic that keeps them consistent.
@MainActor
@Suite("Caffeine settings")
struct SettingsTests {

    @Test("The default follows the agents")
    func defaults() {
        #expect(CaffeineSettings().mode == .whileWorking)
    }

    @Test("Turning Caffeine off and on again keeps the mode the window chose")
    func toggleRestoresTheChosenMode() {
        var settings = CaffeineSettings()
        settings.setMode(.always)
        settings.toggle()
        #expect(settings.mode == .never)
        settings.toggle()
        #expect(settings.mode == .always, "the toggle must not silently demote `always`")
    }

    @Test("A toggle from the default comes back to the default")
    func toggleFromWhileWorking() {
        var settings = CaffeineSettings()
        settings.toggle()
        #expect(settings.mode == .never)
        settings.toggle()
        #expect(settings.mode == .whileWorking)
    }

    /// A stored `activeMode` of `never` would make the footer button a switch
    /// that only ever turns Caffeine off — pressed twice, nothing happens.
    @Test("An inactive remembered mode is repaired on the way in")
    func inactiveRememberedModeIsRepaired() {
        #expect(CaffeineSettings(mode: .never, activeMode: .never).activeMode == .whileWorking)
        #expect(CaffeineSettings(mode: .always, activeMode: .never).activeMode == .always)

        var settings = CaffeineSettings(mode: .never, activeMode: .never)
        settings.toggle()
        #expect(settings.mode.isActive)
    }

    @Test("The choice survives a round trip through the defaults")
    func persistence() {
        let defaults = UserDefaults(suiteName: "caffeine.tests.\(UUID().uuidString)")
        #expect(defaults != nil)
        guard let defaults else { return }
        defer { defaults.removeObject(forKey: UserDefaultsCaffeineSettings.defaultsKey) }

        let store = UserDefaultsCaffeineSettings(defaults: defaults)
        #expect(store.load().mode == .whileWorking, "an empty store reads as the default")

        var settings = CaffeineSettings()
        settings.setMode(.always)
        store.save(settings)
        #expect(UserDefaultsCaffeineSettings(defaults: defaults).load().mode == .always)
    }

    /// A blob this build cannot read is a bug or a downgrade. Degrading to
    /// `never` would leave a user whose Mac has stopped staying awake with
    /// nothing anywhere saying why.
    @Test("An unreadable stored value degrades to the default, not to off")
    func unreadableDegradesToDefault() {
        let defaults = UserDefaults(suiteName: "caffeine.tests.\(UUID().uuidString)")
        #expect(defaults != nil)
        guard let defaults else { return }
        defer { defaults.removeObject(forKey: UserDefaultsCaffeineSettings.defaultsKey) }

        defaults.set(Data("not json".utf8), forKey: UserDefaultsCaffeineSettings.defaultsKey)
        #expect(UserDefaultsCaffeineSettings(defaults: defaults).load().mode == .whileWorking)
    }

    /// The invariant has to survive the way the value actually arrives, which is
    /// a decode and not the memberwise initialiser. A stored pair of `never`s
    /// would otherwise leave the footer button a dead switch that outlives a
    /// relaunch.
    @Test("A stored value that breaks the invariant is repaired on decode")
    func decodeRepairsTheInvariant() throws {
        let stored = Data(#"{"mode":"never","activeMode":"never"}"#.utf8)
        var decoded = try JSONDecoder().decode(CaffeineSettings.self, from: stored)
        #expect(decoded.activeMode == .whileWorking)
        decoded.toggle()
        #expect(decoded.mode == .whileWorking)
    }

    @Test("A stored choice decodes to itself")
    func decodeRoundTrips() throws {
        var settings = CaffeineSettings()
        settings.setMode(.always)
        settings.toggle()
        let restored = try JSONDecoder().decode(
            CaffeineSettings.self, from: try JSONEncoder().encode(settings))
        #expect(restored.mode == .never)
        #expect(restored.activeMode == .always)
    }

    @Test("Setting a mode writes it through")
    func controllerPersists() async {
        let store = InMemoryCaffeineSettings()
        let controller = CaffeineController(assertion: RecordingAssertion(), settings: store)
        controller.setMode(.always)
        #expect(store.load().mode == .always)
        #expect(controller.mode == .always)
        // Shown at once, without waiting for an evaluation that has no source to
        // read: a picker whose `get` reverts after a `set` reads as broken.
        #expect(controller.reading.mode == .always)
    }

    @Test("`never` never takes an assertion, however busy the agents are")
    func neverHoldsNothing() async {
        let clock = ManualTimeSource()
        let store = SessionStore(clock: clock)
        let assertion = RecordingAssertion()
        let controller = CaffeineController(
            assertion: assertion,
            settings: InMemoryCaffeineSettings(CaffeineSettings(mode: .never)))
        await controller.start { await store.snapshot() }

        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.evaluate()
        #expect(!assertion.isHeld)
        #expect(controller.reading.workingSessionCount == 1, "the count is still reported")
    }

    @Test("`always` holds with nothing running, and stops when switched off")
    func alwaysHoldsUntilSwitchedOff() async {
        let store = SessionStore(clock: ManualTimeSource())
        let assertion = RecordingAssertion()
        let controller = CaffeineController(
            assertion: assertion,
            settings: InMemoryCaffeineSettings(CaffeineSettings(mode: .always)))
        await controller.start { await store.snapshot() }
        #expect(assertion.isHeld)

        controller.setMode(.never)
        await controller.evaluate()
        #expect(!assertion.isHeld)
    }

    @Test("Switching the mode on while an agent works takes the assertion at once")
    func switchingOnDuringWorkHolds() async {
        let store = SessionStore(clock: ManualTimeSource())
        let assertion = RecordingAssertion()
        let controller = CaffeineController(
            assertion: assertion,
            settings: InMemoryCaffeineSettings(CaffeineSettings(mode: .never)))
        await controller.start { await store.snapshot() }
        await store.apply(Fixture.event(.turnStarted, at: 1))
        await controller.evaluate()
        #expect(!assertion.isHeld)

        controller.toggle()
        await controller.evaluate()
        #expect(assertion.isHeld)
    }
}
