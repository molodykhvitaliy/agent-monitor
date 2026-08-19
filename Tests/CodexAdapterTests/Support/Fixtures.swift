import AgentBarJSON
import Foundation
import Testing

/// Loads the hook payloads.
///
/// The suites read bytes rather than re-encoding a decoded structure: a decoder
/// tested against JSON a test wrote is a decoder tested against itself. See
/// `Fixtures/README.md` for where these came from and what is still owed.
enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
            "fixture \(name).json is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    /// One session, as the sequence of payload bodies it arrived as.
    static func session(_ name: String) throws -> [Data] {
        let array = try #require(JSONParser.parse(try data(name)).array, "\(name) is not an array")
        return array.map { JSONWriter.data($0) }
    }
}
