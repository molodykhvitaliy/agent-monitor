import Foundation

@testable import AgentBarCore

/// Event construction for the suites.
///
/// Every test says only what it is about — a kind, sometimes a session or a
/// directory — and everything else stays at a known default, so a sequence of
/// events reads like the session it describes.
enum Fixture {
    /// A fixed wall-clock origin. Tests offset from it in seconds, which keeps
    /// their arithmetic readable and their output stable.
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static let defaultProject = "/Users/dev/agentbar"

    static func date(_ offset: TimeInterval) -> Date {
        epoch.addingTimeInterval(offset)
    }

    static func event(
        _ kind: EventKind,
        session: String = "session-1",
        provider: Provider = .claudeCode,
        cwd: String = Fixture.defaultProject,
        at offset: TimeInterval = 0,
        tool: ToolRef? = nil,
        toolUseId: String? = nil,
        agent: AgentRef = .main,
        model: String? = "claude-opus-5",
        raw: RawPayload = .empty
    ) -> AgentEvent {
        AgentEvent(
            provider: provider,
            sessionId: SessionID(session),
            kind: kind,
            cwd: URL(filePath: cwd),
            timestamp: Fixture.date(offset),
            model: model,
            tool: tool,
            toolUseId: toolUseId.map(ToolUseID.init),
            agent: agent,
            raw: raw
        )
    }

    static func subagent(_ id: String, type: String? = "reviewer") -> AgentRef {
        .subagent(id: AgentID(id), type: type)
    }

    static let bash = ToolRef(name: "Bash", invocation: "swift test --parallel")
    static let edit = ToolRef(name: "Edit", invocation: "Sources/AgentBarCore/Session.swift")
}

extension StoreSnapshot {
    /// The one session a single-session test is about.
    var onlySession: Session? {
        guard sessions.count == 1 else { return nil }
        return sessions.first
    }

    func session(_ id: String) -> Session? {
        sessions.first { $0.id == SessionID(id) }
    }
}

extension ApplyOutcome {
    var ignoreReason: IgnoreReason? {
        guard case .ignored(let reason) = self else { return nil }
        return reason
    }

    var stateChange: StateChange? {
        guard case .changed(let change) = self else { return nil }
        return change
    }

    var isUnchanged: Bool {
        guard case .unchanged = self else { return false }
        return true
    }
}
