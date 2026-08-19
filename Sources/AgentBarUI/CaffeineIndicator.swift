import Foundation

/// What Caffeine is allowed to do, as the settings window names it.
///
/// A second declaration of a vocabulary `AgentBarPower` also holds, and
/// deliberately so — the same arrangement as `NotificationVerb` and
/// `IntegrationStatus`. `AgentBarUI` may import only `AgentBarCore`, so the
/// power module's own `CaffeineMode` cannot appear here; `Apps/AgentBar` links
/// both and maps them one for one.
nonisolated public enum CaffeineSetting: String, Sendable, Hashable, CaseIterable, Identifiable {
    case never
    case whileWorking
    case always

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .never:
            String(localized: "Never", comment: "Caffeine setting")
        case .whileWorking:
            String(localized: "While an agent is working", comment: "Caffeine setting")
        case .always:
            String(localized: "Always", comment: "Caffeine setting")
        }
    }

    /// Whether this setting can ever hold the Mac awake.
    public var isActive: Bool { self != .never }
}

/// The Caffeine indicator: the footer button's whole state, and the settings
/// section's status line.
///
/// Declared here and populated by the app target, which is the only place that
/// links both the power module and the views.
nonisolated public struct CaffeineIndicator: Sendable, Hashable {
    public let setting: CaffeineSetting
    /// Whether a power assertion is held right now.
    public let isHolding: Bool
    /// How many sessions are working, reported whatever the setting — a Caffeine
    /// switched off beside three working agents is exactly the situation the
    /// indicator exists to make visible.
    public let workingSessionCount: Int
    /// What the system said when it refused. `nil` in the ordinary case.
    public let failure: String?

    public init(
        setting: CaffeineSetting = .whileWorking,
        isHolding: Bool = false,
        workingSessionCount: Int = 0,
        failure: String? = nil
    ) {
        self.setting = setting
        self.isHolding = isHolding
        self.workingSessionCount = workingSessionCount
        self.failure = failure
    }

    /// What the footer button draws.
    ///
    /// Four appearances rather than three, because "Caffeine is on and holding"
    /// and "Caffeine is on and nothing needs it" are different facts and the
    /// second must not read as the first. Colour is never the only difference:
    /// each appearance has its own silhouette.
    public enum Appearance: String, Sendable, Hashable {
        /// An assertion is held. Steam over a filled cup.
        case holding
        /// On, and nothing is working. Steam over an outlined cup.
        case armed
        /// Off. A plain cup, no steam.
        case off
        /// The system refused. Nothing is being kept awake, and saying so is
        /// the point.
        case failed
    }

    public var appearance: Appearance {
        if failure != nil { return .failed }
        if isHolding { return .holding }
        return setting.isActive ? .armed : .off
    }

    public var symbolName: String {
        switch appearance {
        case .holding: "cup.and.heat.waves.fill"
        case .armed: "cup.and.heat.waves"
        case .off: "cup.and.saucer"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    public var tint: ColorToken? {
        switch appearance {
        case .holding: .connected
        case .failed: .stateFailed
        case .armed, .off: nil
        }
    }

    /// The tooltip, the settings window's status line, and the spoken label —
    /// one sentence so the three cannot disagree.
    public var summary: String {
        if let failure { return failure }
        switch (appearance, setting) {
        case (.holding, .always):
            return String(
                localized: "Keeping your Mac awake", comment: "Caffeine status")
        case (.holding, _):
            return String(
                localized:
                    "Keeping your Mac awake\(DesignTokens.separator)\(workingSessionCount) working",
                comment: "Caffeine status, with the number of working sessions")
        case (.armed, _):
            return String(
                localized: "Not holding\(DesignTokens.separator)no agent is working",
                comment: "Caffeine status when nothing needs the Mac awake")
        default:
            return String(localized: "Caffeine is off", comment: "Caffeine status")
        }
    }

    /// What pressing the footer button will do. Its own sentence, because a
    /// tooltip that only describes the state leaves the user guessing whether
    /// the thing is a button at all.
    public var toggleLabel: String {
        setting.isActive
            ? String(localized: "Turn Caffeine Off", comment: "Footer button")
            : String(localized: "Turn Caffeine On", comment: "Footer button")
    }

    /// The limitation the design brief requires to be stated wherever the
    /// control lives. It is not a caveat about this implementation — no
    /// assertion type of any kind survives the lid closing.
    public static let limitation = String(
        localized: """
            This stops the Mac falling asleep on its own while an agent works. It does not \
            keep the display awake, it does not survive closing the lid, and macOS still \
            sleeps when the battery runs low.
            """,
        comment: "The honest limits of keeping the Mac awake")
}
