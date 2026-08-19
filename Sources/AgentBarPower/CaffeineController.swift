import AgentBarCore
import Foundation
import Observation
import os

/// Holds the Mac awake while an agent is working, and stops when none is.
///
/// The module's one stateful object. `CaffeineDemand` decides what should be
/// true, `PowerAsserting` makes it true, and this joins them and keeps the two
/// in step.
///
/// **Three things release the assertion, and they cover different failures.**
/// The watchdog stops a session staying `working` after its agent has died —
/// `StoreSnapshot` applies it on every read, so a missed `sweep()` cannot leave
/// the assertion held. Process death releases a process-owned assertion, which
/// is why this is not `/usr/bin/caffeinate`. And the lease releases it when this
/// controller itself stops evaluating, which is the only hole the other two
/// leave.
///
/// `@Observable` because the panel footer and the settings window render the
/// reading live, and it changes from underneath both of them.
@Observable
@MainActor
public final class CaffeineController {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "caffeine")

    /// What `pmset -g assertions` calls the assertion.
    public static let assertionName = "AgentBar"

    /// How often the lease is re-armed while the assertion is wanted.
    ///
    /// This is also the **only** thing that re-reads the store once the
    /// assertion is held: a session stuck in `working` produces no events by
    /// definition, which is the whole premise of the hazard, and the menu bar's
    /// clock does not reach this module.
    public static let defaultRenewalInterval: Duration = .seconds(30)

    /// How long the assertion survives without a renewal. Five renewal periods:
    /// long enough that a busy main actor never drops it by accident, short
    /// enough that a wedged app costs the user two and a half minutes of
    /// wakefulness rather than a flat battery.
    public static let defaultLease: Duration = .seconds(150)

    /// How long a burst of pushes is collected before one reading is taken. The
    /// menu bar's window, for the same reason: a busy turn moves a session
    /// several times a second, and one reading answers all of them.
    public static let pushCoalescingInterval: Duration = .milliseconds(150)

    /// What the interface shows, and the only thing outside this module that
    /// needs to know anything about the assertion.
    public private(set) var reading: CaffeineReading

    /// The instance's own timings. The defaults are the two constants above;
    /// they are injectable so a test can drive the renewal loop rather than
    /// standing in for it by calling `evaluate()` by hand — which would prove
    /// the release for a caller the app does not have.
    @ObservationIgnored public let renewalInterval: Duration
    @ObservationIgnored public let lease: Duration

    @ObservationIgnored private let assertion: any PowerAsserting
    @ObservationIgnored private let store: any CaffeineSettingsStoring
    @ObservationIgnored private var settings: CaffeineSettings
    /// How a fresh reading of the store is taken. Held rather than passed in on
    /// every call because the renewal task has to be able to ask by itself.
    @ObservationIgnored private var source: (@MainActor () async -> StoreSnapshot)?
    @ObservationIgnored private var renewal: Task<Void, Never>?
    /// The last IOKit call that did not succeed, kept so the interface can say
    /// so rather than only the log.
    @ObservationIgnored private var failure: String?
    /// The evaluation currently running, so the next one queues behind it
    /// instead of racing it across the `await` on the source.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    /// Set while a coalescing window is open, so a burst of pushes collapses
    /// into one reading.
    @ObservationIgnored private var pushPending = false
    /// Bumped by `start` and by `stop`. An evaluation carries the generation it
    /// began in and abandons itself if that has moved on, which is what stops a
    /// reading taken before a quit from being applied after one.
    @ObservationIgnored private var generation = 0

    public init(
        assertion: any PowerAsserting = IOKitPowerAssertion(),
        settings store: any CaffeineSettingsStoring = UserDefaultsCaffeineSettings(),
        renewalInterval: Duration = CaffeineController.defaultRenewalInterval,
        lease: Duration = CaffeineController.defaultLease
    ) {
        self.assertion = assertion
        self.store = store
        self.renewalInterval = renewalInterval
        self.lease = lease
        settings = store.load()
        reading = CaffeineReading(mode: settings.mode)
    }

    public var mode: CaffeineMode { settings.mode }

    // MARK: - Lifecycle

    /// Begins reacting, and takes one reading immediately.
    ///
    /// Immediately because AgentBar is usually launched while agents are already
    /// running, and the next event from a session halfway through a long `Bash`
    /// call may be half an hour away. Waiting for the push leg would mean the
    /// Mac sleeping under exactly the build this feature exists to protect.
    public func start(reading source: @escaping @MainActor () async -> StoreSnapshot) async {
        generation += 1
        self.source = source
        await evaluate()
    }

    /// The push leg's landing point, called for every batch of state moves.
    ///
    /// Takes no changes: a `StateChange` describes one session and the
    /// assertion is about all of them, so the only correct answer is a fresh
    /// reading. The batch itself is the signal that one is worth taking.
    ///
    /// Coalesced, like the menu bar's: a busy turn moves a session several times
    /// a second, and each reading costs a hop into the store the ingest path is
    /// also using. Delaying the assertion by a sixth of a second costs nothing —
    /// this is about whether the Mac falls asleep in the next quarter of an hour.
    public func stateDidChange() {
        guard !pushPending else { return }
        pushPending = true
        Task { [weak self] in
            try? await Task.sleep(for: Self.pushCoalescingInterval)
            self?.pushPending = false
            await self?.evaluate()
        }
    }

    /// Releases the assertion and stops evaluating.
    ///
    /// Clears the source as well, so nothing revives it afterwards: a push
    /// arriving during termination must not take an assertion the app is about
    /// to stop being able to release.
    public func stop() {
        generation += 1
        source = nil
        renewal?.cancel()
        renewal = nil
        inFlight?.cancel()
        inFlight = nil
        releaseAssertion()
        reading = CaffeineReading(mode: settings.mode)
    }

    // MARK: - The setting

    public func setMode(_ mode: CaffeineMode) {
        guard mode != settings.mode else { return }
        settings.setMode(mode)
        commitSetting()
    }

    /// The footer button: off, or back to the mode the settings window last
    /// chose.
    public func toggle() {
        settings.toggle()
        commitSetting()
    }

    /// Persists the choice, shows it immediately, and asks for a fresh reading.
    ///
    /// **Immediately** matters: `reading` is otherwise written only by an
    /// evaluation, and an evaluation needs a source. A picker whose `get`
    /// reverts after a `set` reads as a broken control even when the write
    /// landed, and with no source attached the reading would never catch up at
    /// all. What the assertion is doing is left as it was until the evaluation
    /// says otherwise — that half is not this method's to guess.
    private func commitSetting() {
        store.save(settings)
        reading = CaffeineReading(
            mode: settings.mode,
            isHolding: reading.isHolding,
            workingSessionCount: reading.workingSessionCount,
            failure: reading.failure)
        Task { await evaluate() }
    }

    // MARK: - Deciding

    /// Re-reads the store and makes the assertion match.
    ///
    /// Public so a caller that owns a run loop can drive it, and so a test can
    /// step a synthetic lifecycle without waiting out a renewal interval.
    /// Evaluations are **serialised**, each queued behind the one before it, so
    /// that `await evaluate()` returns with the assertion matching a reading
    /// taken after the call. Two overlapping evaluations would otherwise be free
    /// to apply their demands in the order they finished reading rather than the
    /// order they started, and the loser would leave the assertion describing a
    /// store that has already moved on.
    public func evaluate() async {
        let previous = inFlight
        let generation = generation
        let task = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == generation, let source = self.source else { return }
            let snapshot = await source()
            // Asked again, because reading the store suspends and `stop()` may
            // have run meanwhile. Without this, an evaluation already in flight
            // when the app quits would take an assertion a moment after the app
            // released its last one — and nothing would be left to let it go.
            guard self.generation == generation else { return }
            self.apply(CaffeineDemand.decide(mode: self.settings.mode, snapshot: snapshot))
        }
        inFlight = task
        await task.value
    }

    /// Carries out one demand. Idempotent: holding while already held renews
    /// rather than taking a second assertion, and releasing while nothing is
    /// held does nothing.
    private func apply(_ demand: CaffeineDemand) {
        guard demand.shouldHold else {
            if assertion.isHeld {
                Self.logger.notice("caffeine releasing: \(demand.details, privacy: .public)")
            }
            renewal?.cancel()
            renewal = nil
            releaseAssertion()
            reading = CaffeineReading(demand: demand, isHolding: assertion.isHeld, failure: failure)
            return
        }
        do {
            if assertion.isHeld {
                try assertion.renew(details: demand.details, lease: lease)
            } else {
                try assertion.take(
                    name: Self.assertionName, details: demand.details, lease: lease)
            }
            failure = nil
        } catch {
            // Reported, and reported to the interface rather than only to the
            // log: an indicator that claims to be keeping the Mac awake when the
            // system refused is worse than no indicator at all.
            Self.logger.error("caffeine could not hold the Mac awake: \(error, privacy: .public)")
            failure = "\(error)"
        }
        reading = CaffeineReading(demand: demand, isHolding: assertion.isHeld, failure: failure)
        // Started whenever a hold is *wanted*, not only when one was granted. A
        // refusal would otherwise be final until the next event, and a session
        // in the middle of a long `Bash` call is entitled to an hour of silence
        // — which is exactly the build this feature exists to protect.
        scheduleRenewal()
    }

    private func releaseAssertion() {
        do {
            try assertion.release()
            failure = nil
        } catch {
            Self.logger.error("power assertion could not be released: \(error, privacy: .public)")
            failure = "\(error)"
        }
    }

    /// Keeps the lease alive, and the decision fresh, for as long as a hold is
    /// wanted.
    ///
    /// Runs only while one is, so an idle AgentBar has no timer at all: the push
    /// leg is what wakes it, and every transition into `working` produces one.
    /// While it does run it is the **only** thing re-reading the store — a
    /// session stuck in `working` emits nothing by definition — so it is what
    /// carries the watchdog's verdict to the assertion.
    private func scheduleRenewal() {
        guard renewal == nil else { return }
        renewal = Task { [weak self, interval = renewalInterval] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return  // Cancelled by `apply` or by `stop`.
                }
                // Dropping the handle does not cancel the task, so a controller
                // that went away would otherwise leave this spinning for ever —
                // waking the process every interval to do nothing.
                guard let self else { return }
                await self.evaluate()
            }
        }
    }
}

/// What the interface shows about the assertion.
///
/// A value rather than a set of properties on the controller, so the panel
/// footer and the settings window cannot read a half-updated state, and so a
/// preview can build one.
public struct CaffeineReading: Sendable, Hashable {
    public let mode: CaffeineMode
    /// Whether an assertion is held **right now**.
    public let isHolding: Bool
    public let workingSessionCount: Int
    /// What the last IOKit call reported when it did not succeed. `nil` is the
    /// ordinary case. It can be set while `isHolding` is still true — a lease
    /// that failed to re-arm means an assertion that is held now and will not
    /// be for long, and the interface has to be able to say that.
    public let failure: String?

    public init(
        mode: CaffeineMode,
        isHolding: Bool = false,
        workingSessionCount: Int = 0,
        failure: String? = nil
    ) {
        self.mode = mode
        self.isHolding = isHolding
        self.workingSessionCount = workingSessionCount
        self.failure = failure
    }

    init(demand: CaffeineDemand, isHolding: Bool, failure: String?) {
        self.init(
            mode: demand.mode,
            isHolding: isHolding,
            workingSessionCount: demand.workingSessionCount,
            failure: failure)
    }
}
