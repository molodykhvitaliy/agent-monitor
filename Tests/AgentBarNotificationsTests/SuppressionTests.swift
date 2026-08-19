import AgentBarCore
import Foundation
import Testing

@testable import AgentBarNotifications

/// Quiet hours are a window on the clock face, and the interesting case is the
/// ordinary one: a window that crosses midnight.
@Suite("Quiet hours")
struct QuietHoursTests {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: "UTC") else { return calendar }
        calendar.timeZone = zone
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19
        components.hour = hour
        components.minute = minute
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components) ?? Date()
    }

    @Test("A window inside one day contains only that stretch")
    func sameDay() {
        let hours = QuietHours(isEnabled: true, startMinute: 9 * 60, endMinute: 17 * 60)
        #expect(!hours.contains(at(8, 59), calendar: calendar))
        #expect(hours.contains(at(9), calendar: calendar))
        #expect(hours.contains(at(16, 59), calendar: calendar))
        // The end is exclusive: 17:00 is already out.
        #expect(!hours.contains(at(17), calendar: calendar))
    }

    @Test("A window that ends earlier than it starts crosses midnight")
    func crossesMidnight() {
        let hours = QuietHours(isEnabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        #expect(hours.contains(at(23), calendar: calendar))
        #expect(hours.contains(at(0, 30), calendar: calendar))
        #expect(hours.contains(at(7, 59), calendar: calendar))
        #expect(!hours.contains(at(8), calendar: calendar))
        #expect(!hours.contains(at(12), calendar: calendar))
        #expect(hours.contains(at(22), calendar: calendar))
    }

    /// Both readings are defensible from the numbers alone, and only one of them
    /// can silently swallow every notification AgentBar exists to deliver.
    @Test("A zero-length window is never quiet, not always quiet")
    func zeroLengthIsNeverQuiet() {
        let hours = QuietHours(isEnabled: true, startMinute: 60, endMinute: 60)
        for hour in 0..<24 {
            #expect(!hours.contains(at(hour), calendar: calendar))
        }
    }

    @Test("Disabled means never, whatever the numbers say")
    func disabled() {
        let hours = QuietHours(isEnabled: false, startMinute: 0, endMinute: 23 * 60)
        #expect(!hours.contains(at(12), calendar: calendar))
    }

    @Test("Minutes outside a day wrap rather than escaping the range")
    func wrapsOutOfRangeMinutes() {
        let hours = QuietHours(isEnabled: true, startMinute: 25 * 60, endMinute: -60)
        #expect(hours.startMinute == 60)
        #expect(hours.endMinute == 23 * 60)
    }
}

@Suite("Focus suppression")
struct FocusSuppressionTests {

    private let vscode = SuppressingApplication(
        bundleIdentifier: "com.microsoft.VSCode", name: "Visual Studio Code")

    @Test("Off by default with nothing listed")
    func defaultsToOff() {
        let suppression = FocusSuppression()
        #expect(!suppression.isEnabled)
        #expect(suppression.applications.isEmpty)
    }

    @Test("A listed application frontmost suppresses; another does not")
    func matchesByBundleIdentifier() {
        let suppression = FocusSuppression(isEnabled: true, applications: [vscode])
        #expect(suppression.suppresses(bundleIdentifier: "com.microsoft.VSCode") != nil)
        #expect(suppression.suppresses(bundleIdentifier: "com.apple.Terminal") == nil)
        #expect(suppression.suppresses(bundleIdentifier: nil) == nil)
    }

    @Test("A list that is not switched on suppresses nothing")
    func disabledListIsInert() {
        let suppression = FocusSuppression(isEnabled: false, applications: [vscode])
        #expect(suppression.suppresses(bundleIdentifier: "com.microsoft.VSCode") == nil)
    }
}

/// The gate reports **which** reason stopped a notification, and the order is
/// the specification: a user who turned notifications off should be told that,
/// not that it is half past ten.
@Suite("Notification gate")
struct GateTests {

    private let calendar = Calendar(identifier: .gregorian)

    private func decide(
        settings: NotificationSettings,
        authorization: NotificationAuthorization = .authorized,
        frontmost: String? = nil,
        event: NotificationEvent = .finished
    ) -> NotificationSuppression? {
        NotificationGate(settings: settings, calendar: calendar)
            .suppression(
                for: Fixture.draft(event: event),
                authorization: authorization,
                frontmostBundleIdentifier: frontmost,
                now: Fixture.epoch)
    }

    @Test("Nothing stops a notification when everything is in order")
    func passes() {
        #expect(decide(settings: NotificationSettings()) == nil)
    }

    @Test("The global switch outranks every other reason")
    func globalSwitchFirst() {
        var settings = NotificationSettings()
        settings.isEnabled = false
        settings.quietHours = QuietHours(isEnabled: true, startMinute: 0, endMinute: 23 * 60)
        #expect(decide(settings: settings) == .notificationsOff)
    }

    @Test("An unauthorised app is reported as such, not as a disabled event")
    func authorizationBeatsMatrix() {
        var settings = NotificationSettings()
        settings.update(
            EventPreference(
                provider: .claudeCode, event: .finished, isEnabled: false, sound: .systemDefault))
        #expect(decide(settings: settings, authorization: .denied) == .notAuthorized)
        #expect(decide(settings: settings, authorization: .notDetermined) == .notAuthorized)
    }

    /// Provisional delivery is quiet, not absent, so posting is still worth it.
    @Test("Provisional authorisation still delivers")
    func provisionalDelivers() {
        #expect(decide(settings: NotificationSettings(), authorization: .provisional) == nil)
    }

    @Test("A cell turned off in the matrix stops only that cell")
    func matrixCell() {
        var settings = NotificationSettings()
        settings.update(
            EventPreference(
                provider: .claudeCode, event: .finished, isEnabled: false, sound: .systemDefault))
        #expect(decide(settings: settings, event: .finished) == .eventDisabled)
        #expect(decide(settings: settings, event: .failed) == nil)
    }

    @Test("A frontmost application on the list is named in the reason")
    func focusedApplication() {
        var settings = NotificationSettings()
        settings.focusSuppression = FocusSuppression(
            isEnabled: true,
            applications: [
                SuppressingApplication(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
            ])
        #expect(
            decide(settings: settings, frontmost: "com.apple.dt.Xcode")
                == .applicationFocused(name: "Xcode"))
    }
}
