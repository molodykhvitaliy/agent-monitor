import AgentBarCore
import AgentBarNotifications
import AgentBarUI
import AppKit
import Foundation
import os

/// Joins the settings window to the notification router.
///
/// The assembly point's half of `SettingsServices`, and the mirror of what
/// `ClaudeCodeIntegration` does for the install card: `AgentBarUI` may reach
/// only `AgentBarCore`, so every notification type is translated here, where
/// both modules are already linked.
///
/// The translation is deliberately dumb — two vocabularies for the same four
/// verbs, mapped one for one. That is the price of the module boundary, and it
/// is a price worth paying: it is what stops a view importing a sound library.
@MainActor
final class NotificationSettingsBridge: SettingsServices {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "notification-settings")

    /// The two sound ids that name no file.
    private enum StandardSound {
        static let systemDefault = "agentbar.sound.default"
        static let silent = "agentbar.sound.silent"
    }

    let providers: [Provider]
    let launchAtLogin = LaunchAtLogin()

    private let router: NotificationRouter
    private let preview = SoundPreview()
    private let caffeineBridge: CaffeineBridge

    init(router: NotificationRouter, providers: [Provider], caffeine: CaffeineBridge) {
        self.router = router
        self.providers = providers
        caffeineBridge = caffeine
    }

    // MARK: - Caffeine

    func caffeine() -> CaffeineIndicator { caffeineBridge.indicator() }

    func setCaffeine(_ setting: CaffeineSetting) { caffeineBridge.set(setting) }

    // MARK: - Preferences

    func preferences() -> NotificationPreferences {
        let settings = router.settings
        // One reading of both sound directories for the whole matrix. Asking
        // per cell would re-enumerate `~/Library/Sounds` eight times — sixteen
        // once Codex has a column — for an answer that cannot change between
        // them, on every toggle the user flips.
        let catalogue = router.sounds.catalogue()
        let cells = providers.flatMap { provider in
            NotificationVerb.allCases.map { verb in
                let preference = settings.preference(
                    for: provider, event: Self.event(for: verb))
                return NotificationCell(
                    provider: provider,
                    verb: verb,
                    isEnabled: preference.isEnabled,
                    soundID: Self.soundID(for: preference.sound),
                    problem: catalogue.problem(with: preference.sound)?.description)
            }
        }
        return NotificationPreferences(
            isEnabled: settings.isEnabled,
            cells: cells,
            quietHoursEnabled: settings.quietHours.isEnabled,
            quietStartMinute: settings.quietHours.startMinute,
            quietEndMinute: settings.quietHours.endMinute,
            focusSuppressionEnabled: settings.focusSuppression.isEnabled,
            focusApplications: settings.focusSuppression.applications.map {
                FocusApplication(bundleIdentifier: $0.bundleIdentifier, name: $0.name)
            })
    }

    /// Folds the window's whole value back into the router's.
    ///
    /// Cells the window did not show — a provider the assembly has not
    /// registered — are left exactly as they were rather than being dropped: a
    /// user who configures Codex, downgrades, and upgrades again should find
    /// their matrix intact.
    func update(_ preferences: NotificationPreferences) {
        var settings = router.settings
        settings.isEnabled = preferences.isEnabled
        for cell in preferences.cells {
            settings.update(
                EventPreference(
                    provider: cell.provider,
                    event: Self.event(for: cell.verb),
                    isEnabled: cell.isEnabled,
                    sound: Self.selection(for: cell.soundID)))
        }
        settings.quietHours = QuietHours(
            isEnabled: preferences.quietHoursEnabled,
            startMinute: preferences.quietStartMinute,
            endMinute: preferences.quietEndMinute)
        settings.focusSuppression = FocusSuppression(
            isEnabled: preferences.focusSuppressionEnabled,
            applications: preferences.focusApplications.map {
                SuppressingApplication(bundleIdentifier: $0.bundleIdentifier, name: $0.name)
            })
        router.update(settings)
    }

    // MARK: - Sounds

    func soundChoices() -> [SoundChoice] {
        var choices = [
            SoundChoice(
                id: StandardSound.systemDefault,
                name: String(localized: "Default", comment: "Sound choice"),
                group: .standard,
                isPlayable: false),
            SoundChoice(
                id: StandardSound.silent,
                name: String(localized: "None", comment: "Sound choice"),
                group: .standard,
                isPlayable: false),
        ]
        choices += router.sounds.available().map {
            SoundChoice(
                id: $0.name,
                name: $0.displayName,
                group: $0.origin == .bundled ? .bundled : .user,
                isPlayable: true)
        }
        return choices
    }

    func previewSound(id: String) {
        guard let file = router.sounds.file(named: id) else { return }
        preview.play(file)
    }

    /// Asks for a file, and copies it where the notification centre can find it.
    func addSoundFile() async -> SoundImportResult? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add Notification Sound", comment: "File picker title")
        panel.allowedContentTypes = [.aiff, .wav, .audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // Opens where the sounds a user is most likely to want already are.
        // They cannot be used from there — the notification centre does not look
        // in /System/Library/Sounds — which is exactly why this copies.
        panel.directoryURL = URL(filePath: "/System/Library/Sounds", directoryHint: .isDirectory)

        guard await panel.begin() == .OK, let source = panel.url else { return nil }
        do {
            return .added(id: try router.sounds.install(from: source).name)
        } catch let problem as SoundProblem {
            return .refused(reason: problem.description)
        } catch {
            Self.logger.error("sound could not be copied: \(error, privacy: .public)")
            return .refused(
                reason: String(
                    localized: "That file could not be copied into your Sounds folder",
                    comment: "Sound import failure"))
        }
    }

    func revealSoundsFolder() {
        let directory = router.sounds.userDirectory
        // Created on the way: a folder that does not exist yet cannot be opened,
        // and "nothing happened" is a worse answer than an empty window.
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    // MARK: - Permission

    func permission() async -> NotificationPermission {
        await router.refreshAuthorization()
        return Self.permission(for: router.authorization)
    }

    func requestPermission() async -> NotificationPermission {
        Self.permission(for: await router.requestAuthorization())
    }

    func openSystemNotificationSettings() {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.notifications")
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Focus suppression

    func chooseApplication() async -> FocusApplication? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose an Application", comment: "File picker title")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(filePath: "/Applications", directoryHint: .isDirectory)

        guard await panel.begin() == .OK, let url = panel.url,
            let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier
        else { return nil }
        return FocusApplication(
            bundleIdentifier: identifier,
            name: FileManager.default.displayName(atPath: url.path(percentEncoded: false)))
    }

    // MARK: - Test

    /// Runs the test and turns its outcome into the sentence the window shows.
    ///
    /// The one surface whose purpose is proving that notifications arrive, so
    /// every path that sends nothing says so. Reporting success here when the
    /// app is not authorised would leave a user in the documented recovery flow
    /// of `platform-integration.md` §6.3 being told the thing they cannot see
    /// is working.
    func sendTestNotifications(for provider: Provider) async -> TestNotificationResult {
        switch await router.sendTestNotifications(for: provider) {
        case .sent(let count):
            TestNotificationResult(
                text: String(
                    localized: "Sent \(count) test notifications",
                    comment: "Result of the settings window's test button"),
                isFault: false)
        case .notificationsOff:
            TestNotificationResult(
                text: String(
                    localized: "Nothing sent — notifications are turned off",
                    comment: "Result of the settings window's test button"),
                isFault: true)
        case .notAuthorised:
            TestNotificationResult(
                text: String(
                    localized: "Nothing sent — macOS has not authorised AgentBar",
                    comment: "Result of the settings window's test button"),
                isFault: true)
        case .everyEventDisabled:
            TestNotificationResult(
                text: String(
                    localized: "Nothing sent — every event is turned off for this provider",
                    comment: "Result of the settings window's test button"),
                isFault: true)
        case .failed(let reason):
            TestNotificationResult(text: reason, isFault: true)
        }
    }

    // MARK: - Translation

    private static func event(for verb: NotificationVerb) -> NotificationEvent {
        switch verb {
        case .question: .question
        case .waiting: .waiting
        case .finished: .finished
        case .failed: .failed
        }
    }

    private static func soundID(for selection: SoundSelection) -> String {
        switch selection {
        case .systemDefault: StandardSound.systemDefault
        case .silent: StandardSound.silent
        case .named(let name): name
        }
    }

    private static func selection(for id: String) -> SoundSelection {
        switch id {
        case StandardSound.systemDefault: .systemDefault
        case StandardSound.silent: .silent
        default: .named(id)
        }
    }

    private static func permission(
        for authorization: NotificationAuthorization
    ) -> NotificationPermission {
        switch authorization {
        case .authorized: .granted
        case .provisional: .quiet
        case .notDetermined: .notAsked
        case .denied: .refused
        }
    }
}

/// Renders each provider's badge once and keeps it on disk for the notification
/// centre to attach.
///
/// The directory is Caches, which is chosen for it by the app assembly: a badge
/// is derived and re-creatable, and it has to be, because
/// `UNNotificationAttachment` **moves** the file it is given into the
/// notification's own storage. Every badge is consumed by its first use and
/// rendered again on the next.
@MainActor
final class ProviderBadgeAttachments: NotificationAttachmentProviding {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "notifications")

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// A file URL for the badge, rendering it if the last one was consumed.
    ///
    /// Returns `nil` on any failure, which is a supported outcome rather than an
    /// error: the notification then names the provider in its title instead.
    func badgeImageURL(for provider: Provider) -> URL? {
        let url = directory.appending(path: "badge-\(provider.rawValue).png")
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        guard let png = ProviderBadgeImage.png(for: provider) else {
            Self.logger.error(
                "provider badge could not be rendered: \(provider.rawValue, privacy: .public)")
            return nil
        }
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            Self.logger.error("provider badge could not be written: \(error, privacy: .public)")
            return nil
        }
    }
}
