import AgentBarJSON
import Foundation
import Testing

@testable import ClaudeCodeAdapter

/// Loads the recorded payloads.
///
/// The suites read bytes rather than re-encoding a decoded structure: a decoder
/// tested against JSON that a test wrote is a decoder tested against itself, and
/// the point of these files is that Claude Code wrote them.
enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
            "fixture \(name).json is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    /// One recorded session, as the sequence of payload bodies it arrived as.
    static func session(_ name: String) throws -> [Data] {
        let array = try #require(JSONParser.parse(try data(name)).array, "\(name) is not an array")
        return array.map { JSONWriter.data($0) }
    }
}
