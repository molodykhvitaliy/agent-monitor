import Foundation

/// JSON as this module needs it: ordered, lossless, and free of `Any`.
///
/// Foundation can already parse JSON, and for a hook payload that would be
/// enough. The installer is why this type exists. It rewrites a file the user
/// owns, and `JSONSerialization` hands back a dictionary that has forgotten the
/// order its keys were written in and a `Double` that has forgotten whether `5`
/// was spelled `5` or `5.0`. Writing that back would rewrite every line of a
/// file AgentBar is supposed to add two entries to.
///
/// The payload decoder shares it as a second benefit rather than the reason:
/// `as?` on `Any` degrades on a type mismatch only where somebody remembered to
/// write `as?`, and `Sendable` has to be argued for rather than checked.
public enum JSONValue: Sendable, Hashable {
    case object(JSONObject)
    case array([JSONValue])
    case string(String)
    /// The number exactly as it was written. Kept as text because the installer
    /// must not turn a `"timeout": 5` it did not write into `5.0`.
    case number(String)
    case bool(Bool)
    case null
}

extension JSONValue {
    public var object: JSONObject? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    /// The number exactly as it was written.
    ///
    /// For a reader that wants to *show* a number rather than compute with one —
    /// an argument in a tool call, say — where reformatting it through `Double`
    /// would be the one transformation this type exists to avoid.
    public var numberText: String? {
        guard case .number(let text) = self else { return nil }
        return text
    }

    /// The value as an integer, or `nil` when it was not written as one.
    ///
    /// Deliberately refuses `5.0`: everything this module reads a number for —
    /// a timeout in seconds — is an integer, and silently rounding a value the
    /// user wrote is how a hook ends up with a timeout nobody configured.
    public var integer: Int? {
        guard case .number(let text) = self else { return nil }
        return Int(text)
    }

    /// A value at a path of object keys, or `nil` if any step is missing or is
    /// not an object.
    public func value(at path: String...) -> JSONValue? {
        var current = self
        for key in path {
            guard let next = current.object?[key] else { return nil }
            current = next
        }
        return current
    }
}

/// A JSON object that remembers the order its keys arrived in.
public struct JSONObject: Sendable, Hashable {
    /// The keys in the order they were written, which is the whole reason this
    /// type exists rather than a `[String: JSONValue]`.
    public private(set) var keys: [String]
    private var storage: [String: JSONValue]

    public init() {
        keys = []
        storage = [:]
    }

    public init(_ pairs: [(String, JSONValue)]) {
        keys = []
        storage = [:]
        for (key, value) in pairs { self[key] = value }
    }

    public var isEmpty: Bool { keys.isEmpty }
    public var count: Int { keys.count }

    /// Reading is order-independent; writing appends a new key and leaves an
    /// existing one where it was.
    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            guard let newValue else {
                guard storage.removeValue(forKey: key) != nil else { return }
                keys.removeAll { $0 == key }
                return
            }
            if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
        }
    }

    public var pairs: [(key: String, value: JSONValue)] {
        keys.compactMap { key in storage[key].map { (key: key, value: $0) } }
    }

    /// Equality ignores key order, because two settings files that differ only
    /// in the order of keys nobody touched describe the same configuration —
    /// and this comparison is what decides whether the file is written at all.
    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.storage == rhs.storage
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}
