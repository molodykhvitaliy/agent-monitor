import AgentBarCore
import Foundation

/// What one self-test check found.
///
/// Three verdicts, and the middle one earns its place: an integration that is
/// installed and not yet trusted is neither working nor broken, and calling it
/// either would make the surface that exists to explain silence the thing that
/// misexplains it.
nonisolated public enum DiagnosticsVerdict: String, Sendable, Hashable {
    case pass
    case warn
    case fail
}

/// One line of the self-test.
///
/// `detail` says what was actually found — a port, a count, a reason — and
/// `remedy` is present only when there is something for the user to do. A check
/// that fails with no remedy is one this app has no advice about, and saying
/// nothing is better than inventing something.
nonisolated public struct DiagnosticsCheck: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let verdict: DiagnosticsVerdict
    public let detail: String
    public let remedy: String?

    public init(
        id: String, title: String, verdict: DiagnosticsVerdict, detail: String,
        remedy: String? = nil
    ) {
        self.id = id
        self.title = title
        self.verdict = verdict
        self.detail = detail
        self.remedy = remedy
    }
}

/// A number the endpoint has been keeping.
nonisolated public struct DiagnosticsCounter: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let value: Int
    /// Whether a non-zero value is a problem. Deliveries are not; rejected
    /// payloads are.
    public let isFault: Bool

    public init(id: String, label: String, value: Int, isFault: Bool = false) {
        self.id = id
        self.label = label
        self.value = value
        self.isFault = isFault
    }
}

/// One thing the endpoint reported, as the surface shows it.
nonisolated public struct DiagnosticsEntry: Sendable, Hashable, Identifiable {
    public enum Severity: String, Sendable, Hashable {
        case info
        case notice
        case fault
    }

    public let id: Int
    public let at: Date
    public let severity: Severity
    public let message: String

    public init(id: Int, at: Date, severity: Severity, message: String) {
        self.id = id
        self.at = at
        self.severity = severity
        self.message = message
    }
}

/// Everything the diagnostics section shows, from one reading.
///
/// > **The surface a user reaches when nothing is happening.** Step 11's
/// > requirement is that a user who sees nothing can find out why *from inside
/// > the app* — the alternative being Console.app, which is not an answer. The
/// > checks say whether each link in the chain is there; the counters say
/// > whether anything has arrived and what was turned away; the log says what
/// > the endpoint actually reported, including the adapter parse failures that
/// > would otherwise be swallowed.
nonisolated public struct DiagnosticsReport: Sendable, Hashable {
    public let checks: [DiagnosticsCheck]
    public let counters: [DiagnosticsCounter]
    /// Most recent first.
    public let recent: [DiagnosticsEntry]
    /// Memory, processor time and uptime — the reading the 98 %-of-a-core
    /// episode wanted and did not have.
    public let resources: String
    public let takenAt: Date

    public init(
        checks: [DiagnosticsCheck],
        counters: [DiagnosticsCounter],
        recent: [DiagnosticsEntry],
        resources: String,
        takenAt: Date
    ) {
        self.checks = checks
        self.counters = counters
        self.recent = recent
        self.resources = resources
        self.takenAt = takenAt
    }

    public var hasFault: Bool { checks.contains { $0.verdict == .fail } }
    public var hasWarning: Bool { checks.contains { $0.verdict == .warn } }

    /// The one line above the list.
    public var summary: String {
        let failed = checks.count { $0.verdict == .fail }
        let warned = checks.count { $0.verdict == .warn }
        if failed > 0 {
            return String(
                localized: "\(failed) of \(checks.count) checks failed",
                comment: "Diagnostics summary")
        }
        if warned > 0 {
            return String(
                localized: "\(warned) of \(checks.count) checks need attention",
                comment: "Diagnostics summary")
        }
        return String(
            localized: "Everything AgentBar can check is in order",
            comment: "Diagnostics summary")
    }

    /// The whole report as text, for the clipboard and for the launch log.
    ///
    /// Plain and greppable on purpose: this is what goes into a bug report, and
    /// it must be readable by somebody who has never seen the window it came
    /// from. It carries no session content — checks, counts and the endpoint's
    /// own diagnostic lines, which are built from routes and reasons and never
    /// from a payload.
    public var plainText: String {
        var lines: [String] = ["AgentBar diagnostics — \(takenAt.formatted(.iso8601))"]
        lines.append("")
        for check in checks {
            lines.append("[\(check.verdict.rawValue.uppercased())] \(check.title): \(check.detail)")
            if let remedy = check.remedy { lines.append("        → \(remedy)") }
        }
        lines.append("")
        lines.append(counters.map { "\($0.label): \($0.value)" }.joined(separator: ", "))
        lines.append(resources)
        guard !recent.isEmpty else { return lines.joined(separator: "\n") }
        lines.append("")
        lines.append("Recent endpoint diagnostics, newest first:")
        for entry in recent {
            lines.append(
                "  \(entry.at.formatted(.iso8601)) \(entry.severity.rawValue) \(entry.message)")
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated extension DiagnosticsCheck {
    /// One provider row of the self-test, from the same `IntegrationStatus` the
    /// panel's integration card renders — so the two surfaces cannot disagree
    /// about what is wrong with a provider.
    ///
    /// > **Warn is a real rung.** `Not connected` is a choice as often as a
    /// > fault, and both `Needs repair` and `Installed, not trusted` describe a
    /// > provider whose configuration is there and merely wrong or unapproved;
    /// > painting any of them red would make the surface that exists to explain
    /// > silence the thing that misexplains it. The two failures are the ones
    /// > where AgentBar itself is the problem — it is not listening, or it
    /// > cannot read the file it would have to write.
    ///
    /// > **Every rung gets something to do.** A provider's own second line is a
    /// > diagnosis for some rungs (`Needs repair` says what drifted) and already
    /// > an instruction for others (`Installed, not trusted` says to run
    /// > `/hooks`). The action is appended where it is missing rather than
    /// > assumed, because a diagnostics row with no next step is a row that
    /// > tells a user they are stuck.
    public init(integration status: IntegrationStatus) {
        let verdict: DiagnosticsVerdict
        switch status.condition {
        case .connected: verdict = .pass
        case .notConnected, .needsRepair, .notTrusted: verdict = .warn
        case .notReceiving, .settingsUnreadable: verdict = .fail
        }
        self.init(
            id: "integration.\(status.provider.rawValue)",
            title: String(
                localized: "\(status.provider.displayName) hooks", comment: "Self-test check"),
            verdict: verdict,
            detail: status.condition.statusLine,
            remedy: Self.remedy(for: status))
    }

    /// What the user can do about this rung.
    ///
    /// `nil` only for `connected`, where there is nothing to do. Every other
    /// rung offers a button on the panel's card, so there is always at least
    /// that to say; the provider's own second line goes in front of it when it
    /// has one, because it is what the button is answering.
    private static func remedy(for status: IntegrationStatus) -> String? {
        let action = status.condition.action.map(\.label)
        switch status.condition {
        case .connected:
            return nil
        case .notTrusted:
            // Already an instruction — `CodexTrustStatus.description` says to run
            // `/hooks`. Appending "press Trust" would offer a button that only
            // re-reads what Codex decided.
            return status.detail
        case .notConnected, .needsRepair, .notReceiving, .settingsUnreadable:
            guard let action else { return status.detail }
            let press = String(
                localized: """
                    Press \(action) on the \(status.provider.displayName) row in AgentBar's \
                    panel.
                    """,
                comment: "Points at the button on the panel's integration card")
            guard let detail = status.detail else { return press }
            return "\(detail) — \(press)"
        }
    }
}

nonisolated extension DiagnosticsVerdict {
    /// The shape and the colour, together — a verdict is never carried by
    /// colour alone here any more than a session state is.
    public var indicator: (kind: SessionStateKind, color: ColorToken) {
        switch self {
        case .pass: (.working, .connected)
        case .warn: (.waiting, .stateWaiting)
        case .fail: (.failed, .stateFailed)
        }
    }
}

nonisolated extension DiagnosticsEntry.Severity {
    public var color: ColorToken {
        switch self {
        case .info: .ink400
        case .notice: .stateWaiting
        case .fault: .stateFailed
        }
    }
}
