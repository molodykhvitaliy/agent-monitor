import AgentBarCore
import Foundation

@testable import AgentBarUI

/// A settings back end that records what the window asked it to do.
@MainActor
final class StubSettingsServices: SettingsServices {
    var providers: [Provider] = [.claudeCode]
    var stored: NotificationPreferences
    private(set) var writes: [NotificationPreferences] = []
    private(set) var previewed: [String] = []
    private(set) var tested: [Provider] = []
    var permissionState: NotificationPermission = .granted
    var importResult: SoundImportResult?
    var chosenApplication: FocusApplication?
    /// Applied to every value handed back, so a test can make a chosen sound
    /// come back carrying a problem the way a real library would.
    var decorate: (@MainActor (NotificationPreferences) -> NotificationPreferences)?

    /// Constructed on demand: `SMAppService` is an app-level service and this
    /// suite has no reason to touch it.
    private var login: LaunchAtLogin?

    init(preferences: NotificationPreferences? = nil) {
        stored =
            preferences
            ?? NotificationPreferences(
                cells: NotificationVerb.allCases.map {
                    NotificationCell(
                        provider: .claudeCode, verb: $0, isEnabled: true,
                        soundID: Self.defaultSoundID(for: $0))
                })
    }

    func preferences() -> NotificationPreferences {
        decorate?(stored) ?? stored
    }

    func update(_ preferences: NotificationPreferences) {
        stored = preferences
        writes.append(preferences)
    }

    /// Whatever the user has dropped into `~/Library/Sounds`, which is the one
    /// input to this window that AgentBar does not control the length of.
    var userSoundChoices: [SoundChoice] = []

    func soundChoices() -> [SoundChoice] {
        [
            SoundChoice(
                id: "agentbar.sound.default", name: "Default", group: .standard, isPlayable: false)
        ]
            + [
                NotificationVerb.question, .waiting, .finished, .failed,
            ].map {
                SoundChoice(
                    id: Self.defaultSoundID(for: $0),
                    name: Self.defaultSoundID(for: $0).replacingOccurrences(of: ".aiff", with: ""),
                    group: .bundled, isPlayable: true)
            } + userSoundChoices
    }

    static func defaultSoundID(for verb: NotificationVerb) -> String {
        "AgentBar \(verb == .approval ? NotificationVerb.waiting.title : verb.title).aiff"
    }

    func previewSound(id: String) { previewed.append(id) }
    func addSoundFile() async -> SoundImportResult? { importResult }
    func revealSoundsFolder() {}
    func permission() async -> NotificationPermission { permissionState }
    /// Counted, because "never re-prompt after a refusal" is a rule about how
    /// many times this is called and not about what it returns.
    private(set) var permissionRequests = 0
    func requestPermission() async -> NotificationPermission {
        permissionRequests += 1
        permissionState = .granted
        return permissionState
    }
    func openSystemNotificationSettings() {}
    func chooseApplication() async -> FocusApplication? { chosenApplication }
    var testResult = TestNotificationResult(text: "Sent 5 test notifications", isFault: false)

    func sendTestNotifications(for provider: Provider) async -> TestNotificationResult {
        tested.append(provider)
        return testResult
    }

    var caffeineIndicator = CaffeineIndicator()
    private(set) var caffeineWrites: [CaffeineSetting] = []

    func caffeine() -> CaffeineIndicator { caffeineIndicator }

    func setCaffeine(_ setting: CaffeineSetting) {
        caffeineWrites.append(setting)
        caffeineIndicator = CaffeineIndicator(
            setting: setting,
            isHolding: setting.isActive && caffeineIndicator.workingSessionCount > 0,
            workingSessionCount: caffeineIndicator.workingSessionCount)
    }

    private(set) var launchRefreshes = 0

    var launchAtLogin: LaunchAtLogin {
        launchRefreshes += 1
        if let login { return login }
        let created = LaunchAtLogin()
        login = created
        return created
    }

    // MARK: - Diagnostics and removal

    var diagnosticsReport = DiagnosticsReport(
        checks: [
            DiagnosticsCheck(
                id: "endpoint", title: "Loopback endpoint", verdict: .pass,
                detail: "127.0.0.1:47821")
        ],
        counters: [DiagnosticsCounter(id: "applied", label: "applied", value: 3)],
        recent: [],
        resources: "70 MB resident",
        takenAt: Date(timeIntervalSince1970: 0))
    private(set) var diagnosticsRuns = 0
    private(set) var copied: [String] = []

    func diagnostics() async -> DiagnosticsReport {
        diagnosticsRuns += 1
        return diagnosticsReport
    }

    func copyToPasteboard(_ text: String) { copied.append(text) }

    var removalReport = RemovalReport(steps: [
        RemovalStep(
            id: "claude-hooks", title: "Claude Code hooks", location: "~/.claude/settings.json",
            outcome: .removed())
    ])
    private(set) var removals = 0
    private(set) var reveals = 0
    private(set) var quits = 0

    func removeEverything() async -> RemovalReport {
        removals += 1
        return removalReport
    }

    func revealApplication() { reveals += 1 }
    func quitApplication() { quits += 1 }
}
