import AgentBarCore

/// What the assertion should be doing, decided from the mode and one reading of
/// the store.
///
/// Pure, and the whole of the decision: everything else in this module either
/// produces the inputs or carries out the answer. Keeping it a value is what
/// lets a synthetic lifecycle be asserted against without IOKit, an entitlement,
/// or a Mac that is willing to fall asleep during a test run.
///
/// `unknown` needs no special case here. `StoreSnapshot` applies the watchdog on
/// every read, so a session that has gone quiet is already reading as `unknown`
/// rather than `working` by the time it reaches this — which is exactly why a
/// missed `sweep()` cannot leave the assertion held.
public struct CaffeineDemand: Sendable, Hashable {
    public let mode: CaffeineMode
    public let workingSessionCount: Int
    public let shouldHold: Bool
    /// One line, in plain English, saying why. It is what `pmset -g assertions`
    /// shows next to the assertion and what the log prints on every change, so
    /// the state is diagnosable from outside the app. Deliberately not
    /// localised: it is a diagnostic, not interface copy.
    public let details: String

    public static func decide(mode: CaffeineMode, snapshot: StoreSnapshot) -> CaffeineDemand {
        let working = snapshot.sessions.filter { $0.state == .working }
        switch mode {
        case .never:
            return CaffeineDemand(
                mode: mode,
                workingSessionCount: working.count,
                shouldHold: false,
                details: "Caffeine is off")
        case .always:
            return CaffeineDemand(
                mode: mode,
                workingSessionCount: working.count,
                shouldHold: true,
                details: "Caffeine is set to keep this Mac awake at all times")
        case .whileWorking:
            return CaffeineDemand(
                mode: mode,
                workingSessionCount: working.count,
                shouldHold: !working.isEmpty,
                details: Self.describe(working))
        }
    }

    /// The project is named only when exactly one session is working, the same
    /// rule the status item's accessibility sentence follows: with more than one
    /// the count carries it, and a list of names would not fit a diagnostic line.
    private static func describe(_ working: [Session]) -> String {
        guard let only = working.first else { return "No agent is working" }
        guard working.count == 1 else { return "\(working.count) agent sessions working" }
        return "1 agent session working in \(only.project.name)"
    }
}
