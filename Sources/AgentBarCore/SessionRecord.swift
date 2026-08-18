import Foundation

/// A tool call that has started and not yet been seen to finish.
struct OpenToolCall: Sendable, Hashable {
    /// Absent when the provider does not identify tool calls — Codex documents
    /// no equivalent of `tool_use_id`.
    let id: ToolUseID?
    let tool: ToolRef?
}

/// The store's mutable view of one session.
///
/// Kept separate from `Session`, which is the immutable reading handed out:
/// this side carries the bookkeeping — open tool calls, live subagents, the two
/// clocks — that nothing outside the store has any business reading.
///
/// It never holds `.unknown`. That state is derived from silence every time it
/// is needed, so nothing has to remember what a session was doing before it
/// went quiet, and a sign of life restores the truth by itself.
struct SessionRecord: Sendable {
    /// A turn closes every tool call it opened, so this only matters when
    /// `PostToolUse` stops arriving. Without it the list would grow for as long
    /// as the session lives.
    static let openToolLimit = 64

    let id: SessionID
    let provider: Provider
    var project: ProjectRef
    var model: String?
    private(set) var state: SessionState
    private(set) var openTools: [OpenToolCall] = []
    var activeSubagents: Set<AgentID> = []
    let startedAt: Date
    let startedAtInstant: MonotonicInstant
    /// Timestamp of the newest event applied. Orders deliveries, and dates the
    /// session when the watchdog gives up on it.
    private(set) var lastEventAt: Date
    /// When that event was applied. What silence is measured from — silence of
    /// information, not of packets.
    private(set) var lastInformedAt: MonotonicInstant
    private(set) var stateChangedAtInstant: MonotonicInstant
    /// Whether the last transition reported to the rest of the app said this
    /// session had gone quiet. Only transition reporting reads it — the state
    /// itself is always derived — and it is what lets a recovery be announced
    /// once rather than every sweep.
    var reportedUnknown = false

    init(admitting event: AgentEvent, at instant: MonotonicInstant) {
        id = event.sessionId
        provider = event.provider
        project = event.project
        model = event.model
        state = .idle
        startedAt = event.timestamp
        startedAtInstant = instant
        lastEventAt = event.timestamp
        lastInformedAt = instant
        stateChangedAtInstant = instant
    }

    var hasOpenTool: Bool { !openTools.isEmpty }

    /// The tool the row shows. Only meaningful while working, which is the
    /// store's business to enforce, not this type's.
    var currentTool: ToolRef? { openTools.last?.tool }

    /// Records an event the state machine is about to act on.
    ///
    /// Only applied events count. A duplicate or a straggler proves a process
    /// is still posting, but it says nothing new — and a session whose every
    /// delivery is refused must still be allowed to go quiet, or one badly
    /// stamped event would keep it believed for ever.
    mutating func observe(_ event: AgentEvent, at instant: MonotonicInstant) {
        lastInformedAt = instant
        lastEventAt = max(lastEventAt, event.timestamp)
        project = event.project
        if let model = event.model { self.model = model }
    }

    /// Moves the session, leaving the state timer alone when nothing moved.
    mutating func enter(_ newState: SessionState) {
        guard newState != state else { return }
        state = newState
        stateChangedAtInstant = lastInformedAt
    }

    /// A turn boundary closes everything it opened. Doing this explicitly means
    /// a missed `PostToolUse` or `SubagentStop` costs one stale counter rather
    /// than a session that is permanently running four subagents.
    mutating func finishTurn() {
        openTools.removeAll()
        activeSubagents.removeAll()
        enter(.idle)
    }

    mutating func openTool(id: ToolUseID?, tool: ToolRef?) {
        if let id, openTools.contains(where: { $0.id == id }) { return }
        openTools.append(OpenToolCall(id: id, tool: tool))
        if openTools.count > SessionRecord.openToolLimit { openTools.removeFirst() }
    }

    mutating func closeTool(id: ToolUseID?, named name: String?) {
        if let id {
            guard let index = openTools.firstIndex(where: { $0.id == id }) else { return }
            openTools.remove(at: index)
            return
        }
        // Without an id the newest call with a matching name is the best guess,
        // and the newest call of any name the fallback. Closing the wrong one
        // costs a mislabelled row; closing none would leave the watchdog
        // believing a tool is running for ever.
        if let name, let index = openTools.lastIndex(where: { $0.tool?.name == name }) {
            openTools.remove(at: index)
            return
        }
        if !openTools.isEmpty { openTools.removeLast() }
    }
}
