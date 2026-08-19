import Foundation
import Testing

/// Recorded and derived App Server payloads — see `Fixtures/README.md`.
enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
            "fixture \(name).json is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    static func decode<Payload: Decodable>(_ type: Payload.Type, _ name: String) throws -> Payload {
        try JSONDecoder().decode(type, from: try data(name))
    }

    /// A fixture wrapped as the `result` of a JSON-RPC reply, which is the form
    /// the client actually receives.
    static func reply(id: Int, _ name: String) throws -> Data {
        let body = String(data: try data(name), encoding: .utf8) ?? "null"
        return Data(#"{"id":\#(id),"result":\#(body)}"#.utf8)
    }
}
