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
    /// The payload never finished arriving, so what is in hand is a fragment.
    /// Either the budget ran out with the writer still holding its end, or a
    /// read failed partway. The helper drops it rather than posting a truncated
    /// JSON body for the endpoint to refuse — and rather than waiting, because
    /// an unbounded wait here is a process that outlives the agent that spawned
    /// it.
    case payloadIncomplete(bytes: Int, reason: String)
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
        case .payloadIncomplete(let bytes, let reason):
            "payload incomplete (\(reason)); \(bytes) bytes arrived and were dropped"
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
    /// to, and would call that fast.
    ///
    /// What it can reach is bounded by two rules that hold whatever the file
    /// says: the destination must be on the loopback network, and the token must
    /// live in the same directory as the description that names it. So the worst
    /// a planted file can do is point the helper at a different local port with
    /// a token the planter already had.
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
        // The token is read from the path the description names, so the
        // description must not be able to name *any* path — a planted file
        // naming a credential store elsewhere in the home directory would turn
        // the helper into a reader of one. It has to sit in the directory the
        // description itself sits in, which is where the endpoint publishes
        // both of them.
        guard Self.isBesideDescription(descriptor.tokenPath, discoveryURL: discovery.fileURL) else {
            return .undelivered(reason: "the endpoint's token file is not beside its description")
        }
        guard let token = Self.readToken(at: descriptor.tokenPath) else {
            return .undelivered(reason: "the endpoint's token file could not be read")
        }

        let request = Self.request(
            payload: payload, token: token, host: descriptor.host, port: descriptor.port)
        // One deadline for the whole relay, both destinations included. Codex
        // caps a `SessionEnd` hook at a second, and a ladder whose rungs each
        // carried their own budget would quietly cost twice what the timeouts
        // say — which is how a hook that "cannot delay an agent" delays one.
        let deadline = ContinuousClock.now + timeouts.total
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
                    request, with: destination, timeouts: timeouts, deadline: deadline)
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

    /// Whether `path` names a file in the same directory as the description.
    static func isBesideDescription(_ path: String, discoveryURL: URL) -> Bool {
        let token = URL(filePath: path).standardizedFileURL.deletingLastPathComponent()
        let description = discoveryURL.standardizedFileURL.deletingLastPathComponent()
        return token.path(percentEncoded: false) == description.path(percentEncoded: false)
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

/// Reads standard input to the end, whatever else happens — but never for ever.
///
/// Draining is not politeness. Codex writes the payload into a pipe, and a
/// reader that leaves early hands the writer `EPIPE` — a visible effect on the
/// agent, from a tool that is supposed to be invisible. So the read continues to
/// EOF even once the payload is past the size the relay would send: what comes
/// back is capped at the caller's limit, what is *consumed* is not.
///
/// > **It is bounded in time, and that bound is not optional.** This was the one
/// > unbounded wait in the whole project: a blocking `read` in a loop with no
/// > deadline, in the one binary an agent spawns on **every tool call**. A
/// > writer that holds the pipe open holds the helper open with it — measured at
/// > exactly the six seconds a test writer was told to wait — and a helper that
/// > outlives the Codex process that spawned it is reparented to `launchd` and
/// > sits in the session's working directory for ever. One per tool call, all
/// > day. Nothing about the safe-superset rule survives that.
/// >
/// > So every wait goes through `poll` against a deadline, and the read only
/// > happens once `poll` has said bytes are there. That also fixes a quieter
/// > bug: a descriptor the parent left non-blocking returned `EAGAIN`, which the
/// > old loop read as end of input and silently dropped the payload.
public enum StandardInput {
    /// How long the writer may say nothing before the drain gives up on it.
    ///
    /// **The bound that does the work, and it measures silence rather than
    /// elapsed time.** A payload arrives as a run of chunks; what a stalled
    /// writer looks like is a gap. Bounding the *total* instead conflates the
    /// two, and the arithmetic says why: the worst legitimate payload — a
    /// `PostToolUse` carrying the endpoint's whole 4 MB limit through a 64 KB
    /// pipe — is about a millisecond on an idle machine but **93–105 ms** with
    /// this repository's suite running in parallel. A total budget large enough
    /// to be safe there would have to be most of the agent's own, and one small
    /// enough to be polite would drop real events on a busy Mac.
    ///
    /// 150 ms of silence is a hundred times the gap between two chunks of a
    /// payload that is actually being written even on the loaded machine above —
    /// 93–105 ms across some sixty-four chunks — and a fifth of the smallest
    /// budget either agent gives a hook.
    public static let defaultQuiet: Duration = .milliseconds(150)

    /// The bound on the whole drain, whatever the writer does.
    ///
    /// Silence alone is not enough: a writer trickling one byte every hundred
    /// milliseconds resets the quiet period for ever and would hold the helper
    /// open exactly as the unbounded read did. This is what closes that, and it
    /// is chosen against the **whole helper process** rather than against this
    /// stage — see `CodexHookHandler.worstCaseHelperRun`, which adds this to the
    /// relay's own total *and to the process spawn this stage cannot measure*,
    /// and which `CodexHooks` pins against the one second Codex gives a
    /// `SessionEnd` hook.
    ///
    /// 300 ms is still about three times the worst legitimate drain measured —
    /// 93–105 ms for a 4 MB payload through a 64 KB pipe on a loaded machine.
    public static let defaultCeiling: Duration = .milliseconds(300)

    /// How a read ended, which is what decides whether the payload is worth
    /// relaying.
    public enum DrainOutcome: Sendable, Hashable {
        /// The writer closed its end. Everything it meant to send arrived.
        case complete
        /// The budget ran out first, so what arrived is a fragment.
        case expired
        /// A syscall failed. Also a fragment, and for a different reason worth
        /// telling apart in a diagnostic.
        case failed(code: Int32)
    }

    /// What one drain produced.
    public struct Drained: Sendable, Hashable {
        /// Everything that arrived, up to the caller's limit.
        public let data: Data
        /// How many bytes arrived in total, limit or no limit.
        ///
        /// A figure for the diagnostic, not a verdict — `outcome` is what says
        /// whether the payload is whole. It is worth carrying because "the
        /// payload never ended" reads very differently at eleven bytes and at
        /// four megabytes.
        public let total: Int
        public let outcome: DrainOutcome

        /// Whether what arrived is the whole of what the writer meant to send.
        ///
        /// The only question the caller has. Anything else — a budget that ran
        /// out, a read that failed halfway — leaves a fragment, and a fragment
        /// must never go out as if it were a payload.
        public var isComplete: Bool { outcome == .complete }
    }

    /// Everything on stdin up to `limit`, giving up after `quiet` of silence or
    /// `ceiling` in total, whichever comes first.
    public static func drain(
        limit: Int,
        quiet: Duration = StandardInput.defaultQuiet,
        ceiling: Duration = StandardInput.defaultCeiling,
        from descriptor: Int32 = 0
    ) -> Drained {
        let ceilingDeadline = ContinuousClock.now + ceiling
        var collected = Data()
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            // Whichever bound expires first. The quiet period restarts on every
            // wait, which is what lets a large payload take as long as its
            // chunks need; the ceiling never does, which is what stops a trickle
            // from taking for ever.
            //
            // **Until the first byte, the ceiling is the only bound.** "The
            // writer has gone quiet" is not a statement anybody can make about a
            // writer that has not started, and the gap between this process
            // being spawned and Codex writing into the pipe belongs to Codex and
            // to how busy the Mac is. Applying the quiet period there would give
            // up on a payload that was always going to arrive.
            let deadline =
                total == 0 ? ceilingDeadline : min(ContinuousClock.now + quiet, ceilingDeadline)
            // Always before the read, never after it. A blocking descriptor
            // never reports `EAGAIN` — it simply never returns — so a deadline
            // enforced by inspecting `errno` would enforce nothing at all on the
            // descriptor the helper actually gets.
            switch waitForInput(descriptor, until: deadline) {
            case .ready: break
            case .expired: return Drained(data: collected, total: total, outcome: .expired)
            case .failed(let code):
                return Drained(data: collected, total: total, outcome: .failed(code: code))
            }
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
            if count == 0 { break }  // End of file: the writer has gone.
            let code = errno
            // A signal, or a readiness that did not survive to the read — the
            // second is possible on a descriptor somebody else left
            // non-blocking. Neither is the end of the payload, and the deadline
            // is what stops either from becoming a loop.
            if code == EINTR || code == EAGAIN || code == EWOULDBLOCK { continue }
            // Anything else really did fail, and reporting it as end of input is
            // how a truncated body gets posted as though it were whole.
            return Drained(data: collected, total: total, outcome: .failed(code: code))
        }
        return Drained(data: collected, total: total, outcome: .complete)
    }

    /// What one wait resolved to.
    enum Readiness: Sendable, Hashable {
        case ready
        case expired
        case failed(code: Int32)
    }

    /// Waits until `descriptor` has something to say, or the deadline passes.
    ///
    /// A failed `poll` is **not** reported as ready. It is tempting to fall
    /// through to the read and let that report the real error, and on a blocking
    /// descriptor that read is exactly the unbounded wait this whole file exists
    /// to remove — `poll` can fail with `EAGAIN` on Darwin when the kernel
    /// cannot allocate for it, which is precisely the loaded machine the wait
    /// must survive. A signal is the one failure worth retrying, and the
    /// deadline bounds the retry.
    private static func waitForInput(
        _ descriptor: Int32, until deadline: ContinuousClock.Instant
    ) -> Readiness {
        while true {
            let left = RelaySocket.remaining(until: deadline)
            guard left > .zero else { return .expired }
            var watched = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watched, 1, RelaySocket.milliseconds(left))
            if ready > 0 { return .ready }
            if ready == 0 { return .expired }
            let code = errno
            if code == EINTR { continue }
            return .failed(code: code)
        }
    }
}
