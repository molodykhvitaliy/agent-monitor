import AgentBarIngest
import Darwin
import Foundation

/// What one run of the helper did.
///
/// Every case exits the process successfully. The distinction exists for tests,
/// for the optional diagnostic line, and for nothing else: Codex is never told
/// that anything went wrong, because a hook that reports a failure is a hook the
/// user sees, and AgentBar is not allowed to be visible on this path.
public enum CodexRelayOutcome: Sendable, Hashable, CustomStringConvertible {
    /// The endpoint answered. The status is carried for the diagnostic line —
    /// `401` after a token rotation looks very different from `200`.
    case delivered(status: Int)
    /// Nothing arrived on stdin. Codex always sends a payload, so this is either
    /// a helper run by hand or a hook invoked in a way nobody anticipated.
    case nothingToSend
    /// The payload is larger than the endpoint would accept, so it is drained
    /// and dropped rather than sent to be refused.
    case payloadTooLarge(bytes: Int)
    /// No endpoint description on disk: AgentBar is not running, or has never
    /// run. The overwhelmingly common failure, and a silent one by design.
    case endpointUnknown
    /// A description exists and the endpoint did not answer.
    case undelivered(reason: String)

    public var description: String {
        switch self {
        case .delivered(let status): "delivered, \(status)"
        case .nothingToSend: "nothing on stdin"
        case .payloadTooLarge(let bytes): "payload of \(bytes) bytes is too large to relay"
        case .endpointUnknown: "AgentBar is not running"
        case .undelivered(let reason): "not delivered: \(reason)"
        }
    }
}

/// The Codex hook bridge: one JSON object in on stdin, one POST out to loopback.
///
/// A dumb pipe, deliberately. It does not parse the payload, does not decide
/// what the event means and does not retry — every interpretation happens in the
/// app, on the far side of the socket, where it can be tested and changed
/// without touching the process that Codex spawns on every tool call.
///
/// Three rules govern it, and each one is a rule rather than a preference.
///
/// 1. **It never fails the agent.** Whatever happens, the process exits `0` and
///    says nothing on stdout or stderr. Codex reads a non-zero exit from
///    `PreToolUse`, `PostToolUse` or `UserPromptSubmit` as a *block* — the one
///    thing a monitor must never do.
/// 2. **It drains stdin before it exits.** Codex writes the payload into a pipe;
///    a helper that exits first hands the writer `EPIPE`, which is a visible
///    effect on the agent and so a breach of the safe-superset rule.
/// 3. **It is bounded everywhere.** Connect, send and reply each carry a
///    deadline measured in a fraction of the smallest budget either agent gives
///    a hook.
public struct CodexHelperRelay: Sendable {
    /// The largest payload relayed. Matches the endpoint's own body limit: a
    /// bigger one would be refused there, and refusing it here saves a
    /// four-megabyte write on a path with a millisecond budget.
    public static let maximumPayloadBytes = 4 * 1024 * 1024

    private let discovery: EndpointDiscoveryFile
    private let timeouts: RelayTimeouts

    public init(discoveryURL: URL, timeouts: RelayTimeouts = RelayTimeouts()) {
        discovery = EndpointDiscoveryFile(url: discoveryURL)
        self.timeouts = timeouts
    }

    /// The environment variable that redirects the helper at another endpoint
    /// description.
    ///
    /// A test seam, and the only one: without it the timing proof would measure
    /// a helper that could not find the endpoint it was supposed to be talking
    /// to, and would call that fast. It can do nothing but point the helper at a
    /// different file — there is no path here that reaches an endpoint the
    /// running app did not publish.
    public static let discoveryOverrideVariable = "AGENTBAR_ENDPOINT_FILE"

    /// The discovery file the running app publishes, in the app support
    /// directory both sides agree on.
    public static func defaultDiscoveryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let override = environment[discoveryOverrideVariable], !override.isEmpty {
            return URL(filePath: override)
        }
        return try? IngestPaths.applicationSupport(fileManager: fileManager).discoveryURL
    }

    /// Relays one payload. Never throws.
    public func relay(_ payload: Data) -> CodexRelayOutcome {
        guard !payload.isEmpty else { return .nothingToSend }
        guard payload.count <= Self.maximumPayloadBytes else {
            return .payloadTooLarge(bytes: payload.count)
        }
        guard let descriptor = discovery.read() else { return .endpointUnknown }
        guard let token = Self.readToken(at: descriptor.tokenPath) else {
            return .undelivered(reason: "the endpoint's token file could not be read")
        }

        let request = Self.request(
            payload: payload, token: token, host: descriptor.host, port: descriptor.port)
        var lastFailure: String?
        // The Unix socket first, when the endpoint managed to bind one: it skips
        // the TCP stack and cannot be answered by anything but the process that
        // created the file. The port is the fallback rather than the choice.
        //
        // The fallback can in principle deliver twice — a socket that accepted
        // the request and then timed out before answering would be tried again
        // over TCP. That trade is deliberate: a tool call is deduplicated by its
        // `tool_use_id` and everything else the store accepts is idempotent by
        // construction, so a second copy costs nothing, where a dropped payload
        // costs a session that reads as quiet while it is working.
        for destination in Self.destinations(for: descriptor) {
            do {
                let reply = try RelaySocket.exchange(
                    request, with: destination, timeouts: timeouts)
                return .delivered(status: Self.status(of: reply) ?? 0)
            } catch {
                lastFailure = "\(error)"
            }
        }
        return .undelivered(reason: lastFailure ?? "no route to the endpoint")
    }

    static func destinations(for descriptor: EndpointDescriptor) -> [RelayDestination] {
        var destinations: [RelayDestination] = []
        if let path = descriptor.socketPath, !path.isEmpty {
            destinations.append(.unixSocket(path: path))
        }
        destinations.append(.loopback(host: descriptor.host, port: descriptor.port))
        return destinations
    }

    /// The token as the endpoint wrote it, validated rather than trusted.
    ///
    /// A file that has been truncated or filled with something else produces
    /// `nil` here instead of a header the endpoint will refuse — the difference
    /// between a diagnostic that says "the token file could not be read" and one
    /// that says `401`.
    static func readToken(at path: String) -> IngestToken? {
        guard let data = FileManager.default.contents(atPath: path),
            let text = String(data: data, encoding: .utf8)
        else { return nil }
        return IngestToken(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The request, byte for byte.
    ///
    /// Hand-built for the same reason the endpoint's parser is: this is one
    /// fixed request to one known peer, and a URL loading system would bring an
    /// HTTP client into a process whose whole job is to write a few hundred
    /// bytes to a socket and exit. `Connection: close` because there is no
    /// second request — the process is about to end.
    static func request(payload: Data, token: IngestToken, host: String, port: UInt16) -> Data {
        var head = ""
        head += "POST \(CodexEndpoint.route.path) HTTP/1.1\r\n"
        head += "Host: \(host):\(port)\r\n"
        head += "Authorization: Bearer \(token.value)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var request = Data(head.utf8)
        request.append(payload)
        return request
    }

    /// The status code out of `HTTP/1.1 200 OK`, or `nil` if the answer was not
    /// a status line. Read for the diagnostic, never acted on.
    static func status(of reply: Data) -> Int? {
        guard let text = String(data: reply.prefix(64), encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/") else { return nil }
        return Int(parts[1])
    }
}

/// Reads standard input to the end, whatever else happens.
///
/// Draining is not politeness. Codex writes the payload into a pipe, and a
/// reader that leaves early hands the writer `EPIPE` — a visible effect on the
/// agent, from a tool that is supposed to be invisible. So the read continues to
/// EOF even once the payload is past the size the relay would send: what comes
/// back is bounded, what is consumed is not.
public enum StandardInput {
    /// Everything on stdin up to `limit`, and the total number of bytes that
    /// arrived.
    ///
    /// The count is what tells a truncated payload from a complete one. A
    /// truncated JSON object is not worth relaying — the endpoint would refuse
    /// it and record a diagnostic naming AgentBar's own helper as the source.
    public static func drain(limit: Int, from descriptor: Int32 = 0) -> (data: Data, total: Int) {
        var collected = Data()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { destination in
                Darwin.read(descriptor, destination.baseAddress, destination.count)
            }
            if count > 0 {
                total += count
                if collected.count < limit {
                    let room = min(count, limit - collected.count)
                    collected.append(contentsOf: buffer[0..<room])
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            break
        }
        return (collected, total)
    }
}
