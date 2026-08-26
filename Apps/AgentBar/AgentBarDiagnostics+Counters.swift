import AgentBarIngest
import AgentBarUI
import Foundation

/// The join between what the endpoint counts and what the diagnostics section
/// shows.
///
/// A file of its own because it is a vocabulary translation and nothing else —
/// the same shape, and for the same reason, as
/// `NotificationSettingsBridge.verb(for:)`: `AgentBarUI` may reach only
/// `AgentBarCore`, so the two enums cannot know about each other and the app
/// target is where they meet.
extension AgentBarDiagnostics {

    // MARK: - Translation

    /// The endpoint's counters, named for the surface.
    ///
    /// `isFault` marks the four that mean something was turned away. They are
    /// not errors on their own — one unauthorised request is a hook still
    /// carrying an old token, which the panel offers to repair — but they are
    /// the numbers a person scanning this block should see first.
    static func counters(_ counters: IngestCounters) -> [DiagnosticsCounter] {
        [
            DiagnosticsCounter(
                id: "deliveries",
                label: String(localized: "deliveries", comment: "Diagnostics counter"),
                value: counters.deliveries),
            DiagnosticsCounter(
                id: "applied",
                label: String(localized: "applied", comment: "Diagnostics counter"),
                value: counters.applied),
            DiagnosticsCounter(
                id: "ignored",
                label: String(localized: "ignored", comment: "Diagnostics counter"),
                value: counters.ignored),
            DiagnosticsCounter(
                id: "rejected",
                label: String(localized: "could not decode", comment: "Diagnostics counter"),
                value: counters.rejected, isFault: true),
            DiagnosticsCounter(
                id: "unauthorized",
                label: String(localized: "unauthorised", comment: "Diagnostics counter"),
                value: counters.unauthorized, isFault: true),
            DiagnosticsCounter(
                id: "malformed",
                label: String(localized: "malformed", comment: "Diagnostics counter"),
                value: counters.malformed, isFault: true),
            DiagnosticsCounter(
                id: "unroutable",
                label: String(localized: "no route", comment: "Diagnostics counter"),
                value: counters.unroutable, isFault: true),
            DiagnosticsCounter(
                id: "timeouts",
                label: String(localized: "handler timeouts", comment: "Diagnostics counter"),
                value: counters.handlerTimeouts, isFault: true),
            DiagnosticsCounter(
                id: "transport",
                label: String(localized: "transport failures", comment: "Diagnostics counter"),
                value: counters.transportFailures, isFault: true),
            DiagnosticsCounter(
                id: "refused",
                label: String(localized: "connections refused", comment: "Diagnostics counter"),
                value: counters.connectionsRefused, isFault: true),
        ]
    }

    static func entry(_ entry: IngestDiagnosticEntry) -> DiagnosticsEntry {
        DiagnosticsEntry(
            id: entry.id, at: entry.at, severity: severity(entry.severity),
            message: entry.message)
    }

    /// Written out rather than bridged through a raw value: the two enums happen
    /// to agree today, and a round trip would turn a future divergence into a
    /// silent fallback instead of a compiler error. The same rule
    /// `NotificationSettingsBridge.verb(for:)` follows next door.
    static func severity(_ severity: IngestDiagnostic.Severity) -> DiagnosticsEntry.Severity {
        switch severity {
        case .info: .info
        case .notice: .notice
        case .fault: .fault
        }
    }
}
