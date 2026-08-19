import Foundation

/// Turns what the App Server said into what the panel can draw.
///
/// Every rule here is a rule about *not* inventing something. The count of
/// windows is the server's, the labels are the server's, and a field the server
/// left out leaves a gap rather than acquiring a zero — a bar drawn at 0 % is
/// the claim "you have used none of it", which is a different and possibly false
/// statement from "we do not know".
enum RateLimitMapping {

    /// Flattens a rate-limits response into ordered windows.
    static func windows(from response: GetAccountRateLimitsResponse) -> [QuotaWindow] {
        buckets(in: response)
            .flatMap(windows(in:))
            .filter(\.isInformative)
    }

    /// The buckets to render, in a stable order.
    ///
    /// `rateLimitsByLimitId` is the multi-bucket view and `rateLimits` is the
    /// back-compat single-bucket one; in the live reading they carried the same
    /// snapshot, so rendering both would draw every row twice. The map wins when
    /// it has anything in it, and the flat field is the fallback for a server
    /// that predates it — or for one that sent an empty map.
    ///
    /// A dictionary has no order, and a list of limits that reshuffles itself on
    /// every refresh would be unreadable, so the keys are sorted. By `limitId`
    /// rather than by anything meaningful: the alternatives — usage, window
    /// length — all reorder rows as the numbers move, which is the same problem
    /// wearing a better excuse.
    private static func buckets(in response: GetAccountRateLimitsResponse) -> [RateLimitSnapshot] {
        if let keyed = response.rateLimitsByLimitId, !keyed.isEmpty {
            return keyed.sorted { $0.key < $1.key }.map(\.value)
        }
        return [response.rateLimits]
    }

    /// A bucket's windows, primary first.
    ///
    /// Primary before secondary is the server's own ordering and it happens to
    /// be shortest-first, which is what the design mocked: a five-hour window
    /// above a weekly one. Nothing sorts by duration, because a bucket whose
    /// windows arrived the other way round would then be silently reordered
    /// against what Codex itself shows.
    private static func windows(in bucket: RateLimitSnapshot) -> [QuotaWindow] {
        [bucket.primary, bucket.secondary].compactMap { window in
            window.map { quotaWindow($0, in: bucket) }
        }
    }

    private static func quotaWindow(
        _ window: RateLimitWindow, in bucket: RateLimitSnapshot
    ) -> QuotaWindow {
        QuotaWindow(
            limitName: nonEmpty(bucket.limitName),
            limitId: nonEmpty(bucket.limitId),
            windowDuration: duration(minutes: window.windowDurationMins),
            fractionUsed: fraction(usedPercent: window.usedPercent),
            resetsAt: resetDate(unixSeconds: window.resetsAt))
    }

    /// A percentage as a fraction, clamped.
    ///
    /// Clamped rather than rejected: a value outside 0–100 is the server saying
    /// something odd about a real window, and the nearest true statement is
    /// "none of it" or "all of it". Dropping the bar entirely would say "we do
    /// not know", which would be the less accurate of the two.
    private static func fraction(usedPercent: Int32) -> Double {
        min(1, max(0, Double(usedPercent) / 100))
    }

    /// `windowDurationMins` is minutes, and a non-positive one is not a window.
    ///
    /// **The multiplication is checked.** This number came from outside — the
    /// backend, by way of the user's `codex` — and an overflow in Swift is a
    /// *trap*, not an error: it would abort the process past every `catch`, past
    /// the exchange's error surface, and past the promise that a bad refresh
    /// leaves the previous reading alone. The same shape has bitten this
    /// repository twice already; see "Arithmetic on numbers a caller chose" in
    /// docs/dev/architecture.md.
    private static func duration(minutes: Int64?) -> Duration? {
        guard let minutes, minutes > 0 else { return nil }
        let (seconds, overflowed) = minutes.multipliedReportingOverflow(by: 60)
        guard !overflowed else { return nil }
        return .seconds(seconds)
    }

    /// `resetsAt` is Unix **seconds**, not milliseconds.
    ///
    /// Worth stating because getting it wrong is invisible: milliseconds read as
    /// seconds put the reset fifty thousand years out, and the row would say
    /// `resets in 18262500d` rather than fail. A non-positive stamp is treated
    /// as absent — zero is how "no value" reaches a field that has no null.
    private static func resetDate(unixSeconds: Int64?) -> Date? {
        guard let unixSeconds, unixSeconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    }

    /// A name made of whitespace is not a name. The server has sent `null` for
    /// `limitName` in every reading so far; an empty string is the same absence
    /// spelled differently, and it would render as a blank row title.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
