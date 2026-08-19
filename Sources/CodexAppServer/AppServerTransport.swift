import Foundation

/// A newline-delimited conversation with one App Server.
///
/// The seam that keeps `swift test` from needing a `codex` binary. Everything
/// above it — the handshake, correlation, deadlines, the mapping — is exercised
/// against a scripted transport, and the only untested part is the process
/// plumbing itself.
///
/// The contract is deliberately small and one-shot: a transport is started
/// once, written to, read from, and ended. It is never restarted, because a
/// child that has to be killed is a child we no longer trust.
public protocol AppServerTransport: Sendable {
    /// Starts the conversation and returns the lines the server produces, each
    /// one a complete JSON object with no trailing newline.
    ///
    /// The stream finishes when the server closes its output or the transport is
    /// ended, whichever happens first. It never finishes silently while the
    /// server is still alive.
    func start() throws -> AsyncStream<Data>

    /// Writes one line. Throws if the far end has already gone.
    func send(_ line: Data) throws

    /// Ends the conversation, for good.
    ///
    /// **Must not block the caller**, must be safe to call from any isolation
    /// and any number of times, and must leave no process behind. It is called
    /// on every path — success, failure, timeout and cancellation — which is
    /// what makes "the child is never leaked" a property rather than a hope.
    func end()
}

/// Why an exchange did not produce an answer.
public enum AppServerError: Error, Sendable, Hashable, CustomStringConvertible {
    /// No `codex` executable could be found. Not a fault: Codex simply is not
    /// installed here, and the interface says nothing rather than complaining.
    case codexNotFound
    case cannotStart(String)
    /// The whole exchange overran its budget and the child was killed.
    case timedOut(Duration)
    /// The server closed its output before answering.
    case disconnected
    /// The server answered, with an error.
    case rejected(code: Int, message: String)
    /// The server does not implement a method this build asks for — an older
    /// Codex, or a newer one that moved the account API.
    case unimplemented(method: String)
    case undecodable(String)

    public var description: String {
        switch self {
        case .codexNotFound: "the codex executable could not be found"
        case .cannotStart(let reason): "codex app-server could not be started: \(reason)"
        case .timedOut(let budget): "codex app-server did not answer within \(budget)"
        case .disconnected: "codex app-server closed the connection"
        case .rejected(let code, let message):
            "codex app-server refused the call: \(message) (\(code))"
        case .unimplemented(let method): "this codex does not implement \(method)"
        case .undecodable(let reason): "codex app-server sent something unreadable: \(reason)"
        }
    }
}
