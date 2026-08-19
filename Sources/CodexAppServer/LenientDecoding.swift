import Foundation
import os

/// Collection decoding that drops what it cannot read.
///
/// The generated models lean on this, and it is the difference between a single
/// unfamiliar bucket costing the user one row and it costing them the whole
/// Limits section. Codex documents `rateLimitsByLimitId` as an open map keyed by
/// whatever the backend meters, so a key this build has never seen is expected
/// traffic rather than a fault.
///
/// The rule stops at collections on purpose. A malformed *required* field of a
/// single object is a different thing — it means that object is not what the
/// schema says it is — and it still throws, so the caller degrades to
/// "unavailable" rather than rendering half a reading as if it were whole.
extension KeyedDecodingContainer {
    /// Decodes an array, skipping elements that fail.
    func decodeLenient<Element: Decodable>(
        _ type: [Element].Type, forKey key: Key
    ) throws -> [Element] {
        var unkeyed = try nestedUnkeyedContainer(forKey: key)
        return Self.drain(&unkeyed)
    }

    func decodeLenientIfPresent<Element: Decodable>(
        _ type: [Element].Type, forKey key: Key
    ) throws -> [Element]? {
        // `contains` first: `decodeNil(forKey:)` *throws* `keyNotFound` for a
        // key that is not there, so asking it about an absent field turns a
        // documented shape into a decoding failure. `rateLimits: {}` — every
        // field absent rather than null — is exactly that shape.
        guard contains(key), try decodeNil(forKey: key) == false else { return nil }
        // A value of the wrong *container* kind is absent rather than fatal. An
        // optional field arriving as an object where an array was declared says
        // nothing about the required fields beside it, and taking the whole
        // response down over it would discard a reading that is otherwise intact.
        return LenientDecoding.reporting(key) { try decodeLenient(type, forKey: key) }
    }

    /// Decodes a string-keyed map, skipping values that fail.
    func decodeLenient<Value: Decodable>(
        _ type: [String: Value].Type, forKey key: Key
    ) throws -> [String: Value] {
        let nested = try nestedContainer(keyedBy: AnyStringKey.self, forKey: key)
        var result: [String: Value] = [:]
        for entry in nested.allKeys {
            // `try?` rather than a caught error: the one thing to do with an
            // entry that will not decode is leave it out, and a diagnostic per
            // key would fire on every refresh for as long as the schema differs.
            if let value = try? nested.decode(Value.self, forKey: entry) {
                result[entry.stringValue] = value
            }
        }
        return result
    }

    func decodeLenientIfPresent<Value: Decodable>(
        _ type: [String: Value].Type, forKey key: Key
    ) throws -> [String: Value]? {
        guard contains(key), try decodeNil(forKey: key) == false else { return nil }
        // Absent rather than fatal, for the reason the array overload gives.
        return LenientDecoding.reporting(key) { try decodeLenient(type, forKey: key) }
    }

    /// Consumes an unkeyed container, keeping what decodes.
    ///
    /// A failed element still has to be *stepped over*, or the index never
    /// advances and the loop never ends. `Skipped` is that step: it decodes
    /// anything by decoding nothing, which is enough for the container to count
    /// the element as consumed.
    ///
    /// The index is checked anyway. Relying on a `Decodable` that cannot throw
    /// to advance a cursor is relying on `JSONDecoder`'s internals, and the
    /// price of being wrong about them is a hang inside a refresh.
    private static func drain<Element: Decodable>(
        _ container: inout UnkeyedDecodingContainer
    ) -> [Element] {
        var result: [Element] = []
        while !container.isAtEnd {
            let position = container.currentIndex
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(Skipped.self)
            }
            if container.currentIndex == position { break }
        }
        return result
    }
}

enum LenientDecoding {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "quota")

    /// Runs a lenient decode and says so when it could not open the container.
    ///
    /// The one drift worth a diagnostic. A per-element failure would log on
    /// every refresh for as long as the schema differs, which is why `drain`
    /// stays quiet; a whole collection arriving as the wrong *kind* happens once
    /// per protocol change and costs the user every row in it. Silently losing
    /// the Limits section's contents is exactly the silent failure this project
    /// forbids.
    static func reporting<Value>(
        _ key: some CodingKey, _ decode: () throws -> Value
    ) -> Value? {
        do {
            return try decode()
        } catch {
            logger.notice(
                """
                app-server sent \(key.stringValue, privacy: .public) as a shape this build \
                cannot read; it is treated as absent: \(error, privacy: .public)
                """)
            return nil
        }
    }
}

/// A key made from whatever string the payload carried.
struct AnyStringKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Decodes anything by decoding nothing.
///
/// Used only to step past an element that could not be read as its declared
/// type: an initialiser that cannot throw always succeeds, and a successful
/// `decode` is what advances an unkeyed container.
private struct Skipped: Decodable {
    init(from decoder: any Decoder) {}
}
