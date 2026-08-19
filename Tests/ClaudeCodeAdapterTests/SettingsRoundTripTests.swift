import AgentBarJSON
import Foundation
import Testing

@testable import ClaudeCodeAdapter

/// The claim the whole installer rests on: a settings file read and written back
/// unchanged is unchanged **byte for byte**.
///
/// It lives here rather than with the other `AgentBarJSON` suites because the
/// evidence is a recorded `settings.json`, and the fixture belongs to the
/// adapter that owns that file.
@Suite("Settings round trip")
struct SettingsRoundTripTests {

    @Test("A settings file written this way round-trips byte for byte")
    func roundTripsRealSettings() throws {
        let original = try Fixtures.data("settings-with-foreign-hooks")
        let rendered = JSONWriter.data(try JSONParser.parse(original))
        #expect(rendered == original)
    }
}
