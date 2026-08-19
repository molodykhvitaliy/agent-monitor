import Foundation

/// One subscription usage window, as it leaves this module.
///
/// Structured, not formatted. Every value here is something the App Server
/// actually said; deciding what a 10 080-minute window is *called* is a
/// presentation question, and presentation lives in `AgentBarUI` where the
/// strings can be localised beside every other string in the panel.
///
/// Deliberately not `Identifiable`. Its only candidate identity is `limitId`,
/// which is optional and shared by both windows of a two-window bucket, so
/// position is the honest identity — the same reasoning `UsageWindow` records.
public struct QuotaWindow: Sendable, Hashable {
    /// The bucket's own name, verbatim, when the server gave one. It was `null`
    /// in every live reading taken so far, which is exactly why nothing renders
    /// it raw.
    public let limitName: String?
    /// The metered bucket this window belongs to — `"codex"` in the live
    /// reading. The last resort for a label, and never used for ordering.
    public let limitId: String?
    /// How long the window is. `nil` when the server did not say.
    public let windowDuration: Duration?
    /// 0…1. `nil` is impossible today — `usedPercent` is a required field — but
    /// the type keeps the option so a future schema that drops it degrades to a
    /// row without a bar instead of to a bar at zero.
    public let fractionUsed: Double?
    public let resetsAt: Date?

    public init(
        limitName: String? = nil,
        limitId: String? = nil,
        windowDuration: Duration? = nil,
        fractionUsed: Double? = nil,
        resetsAt: Date? = nil
    ) {
        self.limitName = limitName
        self.limitId = limitId
        self.windowDuration = windowDuration
        self.fractionUsed = fractionUsed
        self.resetsAt = resetsAt
    }

    /// Whether this window says anything at all.
    ///
    /// A **name is not information here**, deliberately. A row carrying only a
    /// title has no bar and no meta line, so it occupies a row's worth of space
    /// to say that a limit exists — which the section's presence already says.
    /// A percentage or a reset time is the least this row can be worth drawing
    /// for.
    var isInformative: Bool {
        fractionUsed != nil || resetsAt != nil
    }
}

/// What the last successful read found.
public struct QuotaReading: Sendable, Hashable {
    /// Ordered as they should be rendered: bucket by bucket, and within a
    /// bucket the shorter window before the longer one.
    public let windows: [QuotaWindow]
    /// When the reading was taken, for a log line. Nothing in the panel shows
    /// it — a timestamp beside a number invites the reader to wonder whether the
    /// number is stale, which is a question the refresh policy already answers.
    public let takenAt: Date

    public init(windows: [QuotaWindow], takenAt: Date) {
        self.windows = windows
        self.takenAt = takenAt
    }

    public static let empty = QuotaReading(windows: [], takenAt: .distantPast)
}
