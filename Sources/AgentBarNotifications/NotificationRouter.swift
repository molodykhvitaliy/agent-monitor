import AgentBarCore
import Foundation
import Observation
import os

/// Turns state moves into notifications.
///
/// The module's one stateful object, and the only one that joins the pure parts
/// together: `NotificationPolicy` decides what a change means,
/// `NotificationCoalescer` decides how many of them a person should hear about,
/// `NotificationGate` decides whether this one should be delivered at all, and
/// `SoundLibrary` decides whether the sound the user picked still exists.
///
/// `@Observable` because the settings window renders the authorisation state
/// live, and it changes from underneath the window — when the user answers the
/// system prompt, and when they turn AgentBar on in System Settings after a
/// refusal, which is the documented recovery from
/// `platform-integration.md` §6.3.
@Observable
@MainActor
public final class NotificationRouter {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "notifications")

    public private(set) var authorization: NotificationAuthorization = .notDetermined
    public private(set) var settings: NotificationSettings

    @ObservationIgnored private let presenter: any NotificationPresenting
    @ObservationIgnored private let store: any NotificationSettingsStoring
    @ObservationIgnored private let attachments: any NotificationAttachmentProviding
    @ObservationIgnored private let frontmost: any FrontmostApplicationReading
    @ObservationIgnored private let clock: any TimeSource
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let coalescingWindow: Duration
    @ObservationIgnored private var coalescer = NotificationCoalescer()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var immediateQueue: [NotificationDraft] = []
    @ObservationIgnored private var immediateTask: Task<Void, Never>?
    @ObservationIgnored private var immediateGeneration = 0
    /// So the one suppression nobody can diagnose is shouted once, not per
    /// event. Reset whenever the answer changes.
    @ObservationIgnored private var hasReportedMissingAuthorization = false

    /// The sound library. Public because the settings window needs the same
    /// catalogue the router sends from — two lists that could disagree is how a
    /// picker starts offering a sound that will not play.
    public let sounds: SoundLibrary

    public init(
        presenter: any NotificationPresenting,
        store: any NotificationSettingsStoring = UserDefaultsNotificationSettings(),
        sounds: SoundLibrary = SoundLibrary(),
        attachments: any NotificationAttachmentProviding = NoNotificationAttachments(),
        frontmost: any FrontmostApplicationReading = NoFrontmostApplication(),
        clock: any TimeSource = SystemTimeSource(),
        calendar: Calendar = .autoupdatingCurrent,
        coalescingWindow: Duration = NotificationCoalescer.window
    ) {
        self.presenter = presenter
        self.store = store
        self.sounds = sounds
        self.attachments = attachments
        self.frontmost = frontmost
        self.clock = clock
        self.calendar = calendar
        self.coalescingWindow = coalescingWindow
        settings = store.load()
    }

    // MARK: - Lifecycle

    /// Registers the categories and asks for permission, once.
    ///
    /// A refusal is final until the user changes it in System Settings, so this
    /// asks only when nothing has been asked before. Re-prompting on every
    /// launch would achieve nothing except teaching the user to dismiss the
    /// prompt faster.
    public func start() async {
        presenter.registerCategories(NotificationEvent.allCases.map(\.categoryIdentifier))
        authorization = await presenter.authorizationStatus()
        // Asked only when nothing has been asked before; logged either way. A
        // launch that silently decides not to ask is indistinguishable from one
        // that failed to start, and the two need very different fixes.
        if authorization == .notDetermined {
            authorization = await presenter.requestAuthorization()
        }
        Self.logger.notice(
            "notification authorisation: \(self.authorization.rawValue, privacy: .public)")
    }

    /// Re-reads the authorisation status.
    ///
    /// Called when the settings window opens: the user can revoke permission in
    /// System Settings and the app is not told.
    public func refreshAuthorization() async {
        let previous = authorization
        authorization = await presenter.authorizationStatus()
        if authorization != previous { hasReportedMissingAuthorization = false }
    }

    /// Opens the system prompt when it has never been shown, so the settings
    /// window has something to offer beyond an explanation.
    @discardableResult
    public func requestAuthorization() async -> NotificationAuthorization {
        authorization = await presenter.requestAuthorization()
        return authorization
    }

    // MARK: - Settings

    public func update(_ settings: NotificationSettings) {
        self.settings = settings
        store.save(settings)
    }

    // MARK: - The push leg

    /// The landing point for the ingest boundary's state changes.
    ///
    /// Returns immediately: a sink that waits is a hook handler that waits, and
    /// nothing AgentBar installs may delay an agent. Human-required drafts are
    /// scheduled on the main actor with no timer; only `Finished` waits for the
    /// coalescing window.
    public func record(_ changes: [StateChange]) {
        let drafts = changes.compactMap(NotificationPolicy.draft(for:))
        guard !drafts.isEmpty else { return }
        for draft in drafts {
            if draft.event.isTimeSensitive {
                coalescer.discardPending(through: draft.at, for: draft.sessionId)
                immediateQueue.append(draft)
            } else {
                coalescer.enqueue(draft)
            }
        }
        if !immediateQueue.isEmpty { scheduleImmediateDelivery() }
        if !coalescer.isEmpty { scheduleFlush() }
    }

    private func scheduleImmediateDelivery() {
        guard immediateTask == nil else { return }
        let generation = immediateGeneration
        immediateTask = Task {
            // Yield once so `record` still returns before any notification
            // centre call. There is deliberately no clock-based delay here.
            await Task.yield()
            await flushImmediate(generation: generation)
        }
    }

    /// Delivers the urgent queue, re-reading the frontmost application per draft.
    ///
    /// > `flush()` reads it once for a batch drained in one turn, which is sound
    /// > because the answer cannot change without a suspension. This loop
    /// > suspends and `record()` appends while it runs, so a draft added after
    /// > the user switched applications would be judged against the one they
    /// > left — exactly the case focus suppression exists for.
    private func flushImmediate(generation: Int) async {
        while generation == immediateGeneration, !Task.isCancelled, !immediateQueue.isEmpty {
            let draft = immediateQueue.removeFirst()
            await deliver(
                draft, frontmostBundleIdentifier: frontmost.frontmostBundleIdentifier())
        }
        guard generation == immediateGeneration else { return }
        immediateTask = nil
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [coalescingWindow] in
            do {
                try await Task.sleep(for: coalescingWindow)
            } catch {
                // Cancelled by `stop()`. Returning **before** touching
                // `flushTask` is the whole of the fix: `stop()` already cleared
                // it, and a `record()` in between has since put a live task
                // there. Clearing it here would orphan that one, and the next
                // change would be delivered the instant it arrived rather than
                // when its own window closed.
                return
            }
            flushTask = nil
            await flush()
        }
    }

    /// Delivers everything the coalescer still thinks is worth saying.
    ///
    /// Exposed so a test can drive the decision path without waiting out a real
    /// window, and so a caller that is shutting down can drain what it has.
    public func flush() async {
        // An explicit drain includes urgent work that was scheduled but has not
        // had its actor turn yet. Tests and clean shutdown therefore retain the
        // old guarantee that `stop(); flush()` loses nothing.
        immediateTask?.cancel()
        immediateTask = nil
        immediateGeneration += 1
        let ready = (immediateQueue + coalescer.drain()).sorted {
            ($0.at, $0.sessionId) < ($1.at, $1.sessionId)
        }
        immediateQueue.removeAll(keepingCapacity: true)
        guard !ready.isEmpty else { return }
        // Re-read once for the whole batch rather than per draft: the answer
        // cannot change between two notifications posted in the same turn, and
        // `NSWorkspace` is a cross-process read.
        let frontmostIdentifier = frontmost.frontmostBundleIdentifier()
        for draft in ready {
            await deliver(draft, frontmostBundleIdentifier: frontmostIdentifier)
        }
    }

    /// Cancels the scheduled deliveries. For a clean shutdown.
    ///
    /// > **Both queues deliberately survive it**, because `flush()` promises
    /// > that `stop(); flush()` loses nothing. The consequence is worth naming
    /// > rather than removing: a `record()` after a `stop()` schedules a
    /// > delivery carrying the drafts from before it. Nothing in the app does
    /// > that, and emptying the queue here would make the drain lossy instead.
    public func stop() {
        flushTask?.cancel()
        flushTask = nil
        immediateTask?.cancel()
        immediateTask = nil
        immediateGeneration += 1
    }

    // MARK: - Testing against the real path

    /// What a test run actually did. Returned rather than logged, because the
    /// settings window has to say so: a button whose whole purpose is proving
    /// notifications arrive must not report success when it sent nothing.
    public enum TestOutcome: Sendable, Hashable {
        case sent(count: Int)
        case notificationsOff
        case notAuthorised
        case everyEventDisabled
        /// The notification centre refused at least one, with its reason.
        case failed(reason: String)
    }

    /// Fires one notification per event for a provider, exactly as a real one
    /// would be fired.
    ///
    /// The step's own validation criterion — "fire every event type for both
    /// providers; verify sound, content and grouping" — handed to the user
    /// rather than kept for a developer. Nothing short of a real banner can
    /// confirm that a chosen sound plays, because `UNNotificationSound(named:)`
    /// falls back to the default without saying so.
    ///
    /// Two deliberate differences from a real delivery. The coalescer is
    /// bypassed, or five notifications a millisecond apart would collapse into
    /// one. And quiet hours and focus suppression are bypassed, because the
    /// settings window is frontmost by definition and may well be on the
    /// suppression list. **The global switch and the matrix are not**: an event
    /// the user turned off sends nothing, so the test shows what they will
    /// actually get.
    @discardableResult
    public func sendTestNotifications(for provider: Provider) async -> TestOutcome {
        guard settings.isEnabled else { return .notificationsOff }
        guard authorization.allowsDelivery else {
            Self.logger.notice("test notifications skipped: not authorised")
            return .notAuthorised
        }

        var sent = 0
        var failure: String?
        for event in NotificationEvent.allCases {
            guard settings.preference(for: provider, event: event).isEnabled else { continue }
            let draft = NotificationDraft(
                sessionId: SessionID("agentbar.test.\(provider.rawValue).\(event.rawValue)"),
                provider: provider,
                project: Self.testProject,
                event: event,
                // The real shapes: the two events that carry a line get one,
                // and it says what it is rather than pretending to be an
                // agent's question or a provider's error.
                body: event == .question || event == .approval || event == .failed
                    ? String(
                        localized: "Test notification from AgentBar",
                        comment: "Body of a notification sent by the settings window")
                    : nil,
                at: clock.wallTime)
            if let reason = await presenter.post(prepared(draft)) {
                Self.logger.error("test notification not delivered: \(reason, privacy: .public)")
                failure = reason
            } else {
                sent += 1
            }
        }

        if let failure { return .failed(reason: failure) }
        return sent == 0 ? .everyEventDisabled : .sent(count: sent)
    }

    /// The project a test notification claims to come from.
    ///
    /// `root` is never read by a notification — only `name` and `id` are — but
    /// `ProjectRef` requires one, and pointing it at a directory that does not
    /// exist is the honest answer for a session that does not exist either.
    private static let testProject = ProjectRef(
        id: ProjectID("agentbar.test"),
        name: "AgentBar",
        root: URL(filePath: "/dev/null"))

    // MARK: - Delivery

    private func deliver(_ draft: NotificationDraft, frontmostBundleIdentifier: String?) async {
        let now = clock.now
        let gate = NotificationGate(settings: settings, calendar: calendar)
        let suppression =
            gate.suppression(
                for: draft,
                authorization: authorization,
                frontmostBundleIdentifier: frontmostBundleIdentifier,
                now: clock.wallTime)
            ?? (coalescer.isRepeat(draft, now: now) ? .repeated : nil)

        if let suppression {
            report(suppression, for: draft)
            return
        }

        // Recorded before the post rather than after: what starts the repeat
        // window is the decision to deliver. A notification the centre then
        // refuses is not one the user saw, but retrying it a second later would
        // be a second failure, not a recovery.
        coalescer.recordDelivery(of: draft, at: now)
        if let reason = await presenter.post(prepared(draft)) {
            Self.logger.error("notification not delivered: \(reason, privacy: .public)")
        }
    }

    /// Says why a notification was not sent.
    ///
    /// Mostly at `debug`, because a suppression is ordinary. `notAuthorized` is
    /// the exception and is reported **once** at `error`: it means AgentBar is
    /// running and doing nothing at all, which is the failure a user is least
    /// able to diagnose and the one `platform-integration.md` §6.3 exists for.
    /// Once, because logging it per event would bury it.
    private func report(_ suppression: NotificationSuppression, for draft: NotificationDraft) {
        if suppression == .notAuthorized, !hasReportedMissingAuthorization {
            hasReportedMissingAuthorization = true
            Self.logger.error(
                """
                notifications are suppressed because macOS has not authorised them; \
                turn AgentBar on in System Settings › Notifications
                """)
            return
        }
        Self.logger.debug(
            """
            \(draft.event.rawValue, privacy: .public) not delivered: \
            \(suppression.description, privacy: .public)
            """)
    }

    /// Renders a draft into the thing the notification centre takes.
    ///
    /// Two decisions live here and nowhere else. The art is looked up first,
    /// because whether it exists decides the title: with art the square carries
    /// the event and the subtitle carries the provider, without it the provider
    /// goes into the title as well so it cannot be lost to a truncated
    /// subtitle. And the sound is validated **again**, at send time, because
    /// `~/Library/Sounds` is the user's own folder and can be emptied between
    /// the moment they chose a sound and the moment it plays.
    func prepared(_ draft: NotificationDraft) -> PreparedNotification {
        let art = attachments.attachmentURL(for: draft.event)
        return PreparedNotification(
            identifier: draft.sessionId.value,
            threadIdentifier: draft.project.id.value,
            categoryIdentifier: draft.event.categoryIdentifier,
            title: art == nil ? draft.titleNamingProvider : draft.title,
            // Carried even when art was found, because finding a file is not
            // the same as attaching it: `UNNotificationAttachment` can still
            // refuse — it was consumed by an earlier post, or it fails the
            // system's own validation — and this title is what stops that
            // becoming a banner with no provider on it at all.
            titleWithoutBadge: draft.titleNamingProvider,
            subtitle: draft.subtitle,
            body: draft.body,
            sound: resolvedSound(for: draft),
            isTimeSensitive: draft.event.isTimeSensitive,
            attachment: art)
    }

    /// The chosen sound, or the default with the problem recorded.
    ///
    /// Falling back to the **default** rather than to silence is deliberate: a
    /// misconfigured sound must not also cost the user the notification's
    /// arrival. Silence is a choice they can make on purpose; it is not an error
    /// state.
    private func resolvedSound(for draft: NotificationDraft) -> SoundSelection {
        let selection = settings.preference(for: draft.provider, event: draft.event).sound
        guard let problem = sounds.problem(with: selection) else { return selection }
        // The settings window recomputes every cell's problem on each read, so
        // this is a log line and not a second place to keep the same fact.
        Self.logger.error(
            "sound unusable, falling back to the default: \(problem.description, privacy: .public)")
        return .systemDefault
    }
}
