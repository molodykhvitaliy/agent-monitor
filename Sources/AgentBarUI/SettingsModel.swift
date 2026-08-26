import AgentBarCore
import Observation
import SwiftUI

/// The settings window's state.
///
/// Holds an editable copy of the preferences and writes the whole value back on
/// every change. One write path, no half-applied state, and no ordering
/// question about which of two toggles landed first.
@Observable
@MainActor
public final class SettingsModel {
    public private(set) var preferences: NotificationPreferences
    public private(set) var permission: NotificationPermission = .granted
    public private(set) var soundChoices: [SoundChoice] = []
    /// What the last action left behind — a refused sound file, a test sent.
    /// Cleared by the next action, because it is news for a moment and noise
    /// thereafter.
    public private(set) var lastMessage: Message?
    /// Set while a test is in flight so the button cannot be pressed twice.
    public private(set) var isTesting: Provider?
    /// Set while a file or application picker is open. `NSOpenPanel` does not
    /// refuse a second one, so without this a second press stacks two panels.
    public private(set) var isPicking = false
    /// Set while a removal is running, so the button cannot be pressed twice
    /// and the section can say what is happening.
    public private(set) var isRemoving = false
    /// The last self-test, or `nil` before the first one has finished.
    public private(set) var diagnostics: DiagnosticsReport?
    /// Whether the report on screen has been copied. Shown beside the button,
    /// and **not** through `lastMessage`: that line is rendered next to the Test
    /// buttons in `Events`, and a confirmation that appears three sections away
    /// from the control that caused it reads as something else happening.
    public private(set) var didCopyDiagnostics = false
    /// Set while one is being taken, so the button cannot be pressed twice.
    public private(set) var isDiagnosing = false
    /// Whether a removal has run in this session. The diagnostics section says
    /// so instead of reporting an app it has just disconnected as broken.
    public private(set) var hasRemoved = false
    /// What the last removal did, one line per thing it tried. `nil` until one
    /// has been run — the section shows its explanation and its button, and
    /// nothing else.
    ///
    /// Kept after the removal rather than cleared by the next action: a report
    /// that names two files the user still has to open by hand is the one piece
    /// of state in this window that must not disappear when they touch a toggle.
    public private(set) var removal: RemovalReport?
    /// The last request to show a section, and how many have been made.
    ///
    /// On the model rather than in the view's own `@State` for two reasons. It
    /// is the window's state, not a control's, and it outlives any one body
    /// evaluation; and a navigation that lives inside a `@State` cannot be
    /// driven from outside, which would leave "pressing a sidebar row moves the
    /// content" as the one claim in this window nothing could make.
    ///
    /// > **A count, not just a section, and the count is what makes it work.**
    /// > The sidebar's lit row deliberately does not follow the scroll position,
    /// > so a user can press `Sounds`, scroll away by hand, and then press the
    /// > still-lit `Sounds` row to come back — the most natural gesture there is
    /// > in a scroll-anchored sidebar. A view keyed on the section alone sees no
    /// > change and does nothing at all. Every request is distinct.
    public private(set) var navigation = NavigationRequest(section: .notifications, count: 0)

    /// Which sidebar row is lit.
    public var section: SettingsSection { navigation.section }

    /// Asks the content pane to show a section. Idempotent in what it selects
    /// and never idempotent in what it asks for.
    public func show(_ section: SettingsSection) {
        navigation = NavigationRequest(section: section, count: navigation.count + 1)
    }

    @ObservationIgnored private let services: any SettingsServices

    public struct Message: Sendable, Hashable {
        public let text: String
        public let isFault: Bool
    }

    public init(services: any SettingsServices) {
        self.services = services
        preferences = services.preferences()
        soundChoices = services.soundChoices()
    }

    public var providers: [Provider] { services.providers }
    public var launchAtLogin: LaunchAtLogin { services.launchAtLogin }

    /// Computed, for the reason `PanelModel.caffeine` is: the value lives in an
    /// observable object the assembly owns, so reading it in the view body is
    /// what makes the status line follow the assertion rather than the window's
    /// last refresh.
    public var caffeine: CaffeineIndicator { services.caffeine() }

    public func setCaffeine(_ setting: CaffeineSetting) {
        guard setting != caffeine.setting else { return }
        services.setCaffeine(setting)
        lastMessage = nil
    }

    /// Re-reads everything that can change while the window is closed: the
    /// permission the user may have revoked in System Settings, and the sounds
    /// they may have added to or removed from their Sounds folder.
    /// Re-reads everything that can change while the window is not looking.
    ///
    /// Called on appearance **and** whenever the app becomes active again, which
    /// is the case that matters: the documented recovery from a refusal is to
    /// leave for System Settings, turn AgentBar on, and come back. Without a
    /// refresh there, the window would still show the problem, the Test button
    /// would still send nothing, and every real notification would still be
    /// suppressed for the life of the process.
    public func refresh() async {
        await refresh(includingDiagnostics: true)
    }

    /// The same refresh, with the self-test optional. Only the removal path
    /// passes `false`, and it says why.
    private func refresh(includingDiagnostics: Bool) async {
        permission = await services.permission()
        soundChoices = services.soundChoices()
        preferences = services.preferences()
        // The user can revoke the login item in System Settings too, and the
        // service is the only honest source for its state.
        services.launchAtLogin.refresh()
        // Last, because it is the slowest — two configuration files and a
        // handful of `stat`s — and everything above it is what the window shows
        // first.
        guard includingDiagnostics else { return }
        await runDiagnostics()
    }

    // MARK: - Editing

    /// Every edit goes through here, so persistence cannot be forgotten in one
    /// branch and remembered in another.
    private func commit(_ change: (inout NotificationPreferences) -> Void) {
        var edited = preferences
        change(&edited)
        guard edited != preferences else { return }
        services.update(edited)
        // Re-read rather than trusting the edit: a sound that was chosen and
        // turns out to be unusable comes back carrying its problem, which is
        // how the row learns to say so.
        preferences = services.preferences()
        lastMessage = nil
    }

    public func setEnabled(_ isEnabled: Bool) {
        commit { $0.isEnabled = isEnabled }
    }

    public func setCellEnabled(_ isEnabled: Bool, provider: Provider, verb: NotificationVerb) {
        commit {
            guard var cell = $0.cell(for: provider, verb: verb) else { return }
            cell.isEnabled = isEnabled
            $0.update(cell)
        }
    }

    public func setSound(_ soundID: String, provider: Provider, verb: NotificationVerb) {
        commit {
            guard var cell = $0.cell(for: provider, verb: verb) else { return }
            cell.soundID = soundID
            $0.update(cell)
        }
        services.previewSound(id: soundID)
    }

    public func setQuietHours(enabled: Bool) {
        commit { $0.quietHoursEnabled = enabled }
    }

    public func setQuietHours(startMinute: Int) {
        commit { $0.quietStartMinute = startMinute }
    }

    public func setQuietHours(endMinute: Int) {
        commit { $0.quietEndMinute = endMinute }
    }

    public func setFocusSuppression(enabled: Bool) {
        commit { $0.focusSuppressionEnabled = enabled }
    }

    public func removeFocusApplication(_ application: FocusApplication) {
        commit { $0.focusApplications.removeAll { $0.id == application.id } }
    }

    // MARK: - Actions

    public func preview(_ choice: SoundChoice) {
        guard choice.isPlayable else { return }
        services.previewSound(id: choice.id)
    }

    public func requestPermission() async {
        permission = await services.requestPermission()
    }

    public func openSystemSettings() {
        services.openSystemNotificationSettings()
    }

    public func addSound() async {
        guard !isPicking else { return }
        isPicking = true
        defer { isPicking = false }
        guard let result = await services.addSoundFile() else { return }
        switch result {
        case .added(let id):
            soundChoices = services.soundChoices()
            lastMessage = Message(
                text: String(
                    localized: "Added to your Sounds folder",
                    comment: "Result of importing a notification sound"),
                isFault: false)
            services.previewSound(id: id)
        case .refused(let reason):
            lastMessage = Message(text: reason, isFault: true)
        }
    }

    public func revealSoundsFolder() {
        services.revealSoundsFolder()
    }

    public func addFocusApplication() async {
        guard !isPicking else { return }
        isPicking = true
        defer { isPicking = false }
        guard let application = await services.chooseApplication() else { return }
        commit {
            guard !$0.focusApplications.contains(where: { $0.id == application.id }) else { return }
            $0.focusApplications.append(application)
        }
    }

    /// Fires one notification per verb, through the real delivery path.
    ///
    /// The step's own validation criterion, made available to the user rather
    /// than left to a developer: nothing short of a real banner proves that a
    /// chosen sound plays, because `UNNotificationSound` falls back to the
    /// default without saying so.
    public func sendTest(for provider: Provider) async {
        guard isTesting == nil else { return }
        isTesting = provider
        defer { isTesting = nil }
        let result = await services.sendTestNotifications(for: provider)
        lastMessage = Message(text: result.text, isFault: result.isFault)
    }

    // MARK: - Diagnostics

    /// Runs the self-test and shows what it found.
    ///
    /// Not on a timer, and deliberately: it reads both providers' configuration
    /// files, and a settings window that stats `~/.claude` every second would be
    /// its own reason to open this section.
    public func runDiagnostics() async {
        guard !isDiagnosing else { return }
        // A removal is what makes these checks meaningless, and the user asking
        // for one anyway is what makes them meaningful again.
        hasRemoved = false
        isDiagnosing = true
        defer { isDiagnosing = false }
        // Cleared before the reading, not after it: what is on the clipboard is
        // the report that has just been replaced.
        didCopyDiagnostics = false
        diagnostics = await services.diagnostics()
    }

    public func copyDiagnostics() {
        guard let diagnostics else { return }
        services.copyToPasteboard(diagnostics.plainText)
        didCopyDiagnostics = true
    }

    // MARK: - Removal

    /// Takes AgentBar out of both providers' configuration and deletes the files
    /// it created.
    ///
    /// Deliberately does **not** quit afterwards. The report is the point of the
    /// flow — it is where a step that could not be carried out says so — and an
    /// app that removed its hooks and vanished would take that with it.
    public func removeEverything() async {
        guard !isRemoving else { return }
        isRemoving = true
        defer { isRemoving = false }
        lastMessage = nil
        removal = await services.removeEverything()
        // > **The self-test is dropped rather than re-run, and that is the
        // > point.** A clean removal stops the endpoint and deletes the helper,
        // > so a fresh reading necessarily reports `not listening` as a fault
        // > and `not deployed` as a warning, each with a remedy that would
        // > *undo the removal* — beside a summary saying both tools now behave
        // > as if AgentBar had never been installed. Two surfaces in one window
        // > contradicting each other, on the one whose whole purpose is
        // > explaining what is wrong.
        hasRemoved = true
        diagnostics = nil
        // Everything else this window renders can have moved: the login item
        // was unregistered, and the stored preferences are gone.
        await refresh(includingDiagnostics: false)
    }

    public func revealApplication() {
        services.revealApplication()
    }

    public func quitApplication() {
        services.quitApplication()
    }

    /// What the preview block shows, or `nil` when the settings would deliver
    /// nothing at all.
    ///
    /// Ordered by the verb table, first enabled wins — so turning `Question` off
    /// moves the preview to the next event the user would actually receive
    /// rather than to a banner they have just switched off. When the global
    /// switch is off, or every cell is, the answer is `nil` and the block says
    /// so in a sentence instead of showing a banner that will never arrive.
    public var preview: NotificationPreview? {
        guard preferences.isEnabled else { return nil }
        for verb in NotificationVerb.allCases {
            for provider in providers {
                guard let cell = preferences.cell(for: provider, verb: verb), cell.isEnabled
                else { continue }
                return NotificationPreview(
                    verb: verb,
                    provider: provider,
                    // The name the picker shows, including `Silent` — which is a
                    // real answer and not an absence. `nil` only when the stored
                    // id names nothing in the catalogue, which is the same
                    // condition the cell's own problem line reports.
                    soundName: soundChoices.first { $0.id == cell.soundID }?.name)
            }
        }
        return nil
    }

    /// Every sound problem currently on a cell, deduplicated, for the summary
    /// under the Sounds section. Recomputed from the cells on every read, so a
    /// sound the user has just fixed stops being reported without waiting for
    /// another notification to prove it.
    public var soundProblems: [String] {
        var seen: Set<String> = []
        return preferences.cells.compactMap { cell in
            guard let problem = cell.problem, seen.insert(problem).inserted else { return nil }
            return problem
        }
    }
}

extension Int {
    /// Minutes from midnight rendered as `22:00`, in the user's own locale.
    ///
    /// Built from `DateComponents` on a fixed reference day rather than by
    /// string arithmetic, so a 12-hour locale shows `10:00 PM` without this
    /// having to know that 12-hour locales exist.
    public var clockFaceTime: String {
        var components = DateComponents()
        components.hour = self / 60
        components.minute = self % 60
        let calendar = Calendar.current
        guard let date = calendar.date(from: components) else { return "\(self / 60):00" }
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// One request to show a section of the settings window.
///
/// The count is not decoration: two consecutive requests for the *same* section
/// have to be two distinct values, or a view that observes this cannot tell a
/// repeated press from no press at all.
nonisolated public struct NavigationRequest: Sendable, Hashable {
    public let section: SettingsSection
    public let count: Int
}

/// The one notification the settings window previews.
///
/// A value rather than a view model: the preview is a mirror and has no state of
/// its own, which is what stops it being a second place where the app decides
/// what a banner says.
nonisolated public struct NotificationPreview: Sendable, Hashable {
    public let verb: NotificationVerb
    public let provider: Provider
    public let soundName: String?

    public init(verb: NotificationVerb, provider: Provider, soundName: String?) {
        self.verb = verb
        self.provider = provider
        self.soundName = soundName
    }
}
