import AgentBarCore
import Foundation

@testable import AgentBarNotifications

/// Records what would have been delivered.
@MainActor
final class RecordingPresenter: NotificationPresenting {
    private(set) var posted: [PreparedNotification] = []
    private(set) var registeredCategories: [String] = []
    private(set) var authorizationRequests = 0
    var status: NotificationAuthorization
    /// Set to make `post` report a failure, as a real centre can.
    var failure: String?

    init(status: NotificationAuthorization = .authorized) {
        self.status = status
    }

    func registerCategories(_ identifiers: [String]) {
        registeredCategories = identifiers
    }

    func authorizationStatus() async -> NotificationAuthorization { status }

    func requestAuthorization() async -> NotificationAuthorization {
        authorizationRequests += 1
        return status
    }

    func post(_ notification: PreparedNotification) async -> String? {
        posted.append(notification)
        return failure
    }
}

@MainActor
final class StubFrontmostApplication: FrontmostApplicationReading {
    var bundleIdentifier: String?

    init(bundleIdentifier: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
    }

    func frontmostBundleIdentifier() -> String? { bundleIdentifier }
}

@MainActor
final class StubAttachments: NotificationAttachmentProviding {
    var url: URL?

    init(url: URL? = nil) {
        self.url = url
    }

    func attachmentURL(for event: NotificationEvent) -> URL? { url }
}

/// Time the test moves by hand, so a coalescing window costs no wall-clock.
final class ManualClock: TimeSource, @unchecked Sendable {
    private(set) var instant = MonotonicInstant.origin
    private(set) var wall = Date(timeIntervalSince1970: 1_800_000_000)

    var now: MonotonicInstant { instant }
    var wallTime: Date { wall }

    func advance(by amount: Duration) {
        instant = instant.advanced(by: amount)
        wall = wall.addingTimeInterval(
            TimeInterval(amount.components.seconds)
                + TimeInterval(amount.components.attoseconds) / 1e18)
    }

    /// Moves the wall clock alone, for the quiet-hours suite.
    func setWallTime(_ date: Date) { wall = date }
}

/// Sessions, projects and state changes for the suites.
enum Fixture {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func project(_ path: String = "/Users/dev/agentbar") -> ProjectRef {
        PathProjectResolver().project(for: URL(filePath: path))
    }

    static func change(
        _ session: String = "s1",
        provider: Provider = .claudeCode,
        project: String = "/Users/dev/agentbar",
        from: SessionState? = .working,
        to: SessionState? = .idle,
        at: Date = epoch
    ) -> StateChange {
        StateChange(
            sessionId: SessionID(session),
            provider: provider,
            project: Self.project(project),
            from: from,
            to: to,
            at: at)
    }

    static func draft(
        _ session: String = "s1",
        provider: Provider = .claudeCode,
        event: NotificationEvent = .finished,
        body: String? = nil,
        at: Date = epoch
    ) -> NotificationDraft {
        NotificationDraft(
            sessionId: SessionID(session),
            provider: provider,
            project: Self.project(),
            event: event,
            body: body,
            at: at)
    }
}

/// A directory of real audio files, built for one test and removed after it.
///
/// The sound suites are about what Core Audio says of a file on disk, so they
/// use real files: a mocked validator would only assert that the mock was
/// written to agree with itself.
struct SoundScratch: ~Copyable {
    let directory: URL

    init(name: String = UUID().uuidString) throws {
        directory = URL(filePath: NSTemporaryDirectory(), directoryHint: .isDirectory)
            .appending(path: "agentbar-sounds-\(name)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Writes a silent 16-bit mono 44.1 kHz WAV of the given length.
    ///
    /// Linear PCM in a container `UNNotificationSound` accepts, so the only
    /// thing under test is the property the caller is varying.
    @discardableResult
    func writeWave(_ name: String, seconds: Double) throws -> URL {
        let rate = 44_100
        let frames = Int(seconds * Double(rate))
        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(uint32: UInt32(36 + frames * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(uint32: 16)  // PCM header size
        data.append(uint16: 1)  // format: PCM
        data.append(uint16: 1)  // channels
        data.append(uint32: UInt32(rate))
        data.append(uint32: UInt32(rate * 2))  // byte rate
        data.append(uint16: 2)  // block align
        data.append(uint16: 16)  // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(uint32: UInt32(frames * 2))
        data.append(Data(count: frames * 2))

        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    /// Writes something that is not audio at all, under a name that claims it
    /// is.
    @discardableResult
    func writeGarbage(_ name: String) throws -> URL {
        let url = directory.appending(path: name)
        try Data("not audio".utf8).write(to: url)
        return url
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

extension Data {
    fileprivate mutating func append(uint32 value: UInt32) {
        let little = value.littleEndian
        append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: little >> ($0 * 8)) })
    }

    fileprivate mutating func append(uint16 value: UInt16) {
        let little = value.littleEndian
        append(contentsOf: (0..<2).map { UInt8(truncatingIfNeeded: little >> ($0 * 8)) })
    }
}

/// Builds routers for the suites, so two files can drive the same one.
@MainActor
enum RouterHarness {

    /// The bundled sounds, read from the repository rather than from a bundle:
    /// `swift test` has no app bundle, and these are the same bytes the app
    /// ships. A router without them would report every default as missing.
    static var shippedSounds: SoundLibrary {
        let directory = URL(filePath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // AgentBarNotificationsTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repository root
            .appending(path: "Apps/AgentBar/Sounds", directoryHint: .isDirectory)
        return SoundLibrary(userDirectory: directory)
    }

    static func router(
        presenter: RecordingPresenter,
        settings: NotificationSettings = NotificationSettings(),
        sounds: SoundLibrary? = nil,
        attachments: StubAttachments = StubAttachments(),
        frontmost: StubFrontmostApplication = StubFrontmostApplication(),
        coalescingWindow: Duration = NotificationCoalescer.window
    ) -> NotificationRouter {
        NotificationRouter(
            presenter: presenter,
            store: InMemoryNotificationSettings(settings),
            sounds: sounds
                ?? SoundLibrary(
                    userDirectory: URL(filePath: "/nonexistent", directoryHint: .isDirectory)),
            attachments: attachments,
            frontmost: frontmost,
            clock: ManualClock(),
            calendar: Calendar(identifier: .gregorian),
            coalescingWindow: coalescingWindow)
    }

    /// The same router, with authorisation already read.
    ///
    /// Started explicitly rather than in the initialiser, because the router
    /// refusing to post before `start()` is itself correct: until macOS has been
    /// asked, AgentBar does not know it may deliver, and guessing yes is the one
    /// direction it must not guess in.
    static func started(
        presenter: RecordingPresenter,
        settings: NotificationSettings = NotificationSettings(),
        sounds: SoundLibrary? = nil,
        attachments: StubAttachments = StubAttachments(),
        frontmost: StubFrontmostApplication = StubFrontmostApplication(),
        coalescingWindow: Duration = NotificationCoalescer.window
    ) async -> NotificationRouter {
        let router = router(
            presenter: presenter, settings: settings, sounds: sounds,
            attachments: attachments, frontmost: frontmost,
            coalescingWindow: coalescingWindow)
        await router.start()
        return router
    }
}
