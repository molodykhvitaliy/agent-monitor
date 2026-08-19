import Foundation

/// The App Server's JSON-RPC dialect.
///
/// Two things about it are not the textbook protocol, both verified against
/// `codex-cli 0.147.0` on 2026-08-19 and both documented upstream:
///
/// - **`"jsonrpc": "2.0"` is omitted on the wire.** Sending it is not what the
///   binary parses against, so this encoder does not write it and the decoder
///   does not require it.
/// - **Messages are newline-delimited**, one JSON object per line, and replies
///   arrive **out of order** — a slower `account/rateLimits/read` was observed
///   landing after a later `account/usage/read`. Correlation by `id` is
///   therefore load-bearing rather than tidy.
///
/// Notifications interleave with replies from the first moment: `configWarning`
/// and `remoteControl/status/changed` both arrive before anything is asked for.
/// Everything unrecognised is skipped, which is what makes an unknown
/// notification cost nothing.
enum JSONRPC {
    /// The id AgentBar puts on a request. Integers only — the schema allows a
    /// string too, but nothing requires us to send one.
    struct RequestID: Sendable, Hashable, Codable, CustomStringConvertible {
        let value: Int

        init(_ value: Int) { self.value = value }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            // A server is free to echo the id as a string; the schema declares
            // both. Refusing that would strand a reply we asked for.
            if let number = try? container.decode(Int.self) {
                value = number
            } else if let text = try? container.decode(String.self), let number = Int(text) {
                value = number
            } else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "request id is neither an integer nor a numeric string")
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(value)
        }

        var description: String { String(value) }
    }

    /// What a request carries, as a closed set rather than an arbitrary JSON
    /// value: every call AgentBar makes takes either nothing, an empty object,
    /// or the handshake's `clientInfo`. A type that cannot express more is a
    /// type that cannot accidentally send more.
    enum Parameters {
        /// The key is absent entirely, which is what
        /// `account/rateLimits/read` and `account/usage/read` take.
        case omitted
        /// `"params": {}` — required by `account/read`, which rejects a request
        /// without it. Empty and nothing else: the one flag the schema allows
        /// there asks Codex to renew a credential, and this type has no way to
        /// say it.
        case empty
        /// `initialize`'s `clientInfo`. AgentBar introduces itself by its own
        /// name and version — never a harness identity, never a user agent that
        /// could read as an official client.
        case clientInfo(name: String, version: String)
    }

    /// `Outgoing`'s keys, one level up from where they are used so the file
    /// stays inside the project's nesting limit.
    private enum OutgoingKey: String, CodingKey { case id, method, params }

    /// The one request body AgentBar sends, and the only shape of it.
    struct ClientInfo: Encodable {
        let name: String
        let version: String
    }

    /// A request or a notification on its way out.
    struct Outgoing: Encodable {
        let id: RequestID?
        let method: String
        let params: Parameters

        static func request(id: RequestID, method: String, params: Parameters) -> Outgoing {
            Outgoing(id: id, method: method, params: params)
        }

        static func notification(method: String) -> Outgoing {
            Outgoing(id: nil, method: method, params: .omitted)
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: OutgoingKey.self)
            try container.encodeIfPresent(id, forKey: .id)
            try container.encode(method, forKey: .method)
            switch params {
            case .omitted:
                break
            case .empty:
                try container.encode([String: String](), forKey: .params)
            case .clientInfo(let name, let version):
                try container.encode(
                    ["clientInfo": ClientInfo(name: name, version: version)], forKey: .params)
            }
        }
    }

    /// What the server said, reduced to the cases a caller can act on.
    enum Incoming {
        case result(id: RequestID, line: Data)
        case failure(id: RequestID, error: Failure)
        /// The server asking *us* something — an id and a method together.
        ///
        /// Separate from `unrelated` on purpose. It cannot happen while
        /// AgentBar starts no thread, and if it ever does it is a permission
        /// prompt arriving on a connection that has no way to answer one. That
        /// is worth a line in the log; an ordinary notification is not.
        case request(id: RequestID, method: String)
        /// A notification, or a reply whose id could not be read. Ignored.
        case unrelated(method: String?)
    }

    struct Failure: Sendable, Hashable, Decodable, Error, CustomStringConvertible {
        let code: Int
        let message: String

        var description: String { "\(message) (\(code))" }

        /// The server's answer to a method it does not implement.
        ///
        /// Verified: an unrecognised method is rejected as `-32600` — *invalid
        /// request*, not *method not found* — because the whole envelope fails
        /// to deserialise against a closed enum of methods. The id survives, so
        /// the failure still reaches the caller that asked.
        var looksUnimplemented: Bool {
            code == -32600 && message.contains("unknown variant")
        }
    }

    /// Splits one line into the case a caller can act on, without decoding the
    /// result payload: the payload's type depends on the method that asked for
    /// it, which only the caller knows.
    static func decode(line: Data) -> Incoming {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: line) else {
            return .unrelated(method: nil)
        }
        guard let id = envelope.id else { return .unrelated(method: envelope.method) }
        // A message with *both* an id and a method is the server asking us
        // something, not answering. AgentBar never starts a thread, so nothing
        // can prompt an approval and this is unreachable today — but server ids
        // come from the server's own counter and would collide with ours, and a
        // decoder that can mistake a permission request for a reply is not one
        // to leave standing next to the never-auto-approve rule.
        if let method = envelope.method { return .request(id: id, method: method) }
        if let error = envelope.error { return .failure(id: id, error: error) }
        // The result is handed back as the whole line. Extracting it here would
        // mean re-encoding a value this layer deliberately never models.
        return .result(id: id, line: line)
    }

    /// Pulls `result` out of a reply and decodes it as the caller's type.
    static func result<Payload: Decodable>(
        _ type: Payload.Type, from line: Data
    ) throws -> Payload {
        try JSONDecoder().decode(Reply<Payload>.self, from: line).result
    }

    /// As much of a message as this layer reads before handing it on.
    private struct Envelope: Decodable {
        let id: RequestID?
        let method: String?
        let error: Failure?
    }

    /// The one field a reply is read for. Declared here rather than inside
    /// `result(_:from:)` because Swift will not nest a generic type in a
    /// generic function.
    private struct Reply<Wrapped: Decodable>: Decodable {
        let result: Wrapped
    }
}
