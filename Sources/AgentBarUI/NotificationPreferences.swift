import AgentBarCore
import Foundation

/// The five notification verbs, as the settings window names them.
///
/// A second declaration of a vocabulary `AgentBarNotifications` also holds, and
/// deliberately so: the two modules are siblings below `AgentBarCore` and
/// neither may import the other, exactly as `IntegrationStatus` restates the
/// install report the adapters own. `Apps/AgentBar` links both and is where the
/// two are mapped onto each other.
///
/// These are **events**, not states, which is why `finished` appears here and
/// the five state words have no sixth (`docs/dev/design-spec.md` § Vocabulary).
nonisolated public enum NotificationVerb: String, Sendable, Hashable, CaseIterable, Identifiable {
    case question
    case approval
    case waiting
    case finished
    case failed

    public var id: String { rawValue }

    /// The word a notification's title starts with, and the row's label.
    public var title: String {
        switch self {
        case .question: String(localized: "Question", comment: "Notification verb")
        case .waiting: String(localized: "Waiting", comment: "Notification verb")
        case .approval: String(localized: "Approval", comment: "Notification verb")
        case .finished: String(localized: "Finished", comment: "Notification verb")
        case .failed: String(localized: "Failed", comment: "Notification verb")
        }
    }

    /// What the event actually is, in the user's terms. The settings window is
    /// the one place there is room to say it.
    public var explanation: String {
        switch self {
        case .question:
            String(
                localized: "An agent asked you something",
                comment: "Notification verb, explained")
        case .waiting:
            String(
                localized: "An agent is blocked and needs you",
                comment: "Notification verb, explained")
        case .approval:
            String(
                localized: "An agent requested access",
                comment: "Notification verb, explained")
        case .finished:
            String(localized: "An agent finished its turn", comment: "Notification verb, explained")
        case .failed:
            String(localized: "A turn ended in an error", comment: "Notification verb, explained")
        }
    }

    /// The underlying state shape this verb shares with rows and status glyphs.
    /// The settings matrix encloses Approval's waiting agent in a shield so it
    /// remains distinct from Question and Waiting without colour.
    ///
    /// `finished` maps to `idle`, which is the state it announces the arrival
    /// of — the hollow ring, correctly, since nothing needs doing.
    public var shape: SessionStateKind {
        switch self {
        case .question, .waiting, .approval: .waiting
        case .finished: .idle
        case .failed: .failed
        }
    }
}

/// Where a selectable sound came from, which is how the picker groups them.
nonisolated public enum SoundGroup: String, Sendable, Hashable, CaseIterable, Identifiable {
    /// Default and Silent — the two answers that need no file.
    case standard
    /// Shipped with AgentBar.
    case bundled
    /// The user's own `~/Library/Sounds`.
    case user

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .standard: String(localized: "Standard", comment: "Sound picker group")
        case .bundled: String(localized: "AgentBar", comment: "Sound picker group")
        case .user: String(localized: "Your Sounds", comment: "Sound picker group")
        }
    }
}

/// One entry in a sound picker.
nonisolated public struct SoundChoice: Sendable, Hashable, Identifiable {
    /// Opaque to the view; `Apps/AgentBar` maps it back to a selection.
    public let id: String
    public let name: String
    public let group: SoundGroup
    /// Whether this sound can be auditioned. The two standard entries cannot.
    public let isPlayable: Bool

    public init(id: String, name: String, group: SoundGroup, isPlayable: Bool) {
        self.id = id
        self.name = name
        self.group = group
        self.isPlayable = isPlayable
    }
}

/// One cell of the provider × event matrix.
nonisolated public struct NotificationCell: Sendable, Hashable, Identifiable {
    public let provider: Provider
    public let verb: NotificationVerb
    public var isEnabled: Bool
    public var soundID: String
    /// Set when the chosen sound cannot be played — the file was removed, is too
    /// long, or is in a format the notification centre will not take. Shown on
    /// the row, because a sound that silently plays as the default is the one
    /// failure the user cannot diagnose.
    public var problem: String?

    public var id: String { "\(provider.rawValue).\(verb.rawValue)" }

    public init(
        provider: Provider,
        verb: NotificationVerb,
        isEnabled: Bool,
        soundID: String,
        problem: String? = nil
    ) {
        self.provider = provider
        self.verb = verb
        self.isEnabled = isEnabled
        self.soundID = soundID
        self.problem = problem
    }
}

/// An application whose being frontmost silences notifications.
nonisolated public struct FocusApplication: Sendable, Hashable, Identifiable {
    public let bundleIdentifier: String
    public let name: String

    public var id: String { bundleIdentifier }

    public init(bundleIdentifier: String, name: String) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
    }
}

/// Everything the settings window shows and writes back.
///
/// A flat value rather than a live object: the window edits a copy and hands the
/// whole thing back, so there is one write path and no half-applied state.
nonisolated public struct NotificationPreferences: Sendable, Hashable {
    public var isEnabled: Bool
    public var cells: [NotificationCell]
    public var quietHoursEnabled: Bool
    /// Minutes from local midnight.
    public var quietStartMinute: Int
    public var quietEndMinute: Int
    public var focusSuppressionEnabled: Bool
    public var focusApplications: [FocusApplication]

    public init(
        isEnabled: Bool = true,
        cells: [NotificationCell] = [],
        quietHoursEnabled: Bool = false,
        quietStartMinute: Int = 22 * 60,
        quietEndMinute: Int = 8 * 60,
        focusSuppressionEnabled: Bool = false,
        focusApplications: [FocusApplication] = []
    ) {
        self.isEnabled = isEnabled
        self.cells = cells
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartMinute = quietStartMinute
        self.quietEndMinute = quietEndMinute
        self.focusSuppressionEnabled = focusSuppressionEnabled
        self.focusApplications = focusApplications
    }

    public func cell(for provider: Provider, verb: NotificationVerb) -> NotificationCell? {
        cells.first { $0.provider == provider && $0.verb == verb }
    }

    public mutating func update(_ cell: NotificationCell) {
        guard
            let index = cells.firstIndex(where: {
                $0.provider == cell.provider && $0.verb == cell.verb
            })
        else { return }
        cells[index] = cell
    }
}

/// What came back from importing a sound file.
nonisolated public enum SoundImportResult: Sendable, Hashable {
    /// Copied in, and selectable under its new name.
    case added(id: String)
    /// Refused, with the sentence explaining why — a format the notification
    /// centre will not take, a file over thirty seconds, or a copy that failed.
    case refused(reason: String)
}

/// What a test run did, in the words the window shows.
nonisolated public struct TestNotificationResult: Sendable, Hashable {
    public let text: String
    public let isFault: Bool

    public init(text: String, isFault: Bool) {
        self.text = text
        self.isFault = isFault
    }
}

/// What macOS has said about delivering notifications at all.
nonisolated public enum NotificationPermission: Sendable, Hashable {
    case granted
    /// Delivered without a banner, straight to Notification Center.
    case quiet
    case notAsked
    case refused

    /// The sentence the window shows above everything else, or `nil` when there
    /// is nothing wrong.
    public var problem: String? {
        switch self {
        case .granted:
            nil
        case .quiet:
            String(
                localized: "Notifications are delivered quietly, without a banner",
                comment: "Notification permission state")
        case .notAsked:
            String(
                localized: "AgentBar has not asked to send notifications yet",
                comment: "Notification permission state")
        case .refused:
            String(
                localized: "Notifications are turned off for AgentBar in System Settings",
                comment: "Notification permission state")
        }
    }

    /// Whether the window can do anything about it itself. macOS shows its
    /// prompt once and never again, so a refusal is only fixable in System
    /// Settings.
    public var canRequest: Bool { self == .notAsked }

    /// Whether a notification sent now would reach the user at all. The Test
    /// button is disabled when this is false, because a button that reports
    /// success having sent nothing is worse than one that cannot be pressed.
    public var canDeliver: Bool {
        switch self {
        case .granted, .quiet: true
        case .notAsked, .refused: false
        }
    }
}

/// Everything the settings window needs from the app that assembled it.
///
/// The same seam as `PanelServices`, for the same reason: `AgentBarUI` may reach
/// only `AgentBarCore`, so the notification router, the sound library and the
/// file pickers all arrive through this protocol.
@MainActor
public protocol SettingsServices: AnyObject {
    /// The providers the assembly actually registered, in display order.
    ///
    /// Never `Provider.allCases`: a Codex column before step 09 lands would
    /// offer settings for notifications that cannot arrive, which is the same
    /// mistake as the footer's hardcoded `1 of 2`.
    var providers: [Provider] { get }

    func preferences() -> NotificationPreferences
    func update(_ preferences: NotificationPreferences)

    func soundChoices() -> [SoundChoice]
    /// Plays a sound so the user can hear it. The only honest check available:
    /// validation proves a file loads, not that it is the sound they wanted.
    func previewSound(id: String)
    /// Opens a file picker, validates what comes back and copies it into the
    /// user's Sounds folder. `nil` when the user cancelled.
    func addSoundFile() async -> SoundImportResult?
    func revealSoundsFolder()

    func permission() async -> NotificationPermission
    func requestPermission() async -> NotificationPermission
    func openSystemNotificationSettings()

    /// Opens an application picker for the focus-suppression list.
    func chooseApplication() async -> FocusApplication?

    /// Sends one notification per verb for a provider, through the real path —
    /// the sound, the badge and the grouping included. Says what it actually
    /// did: this is the one surface whose purpose is proving delivery, so it
    /// must never claim to have sent what it did not.
    func sendTestNotifications(for provider: Provider) async -> TestNotificationResult

    var launchAtLogin: LaunchAtLogin { get }

    /// What Caffeine is doing, and what it has been told to do.
    ///
    /// The same seam as the panel's, reaching the same observable controller,
    /// which is what keeps the status line in the `Caffeine` section live while
    /// the window is open.
    func caffeine() -> CaffeineIndicator

    func setCaffeine(_ setting: CaffeineSetting)

    // MARK: - Diagnostics

    /// Runs the self-test and gathers everything the diagnostics section shows.
    ///
    /// Touches the disk — it reads both providers' configuration — so it is
    /// called when the window appears and when the user asks, never on a timer.
    func diagnostics() async -> DiagnosticsReport

    /// Puts the report on the clipboard, which is what a bug report needs.
    func copyToPasteboard(_ text: String)

    // MARK: - Removal

    /// Takes AgentBar's hooks out of both providers' configuration and deletes
    /// the files it created, reporting each one separately.
    ///
    /// Never throws and never stops early: every step in the report ran, and a
    /// step that could not be carried out comes back as a `failed` carrying the
    /// instruction the user needs. See `RemovalReport`.
    func removeEverything() async -> RemovalReport

    /// Shows `AgentBar.app` in the Finder, so the last step — moving it to the
    /// Trash — is one the user can take without going looking for it. AgentBar
    /// deliberately does not delete itself: a running application unlinking its
    /// own bundle is a trick, and the honest end of an uninstall is the user
    /// dragging it away.
    func revealApplication()

    func quitApplication()
}
