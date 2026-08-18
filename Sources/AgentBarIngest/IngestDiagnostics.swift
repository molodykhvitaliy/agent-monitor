import Foundation
import os

/// Something worth explaining about the endpoint or about a request it refused.
///
/// A rejected request is not an error the caller can act on — the answer is
/// always the same empty 200 or a bare status — so this is the only place the
/// reason survives. A misconfigured token, a hook installed twice and a helper
/// talking to a stale port all look identical from outside and completely
/// different here.
///
/// Nothing in a case carries request content. Sizes, routes and reasons only:
/// a hook payload holds prompts, file contents and command lines, and a log is
/// the wrong place for any of them.
public enum IngestDiagnostic: Sendable, Hashable {
    case started(port: UInt16, socketPath: String?)
    case stopped
    case portUnavailable(UInt16)
    case portMoved(from: UInt16, to: UInt16)
    case staleSocketRemoved(String)
    case unixSocketUnavailable(reason: String)
    case credentialReplaced(reason: String)
    case credentialPermissionsTightened(previousMode: Int)
    case unauthorized(path: String, transport: IngestTransport, reason: AuthenticationFailure)
    case malformedRequest(HTTPParseError, transport: IngestTransport)
    case routeNotFound(path: String, method: String)
    case methodNotAllowed(path: String, method: String)
    case payloadRejected(path: String, reason: String, byteCount: Int)
    case eventsAccepted(path: String, applied: Int, ignored: Int)
    case handlerTimedOut(path: String)
    case connectionsAtCapacity(limit: Int)
    case transportFailure(reason: String)

    public enum Severity: Sendable, Hashable {
        case info
        case notice
        case fault
    }

    public var severity: Severity {
        switch self {
        case .started, .stopped, .eventsAccepted, .staleSocketRemoved:
            .info
        case .portUnavailable, .unauthorized, .routeNotFound, .methodNotAllowed,
            .malformedRequest, .payloadRejected:
            .notice
        case .portMoved, .unixSocketUnavailable, .credentialReplaced,
            .credentialPermissionsTightened, .handlerTimedOut, .connectionsAtCapacity,
            .transportFailure:
            .fault
        }
    }

    public var message: String {
        switch self {
        case .started(let port, let socketPath):
            "ingest listening on \(IngestConfiguration.host):\(port)"
                + (socketPath.map { ", socket \($0)" } ?? ", no socket")
        case .stopped:
            "ingest stopped"
        case .portUnavailable(let port):
            "port \(port) is in use, trying the next"
        case .portMoved(let from, let to):
            "ingest moved from port \(from) to \(to); installed hook URLs need repairing"
        case .staleSocketRemoved(let path):
            "removed a socket left behind by an earlier run: \(path)"
        case .unixSocketUnavailable(let reason):
            "serving TCP only — the Unix socket is unavailable: \(reason)"
        case .credentialReplaced(let reason):
            "ingest token replaced (\(reason)); installed hook headers need repairing"
        case .credentialPermissionsTightened(let previousMode):
            "ingest token was readable beyond its owner (mode "
                + String(previousMode, radix: 8) + "); tightened to 600"
        case .unauthorized(let path, let transport, let reason):
            "refused an unauthenticated request to \(path.loggable) over "
                + "\(transport.rawValue): \(reason)"
        case .malformedRequest(let error, let transport):
            "malformed request over \(transport.rawValue): \("\(error)".loggable)"
        case .routeNotFound(let path, let method):
            "no route for \(method.loggable) \(path.loggable)"
        case .methodNotAllowed(let path, let method):
            "\(path.loggable) does not accept \(method.loggable)"
        case .payloadRejected(let path, let reason, let byteCount):
            "could not decode \(byteCount) bytes posted to \(path.loggable): \(reason.loggable)"
        case .eventsAccepted(let path, let applied, let ignored):
            "\(path.loggable): \(applied) applied, \(ignored) ignored"
        case .handlerTimedOut(let path):
            "handler for \(path.loggable) overran its deadline; answered with no opinion"
        case .connectionsAtCapacity(let limit):
            "refused a connection: \(limit) already open"
        case .transportFailure(let reason):
            "transport failure: \(reason)"
        }
    }
}

/// Why a request was not authenticated. Never told to the caller, which learns
/// only that it was refused.
public enum AuthenticationFailure: String, Sendable, Hashable, CustomStringConvertible {
    case headerMissing
    case schemeNotBearer
    case tokenMismatch

    public var description: String { rawValue }
}

/// Where diagnostics go.
///
/// A protocol rather than a logger because the suites assert on what the
/// endpoint reported: "the request was refused" and "the request was refused
/// for the reason we think" are different tests, and only one of them can be
/// written against a log file.
public protocol IngestDiagnosticSink: Sendable {
    func record(_ diagnostic: IngestDiagnostic)
}

/// Discards everything. The default where a component can work without a sink.
public struct SilentDiagnostics: IngestDiagnosticSink {
    public init() {}
    public func record(_ diagnostic: IngestDiagnostic) {}
}

/// The production sink.
///
/// Messages are logged `.public` on purpose: every one of them is assembled
/// from routes, ports and reasons this module wrote, never from request
/// content, so redacting them would hide exactly the information a user needs
/// to paste into a bug report.
public struct SystemDiagnostics: IngestDiagnosticSink {
    private let logger: Logger

    public init(subsystem: String = "com.molodykhvitalii.AgentBar", category: String = "ingest") {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func record(_ diagnostic: IngestDiagnostic) {
        let message = diagnostic.message
        switch diagnostic.severity {
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .fault: logger.error("\(message, privacy: .public)")
        }
    }
}

extension String {
    /// This text, made safe to put in a log line.
    ///
    /// Diagnostics are logged `.public`, which is right — every message is built
    /// from routes and reasons, and redacting them would hide exactly what a bug
    /// report needs. But a request target and a rejected header value come from
    /// whoever opened the socket, and both are reachable *before* the token is
    /// checked. A request line may be kilobytes long, and splitting the head on
    /// `\r\n` leaves a bare newline inside a path untouched — which in the
    /// unified log is a second line the caller wrote. So: control characters
    /// replaced, length bounded.
    var loggable: String {
        let limit = 120
        var result = ""
        result.reserveCapacity(min(utf8.count, limit))
        for scalar in unicodeScalars {
            guard result.count < limit else { return result + "…" }
            result.append(
                CharacterSet.controlCharacters.contains(scalar) ? "?" : Character(scalar))
        }
        return result
    }
}
