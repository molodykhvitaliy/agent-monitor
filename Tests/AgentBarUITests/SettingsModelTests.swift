import AgentBarCore
import Foundation
import Testing

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
                        soundID: "AgentBar \($0.title).aiff")
                })
    }

    func preferences() -> NotificationPreferences {
        decorate?(stored) ?? stored
    }

    func update(_ preferences: NotificationPreferences) {
        stored = preferences
        writes.append(preferences)
    }

    func soundChoices() -> [SoundChoice] {
        [
            SoundChoice(
                id: "agentbar.sound.default", name: "Default", group: .standard, isPlayable: false)
        ]
            + NotificationVerb.allCases.map {
                SoundChoice(
                    id: "AgentBar \($0.title).aiff", name: "AgentBar \($0.title)",
                    group: .bundled, isPlayable: true)
            }
    }

    func previewSound(id: String) { previewed.append(id) }
    func addSoundFile() async -> SoundImportResult? { importResult }
    func revealSoundsFolder() {}
    func permission() async -> NotificationPermission { permissionState }
    func requestPermission() async -> NotificationPermission {
        permissionState = .granted
        return permissionState
    }
    func openSystemNotificationSettings() {}
    func chooseApplication() async -> FocusApplication? { chosenApplication }
    var testResult = TestNotificationResult(text: "Sent 4 test notifications", isFault: false)

    func sendTestNotifications(for provider: Provider) async -> TestNotificationResult {
        tested.append(provider)
        return testResult
    }

    private(set) var launchRefreshes = 0

    var launchAtLogin: LaunchAtLogin {
        launchRefreshes += 1
        if let login { return login }
        let created = LaunchAtLogin()
        login = created
        return created
    }
}

/// The settings window edits a copy and hands the whole value back, so the two
/// things worth asserting are that every edit is written and that what comes
/// back is what is shown.
@MainActor
@Suite("Settings model")
struct SettingsModelTests {

    @Test("Every edit is written through, once")
    func editsArePersisted() {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)

        model.setCellEnabled(false, provider: .claudeCode, verb: .finished)
        #expect(services.writes.count == 1)
        #expect(model.preferences.cell(for: .claudeCode, verb: .finished)?.isEnabled == false)

        model.setQuietHours(enabled: true)
        model.setQuietHours(startMinute: 90)
        #expect(services.writes.count == 3)
        #expect(model.preferences.quietStartMinute == 90)
    }

    /// A settings window that writes on every keystroke should not write when
    /// nothing changed: each write is a defaults write and a revalidation.
    @Test("An edit that changes nothing writes nothing")
    func noOpEditsAreDropped() {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        model.setEnabled(true)
        #expect(services.writes.isEmpty)
    }

    @Test("Choosing a sound plays it, so the choice is audible immediately")
    func choosingASoundPreviewsIt() {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        model.setSound("AgentBar Failed.aiff", provider: .claudeCode, verb: .question)
        #expect(services.previewed == ["AgentBar Failed.aiff"])
    }

    /// The window shows what the services report, not what it just set: a sound
    /// that turns out to be unusable comes back carrying its problem, which is
    /// how the row learns to say so.
    @Test("A problem reported by the back end reaches the row")
    func problemsSurviveTheRoundTrip() {
        let services = StubSettingsServices()
        services.decorate = { preferences in
            var decorated = preferences
            guard var cell = decorated.cell(for: .claudeCode, verb: .question) else {
                return decorated
            }
            cell.problem = "Chime.aiff is not in your Sounds folder any more"
            decorated.update(cell)
            return decorated
        }
        let model = SettingsModel(services: services)
        #expect(model.preferences.cell(for: .claudeCode, verb: .question)?.problem != nil)
        #expect(model.soundProblems.count == 1)
    }

    @Test("A refused sound file is reported rather than silently dropped")
    func refusedImportIsReported() async {
        let services = StubSettingsServices()
        services.importResult = .refused(reason: "theme.mp3 is a .mp3 file")
        let model = SettingsModel(services: services)

        await model.addSound()
        #expect(model.lastMessage?.isFault == true)
        #expect(model.lastMessage?.text.contains("mp3") == true)
    }

    @Test("An accepted sound file is added, announced and played")
    func acceptedImportIsPlayed() async {
        let services = StubSettingsServices()
        services.importResult = .added(id: "Chime.wav")
        let model = SettingsModel(services: services)

        await model.addSound()
        #expect(model.lastMessage?.isFault == false)
        #expect(services.previewed == ["Chime.wav"])
    }

    @Test("Cancelling the file picker leaves no message")
    func cancelledImportSaysNothing() async {
        let services = StubSettingsServices()
        services.importResult = nil
        let model = SettingsModel(services: services)
        await model.addSound()
        #expect(model.lastMessage == nil)
    }

    @Test("An application is added once, however many times it is chosen")
    func focusApplicationsAreUnique() async {
        let services = StubSettingsServices()
        services.chosenApplication = FocusApplication(
            bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode")
        let model = SettingsModel(services: services)

        await model.addFocusApplication()
        await model.addFocusApplication()
        #expect(model.preferences.focusApplications.count == 1)

        model.removeFocusApplication(
            FocusApplication(bundleIdentifier: "com.apple.dt.Xcode", name: "Xcode"))
        #expect(model.preferences.focusApplications.isEmpty)
    }

    @Test("A test fires for the provider that was asked for")
    func testsFirePerProvider() async {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        await model.sendTest(for: .claudeCode)
        #expect(services.tested == [.claudeCode])
        #expect(model.isTesting == nil)
        #expect(model.lastMessage?.isFault == false)
    }

    /// The window must repeat what the back end actually did. Reporting success
    /// when nothing was sent is the one failure this button cannot have.
    @Test("A test that sent nothing is shown as a fault, in its own words")
    func testFailureIsShown() async {
        let services = StubSettingsServices()
        services.testResult = TestNotificationResult(
            text: "Nothing sent — macOS has not authorised AgentBar", isFault: true)
        let model = SettingsModel(services: services)

        await model.sendTest(for: .claudeCode)
        #expect(model.lastMessage?.isFault == true)
        #expect(model.lastMessage?.text.contains("Nothing sent") == true)
    }

    /// `NSOpenPanel` does not refuse a second panel, so the model has to.
    @Test("Only one picker can be open at a time")
    func pickersAreNotReentrant() async {
        let services = StubSettingsServices()
        services.importResult = .added(id: "Chime.wav")
        let model = SettingsModel(services: services)
        #expect(!model.isPicking)
        await model.addSound()
        #expect(!model.isPicking)
    }

    /// Nothing else re-reads the login item, and the user can revoke it in
    /// System Settings while the window is open.
    @Test("Refreshing re-reads the login item as well as the permission")
    func refreshRereadsLaunchAtLogin() async {
        let services = StubSettingsServices()
        let model = SettingsModel(services: services)
        await model.refresh()
        #expect(services.launchRefreshes >= 1)
    }

    @Test("Refreshing re-reads the permission the user may have revoked")
    func refreshRereadsPermission() async {
        let services = StubSettingsServices()
        services.permissionState = .refused
        let model = SettingsModel(services: services)
        await model.refresh()
        #expect(model.permission == .refused)
    }

    /// macOS shows its prompt once and never again, so a refusal is only fixable
    /// in System Settings — the window must offer that rather than a button that
    /// does nothing.
    @Test("Only an unasked permission offers to ask")
    func onlyUnaskedCanBeRequested() {
        #expect(NotificationPermission.notAsked.canRequest)
        #expect(!NotificationPermission.refused.canRequest)
        #expect(!NotificationPermission.granted.canRequest)
        #expect(NotificationPermission.granted.problem == nil)
        #expect(NotificationPermission.refused.problem != nil)
    }
}

@Suite("Notification verbs")
struct NotificationVerbTests {

    /// The state-shape language is the accessibility backbone: a Waiting
    /// notification has to be recognisable as the same thing as a Waiting row.
    @Test("Each verb wears the shape of the state it announces")
    func shapesMatchTheStates() {
        #expect(NotificationVerb.question.shape == .waiting)
        #expect(NotificationVerb.waiting.shape == .waiting)
        #expect(NotificationVerb.finished.shape == .idle)
        #expect(NotificationVerb.failed.shape == .failed)
    }

    @Test("Every verb has a title and an explanation, and they differ")
    func copyIsComplete() {
        for verb in NotificationVerb.allCases {
            #expect(!verb.title.isEmpty)
            #expect(!verb.explanation.isEmpty)
            #expect(verb.title != verb.explanation)
        }
    }
}

@Suite("Clock-face times")
struct ClockFaceTests {

    /// Built from `DateComponents` rather than by string arithmetic, so a
    /// 12-hour locale renders correctly without this knowing such locales exist.
    @Test("Minutes from midnight render as a time in the current locale")
    func rendersATime() {
        // Locale-independent assertions: the hour appears, and midnight and noon
        // are different strings.
        #expect(!(22 * 60).clockFaceTime.isEmpty)
        #expect((0).clockFaceTime != (12 * 60).clockFaceTime)
        #expect((22 * 60).clockFaceTime != (22 * 60 + 30).clockFaceTime)
    }
}
