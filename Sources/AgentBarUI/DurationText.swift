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

    /// How long a usage window is, as its name: `Weekly`, `5 hours`.
    ///
    /// Different from `compact` on purpose. `compact` measures something that is
    /// running and has to fit beside a ticking row; this names a fixed period
    /// and is read as a label, so the round ones get the word people use for
    /// them and the rest are spelled out. The design mocked exactly these two
    /// forms — a five-hour window above a weekly one.
    public static func window(_ duration: Duration) -> String? {
        let minutes = Int(duration.components.seconds / 60)
        guard minutes > 0 else { return nil }
        switch minutes {
        case 60:
            return String(localized: "Hourly", comment: "Name of a one-hour usage window")
        case 1440:
            return String(localized: "Daily", comment: "Name of a one-day usage window")
        case 10080:
            return String(localized: "Weekly", comment: "Name of a one-week usage window")
        case 43200:
            return String(localized: "Monthly", comment: "Name of a 30-day usage window")
        default:
            break
        }
        if minutes.isMultiple(of: 1440) {
            return String(
                localized: "\(minutes / 1440) days", comment: "Name of a usage window, in days")
        }
        if minutes.isMultiple(of: 60) {
            return String(
                localized: "\(minutes / 60) hours", comment: "Name of a usage window, in hours")
        }
        return String(
            localized: "\(minutes) minutes", comment: "Name of a usage window, in minutes")
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
