import Foundation

/// Whether a session survives the event just applied.
enum Disposition: Sendable, Hashable {
    case keep
    case end
}

extension SessionStore {
    /// The state machine from docs/dev/architecture.md, in one place.
    ///
    /// Every case here decides a state and nothing else: liveness, project and
    /// model were already refreshed by `SessionRecord.observe`, so an event
    /// whose only job is to prove the agent is alive needs no case of its own.
    func transition(_ record: inout SessionRecord, on event: AgentEvent) -> Disposition {
        switch event.kind {
        case .sessionStarted:
            // Also fires on resume, clear, compact and fork, for a session that
            // may well be mid-turn. Resetting it to idle would report a
            // compaction as the agent having stopped, so an announcement about
            // a session already known is a heartbeat and nothing more.
            return .keep

        case .turnStarted:
            record.enter(.working)

        case .toolStarted:
            record.openTool(id: event.toolUseId, tool: event.tool)
            record.enter(.working)

        case .toolFinished:
            record.closeTool(id: event.toolUseId, named: event.tool?.name)
            record.enter(.working)

        case .subagentStarted:
            if let id = event.agent.subagentId { record.activeSubagents.insert(id) }
            record.enter(.working)

        case .subagentStopped:
            // Only a subagent this session was actually counting says anything
            // about what the session is doing. A background subagent outlives
            // the turn that spawned it, so its farewell can arrive after `Stop`
            // has already cleared the counter and moved the session to idle —
            // and `enter(.working)` there would resurrect a finished session
            // into a state only the watchdog could end, holding the power
            // assertion open with it.
            guard let id = event.agent.subagentId,
                record.activeSubagents.remove(id) != nil
            else { return .keep }
            record.enter(.working)

        case .waitingInput:
            record.enter(.waitingInput)

        case .waitingPermission(let request):
            record.enter(.waitingPermission(request))

        case .turnFinished:
            record.finishTurn()

        case .failed(let reason):
            record.enter(.failed(reason: reason))

        case .sessionEnded:
            return .end
        }
        return .keep
    }
}
