import Foundation

/// One subscription usage window, as the Limits section renders it.
///
/// A **repeating** component: one row per window the provider reported — one,
/// two, or more. Never a fixed two-slot layout, because a live sample returned
/// exactly one bucket and the count is not ours to assume.
///
/// Every field is independently optional and degrades by **omission**, never by
/// a placeholder zero: a bar drawn at 0 % says "you have used none of it", which
/// is a different and possibly false claim.
///
/// Declared here rather than in a provider module for the same reason
/// `IntegrationStatus` is: `AgentBarUI` may import only `AgentBarCore`. Step 10
/// maps the App Server's own shape onto this in the app target.
nonisolated
    ///
    /// Deliberately **not** `Identifiable`. Its only candidate identity is the
    /// server's own name, which is optional and need not be unique — two unnamed
    /// windows, or two the App Server labels the same, would collide and SwiftUI
    /// would render one row where two were reported. The list is ordered and
    /// short, so position is the honest identity and `LimitsSectionView` keys on it.
    public struct UsageWindow: Sendable, Hashable
{
    /// The provider's own name for the window, verbatim. `nil` renders as
    /// `Usage`.
    public let name: String?
    /// 0…1. `nil` means no bar at all.
    public let fractionUsed: Double?
    public let resetsAt: Date?

    public init(name: String?, fractionUsed: Double?, resetsAt: Date?) {
        self.name = name
        self.fractionUsed = fractionUsed
        self.resetsAt = resetsAt
    }

    public var displayName: String {
        name ?? String(localized: "Usage", comment: "Fallback name for an unnamed usage window")
    }

    /// `34% · resets in 2h 10m`, with the separator dropped when only one half
    /// is present, and the whole line absent when neither is.
    public func meta(now: Date) -> String? {
        var parts: [String] = []
        if let fractionUsed {
            let percent = Int((max(0, min(1, fractionUsed)) * 100).rounded())
            parts.append("\(percent)%")
        }
        if let resetsAt {
            let remaining = Duration.seconds(max(0, resetsAt.timeIntervalSince(now)))
            // Capitalised when it stands alone, because then it starts the line.
            let phrase = DurationText.resets(in: remaining)
            parts.append(parts.isEmpty ? phrase.capitalisedFirst : phrase)
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: DesignTokens.separator)
    }
}

nonisolated extension String {
    /// Sentence case without touching anything after the first character —
    /// `capitalized` would turn `resets in 2h 10m` into `Resets In 2h 10m`.
    var capitalisedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
