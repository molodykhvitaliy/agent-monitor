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

    /// What a window is called, from the three things a provider might have
    /// said about it.
    ///
    /// The order is the point:
    ///
    /// - the provider's **own name** for the bucket, when it gives one. Codex
    ///   has sent `null` in every live reading so far, which is why the rest of
    ///   this exists;
    /// - the window's **length** — `Weekly`, `5 hours`. This is what the design
    ///   mocked, and it is the only label that tells two windows of one bucket
    ///   apart;
    /// - the **identifier**, last, because `codex` is an id rather than a name
    ///   and reads as one.
    ///
    /// A name and a length are **joined** rather than one replacing the other: a
    /// bucket that has a name and two windows would otherwise render two
    /// identical rows. Nothing here invents a label — with none of the three the
    /// answer is `nil`, and `displayName` falls back to `Usage`.
    ///
    /// Lives here rather than beside the provider that supplies the values,
    /// because every string in it is localised and localisation belongs where
    /// the rest of the panel's strings are.
    public static func label(
        name: String?, windowDuration: Duration?, identifier: String?
    ) -> String? {
        var parts: [String] = []
        if let name, !name.isEmpty { parts.append(name) }
        if let windowDuration, let phrase = DurationText.window(windowDuration) {
            parts.append(phrase)
        }
        if parts.isEmpty, let identifier, !identifier.isEmpty { parts.append(identifier) }
        return parts.isEmpty ? nil : parts.joined(separator: DesignTokens.separator)
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
