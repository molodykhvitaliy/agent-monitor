import Foundation
import Synchronization

@testable import AgentBarCore
@testable import AgentBarIngest

/// Keeps every diagnostic so a test can assert on the reason a request was
/// refused, not merely that it was.
final class CollectingDiagnostics: IngestDiagnosticSink {
    private let entries = Mutex<[IngestDiagnostic]>([])

    func record(_ diagnostic: IngestDiagnostic) {
        entries.withLock { $0.append(diagnostic) }
    }

    var recorded: [IngestDiagnostic] { entries.withLock { $0 } }

    func contains(where predicate: (IngestDiagnostic) -> Bool) -> Bool {
        recorded.contains(where: predicate)
    }
}

/// A directory that cleans up after itself.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        // Short on purpose. A Unix socket path is capped at 103 bytes, the
        // per-user temporary directory already spends about 50 of them, and a
        // full UUID in the name overruns it — which the endpoint correctly
        // refuses to bind, failing the test for a reason that is not the code's.
        let unique = UUID().uuidString.prefix(8).lowercased()
        url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "agentbar-\(unique)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    var paths: IngestPaths { IngestPaths(directory: url) }

    func mode(of file: URL) -> Int? {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: file.path(percentEncoded: false))
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue
    }
}

/// A handler whose response and delay a test chooses.
struct ScriptedHandler: IngestHandling {
    let routes: Set<IngestRoute>
    let delay: Duration
    let response: IngestResponse

    init(
        routes: Set<IngestRoute>,
        delay: Duration = .zero,
        response: IngestResponse = .noOpinion
    ) {
        self.routes = routes
        self.delay = delay
        self.response = response
    }

    func handle(_ request: IngestRequest) async -> IngestResponse {
        if delay != .zero { try? await Task.sleep(for: delay) }
        return response
    }
}

/// A handler that ignores cancellation entirely.
///
/// `ScriptedHandler` sleeps with `Task.sleep`, which throws the moment the
/// deadline cancels it — so it cannot tell a deadline that abandons its work
/// from one that politely waits for it. This one parks on a continuation a
/// timer resumes, which no amount of cancellation shortens. It is the only
/// shape that can prove the property `Deadline` exists for.
struct UncooperativeHandler: IngestHandling {
    let routes: Set<IngestRoute>
    let seconds: Double
    let response: IngestResponse

    init(routes: Set<IngestRoute>, seconds: Double = 2, response: IngestResponse = .noOpinion) {
        self.routes = routes
        self.seconds = seconds
        self.response = response
    }

    typealias ResponseContinuation = CheckedContinuation<IngestResponse, Never>

    func handle(_ request: IngestRequest) async -> IngestResponse {
        let answer = response
        return await withCheckedContinuation { (continuation: ResponseContinuation) in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume(returning: answer)
            }
        }
    }
}

/// The native envelope, as JSON.
enum EventPayload {
    static let project = "/Users/dev/agentbar"

    static func json(
        kind: String,
        session: String = "session-1",
        provider: String = "claudeCode",
        cwd: String = EventPayload.project,
        extra: [String: String] = [:]
    ) -> String {
        var fields = [
            "\"provider\": \"\(provider)\"",
            "\"sessionId\": \"\(session)\"",
            "\"kind\": \"\(kind)\"",
            "\"cwd\": \"\(cwd)\"",
        ]
        fields += extra.map { "\"\($0.key)\": \($0.value)" }
        return "{\(fields.joined(separator: ", "))}"
    }
}

extension StoreSnapshot {
    /// The session a test names, wherever its project group put it.
    func session(_ id: String) -> Session? {
        sessions.first { $0.id == SessionID(id) }
    }
}
