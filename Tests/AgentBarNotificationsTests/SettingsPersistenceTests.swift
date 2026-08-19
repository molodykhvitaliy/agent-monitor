import AgentBarCore
import Foundation
import Testing

@testable import AgentBarNotifications

/// The settings file is the one thing here that outlives a launch, so it has to
/// survive being written by another version of AgentBar.
@Suite("Notification settings persistence")
struct SettingsPersistenceTests {

    @Test("A full value round-trips")
    func roundTrip() throws {
        var settings = NotificationSettings()
        settings.isEnabled = false
        settings.quietHours = QuietHours(isEnabled: true, startMinute: 90, endMinute: 500)
        settings.focusSuppression = FocusSuppression(
            isEnabled: true,
            applications: [
                SuppressingApplication(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
            ])
        settings.update(
            EventPreference(
                provider: .codex, event: .failed, isEnabled: false, sound: .named("Boom.aiff")))

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(NotificationSettings.self, from: data) == settings)
    }

    @Test("Every provider and event has a cell by default")
    func defaultsAreComplete() {
        let settings = NotificationSettings()
        #expect(
            settings.preferences.count == Provider.allCases.count * NotificationEvent.allCases.count
        )
        #expect(settings.preferences.allSatisfy { $0.isEnabled })
    }

    /// A settings file written before a provider existed has no row for it, and
    /// the honest answer to "should AgentBar notify about it?" is the default —
    /// never silence.
    @Test("A missing cell reads as the default rather than as off")
    func missingCellDefaultsOn() {
        let settings = NotificationSettings(preferences: [])
        #expect(settings.preference(for: .codex, event: .question).isEnabled)
        #expect(
            settings.completed().preferences.count
                == Provider.allCases.count * NotificationEvent.allCases.count)
    }

    /// Losing a preference is survivable; quietly disabling every notification
    /// is not.
    @Test("An unreadable stored value degrades to the defaults, never to silence")
    func unreadableDataFallsBackToDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "agentbar.tests.\(UUID().uuidString)"))
        defaults.set(Data("this is not json".utf8), forKey: "notifications.settings")
        let store = UserDefaultsNotificationSettings(defaults: defaults)

        let loaded = store.load()
        #expect(loaded.isEnabled)
        #expect(loaded.preferences.allSatisfy { $0.isEnabled })
    }

    /// Losing one row to a downgrade is survivable; losing the matrix is not.
    /// The synthesised conformance would fail the whole value on a single
    /// unrecognised provider, and `load()` would then replace every preference
    /// the user had set.
    @Test("One unreadable cell costs one cell, not the whole matrix")
    func oneBadRowDoesNotWipeTheRest() throws {
        let json = """
            {
              "version": 1,
              "isEnabled": false,
              "preferences": [
                {"provider": "claudeCode", "event": "failed", "isEnabled": false,
                 "sound": {"silent": {}}},
                {"provider": "cursor", "event": "failed", "isEnabled": true,
                 "sound": {"systemDefault": {}}},
                {"provider": "claudeCode", "event": "question", "isEnabled": true,
                 "sound": {"named": {"_0": "Chime.aiff"}}}
              ],
              "quietHours": {"isEnabled": true, "startMinute": 60, "endMinute": 120},
              "focusSuppression": {"isEnabled": false, "applications": []}
            }
            """
        let decoded = try JSONDecoder().decode(
            NotificationSettings.self, from: Data(json.utf8))

        #expect(!decoded.isEnabled)
        #expect(decoded.quietHours.startMinute == 60)
        // The two rows this build understands survived the one it did not.
        #expect(!decoded.preference(for: .claudeCode, event: .failed).isEnabled)
        #expect(
            decoded.preference(for: .claudeCode, event: .question).sound
                == .named("Chime.aiff"))
        #expect(decoded.preferences.count == 2)
        // And the missing cells default to on rather than to silence.
        #expect(decoded.completed().preference(for: .codex, event: .waiting).isEnabled)
    }

    /// A file written by a version that had not invented a key yet still reads.
    @Test("Absent keys read as their defaults rather than as a corrupt file")
    func absentKeysDegrade() throws {
        let decoded = try JSONDecoder().decode(
            NotificationSettings.self, from: Data("{}".utf8))
        #expect(decoded.isEnabled)
        #expect(!decoded.quietHours.isEnabled)
        #expect(decoded.preferences.isEmpty)
        #expect(
            decoded.completed().preferences.count
                == Provider.allCases.count * NotificationEvent.allCases.count)
    }

    @Test("An empty store is the defaults")
    func emptyStore() throws {
        let defaults = try #require(UserDefaults(suiteName: "agentbar.tests.\(UUID().uuidString)"))
        #expect(
            UserDefaultsNotificationSettings(defaults: defaults).load() == NotificationSettings())
    }

    @Test("What was saved is what comes back")
    func savesAndLoads() throws {
        let defaults = try #require(UserDefaults(suiteName: "agentbar.tests.\(UUID().uuidString)"))
        let store = UserDefaultsNotificationSettings(defaults: defaults)
        var settings = NotificationSettings()
        settings.isEnabled = false
        store.save(settings)
        #expect(!store.load().isEnabled)
    }
}
