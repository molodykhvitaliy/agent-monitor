import Foundation

/// How a duration reads in the panel, and how it reads to VoiceOver.
///
/// Two forms, deliberately different. The row shows `4m 12s`, which is compact
/// and set in tabular figures so a ticking row does not jitter. A screen reader
/// gets `4 minutes 12 seconds`, because `4m 12s` is read out as letters.
nonisolated public enum DurationText {

    /// At most two units, largest first, never zero-padded: `1m 3s`, not
    /// `1m 03s`.
    ///
    /// | Range | Form |
    /// |---|---|
    /// | < 1 min | `38s` |
    /// | 1–10 min | `4m 12s` |
    /// | > 10 min | `14m` |
    /// | > 1 h | `1h 20m` |
    public static func compact(_ duration: Duration) -> String {
        let units = Units(max(0, Int(duration.components.seconds)))
        let (days, hours, minutes, seconds) =
            (units.days, units.hours, units.minutes, units.seconds)

        if days > 0 {
            return hours > 0 ? "\(days)d \(hours)h" : "\(days)d"
        }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 10 {
            return "\(minutes)m"
        }
        if minutes > 0 {
            return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
        }
        return "\(seconds)s"
    }

    /// The same duration spelled out, for the row's accessibility label.
    public static func spoken(_ duration: Duration) -> String {
        let units = Units(max(0, Int(duration.components.seconds)))
        let (days, hours, minutes, seconds) =
            (units.days, units.hours, units.minutes, units.seconds)
        var parts: [String] = []
        if days > 0 { parts.append(unit(days, "day", "days")) }
        if hours > 0 { parts.append(unit(hours, "hour", "hours")) }
        if days == 0, minutes > 0 { parts.append(unit(minutes, "minute", "minutes")) }
        if days == 0, hours == 0, minutes <= 10, seconds > 0 || parts.isEmpty {
            parts.append(unit(seconds, "second", "seconds"))
        }
        return parts.isEmpty ? unit(0, "second", "seconds") : parts.joined(separator: " ")
    }

    /// A reset time, in the same units with a preposition: `resets in 2h 10m`.
    public static func resets(in duration: Duration) -> String {
        String(
            localized: "resets in \(compact(duration))",
            comment: "Time until a usage window resets, lower case; follows a percentage")
    }

    /// `Started 14:02, running 41m` — the row's tooltip, which absorbs
    /// `startedAt` and `uptime` without spending a pixel on either.
    public static func startedAndRunning(at start: Date, uptime: Duration) -> String {
        let time = start.formatted(date: .omitted, time: .shortened)
        return String(
            localized: "Started \(time), running \(compact(uptime))",
            comment: "Session row tooltip")
    }

    /// Days, hours, minutes and seconds of one duration.
    private struct Units {
        let days: Int
        let hours: Int
        let minutes: Int
        let seconds: Int

        init(_ total: Int) {
            days = total / 86400
            hours = (total % 86400) / 3600
            minutes = (total % 3600) / 60
            seconds = total % 60
        }
    }

    private static func unit(_ count: Int, _ singular: String, _ plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
