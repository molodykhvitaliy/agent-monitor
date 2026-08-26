import Foundation

/// Keeps App Nap off while something in this process is time-critical.
///
/// > **Why the caffeine controller needs one.** AgentBar is `LSUIElement` with
/// > no visible window for most of its life, which is textbook App Nap
/// > eligibility — and App Nap throttles timers. The lease is re-armed every
/// > thirty seconds against a hundred-and-fifty-second expiry, so five throttled
/// > periods still fit; but *nothing measured that*, and the failure mode is the
/// > Mac going to sleep under a running build, which is the one thing this
/// > feature exists to prevent. An activity for exactly as long as a hold is
/// > wanted removes the question.
///
/// > **`userInitiatedAllowingIdleSystemSleep`, not `userInitiated`.** The
/// > difference is `idleSystemSleepDisabled`, and AgentBar already holds a real
/// > IOKit assertion for that — a leased one, released on three independent
/// > paths (ADR-0007). Taking a second, unleased claim on idle sleep through
/// > `NSProcessInfo` would be a way to keep the Mac awake that
/// > `CaffeineController.stop()` does not cover.
@MainActor
public protocol AppNapSuppressing: AnyObject {
    /// Begins an activity if none is running. Idempotent.
    func begin(reason: String)
    /// Ends it if one is. Idempotent.
    func end()
    var isSuppressing: Bool { get }
}

/// The real one, over `ProcessInfo.beginActivity`.
@MainActor
public final class ProcessActivitySuppression: AppNapSuppressing {
    private var token: (any NSObjectProtocol)?

    public init() {}

    public var isSuppressing: Bool { token != nil }

    public func begin(reason: String) {
        guard token == nil else { return }
        token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: reason)
    }

    public func end() {
        guard let token else { return }
        ProcessInfo.processInfo.endActivity(token)
        self.token = nil
    }
}

/// Does nothing, for tests and for any assembly that does not want the
/// behaviour. Records what it was asked so a suite can assert on it.
@MainActor
public final class RecordingAppNapSuppression: AppNapSuppressing {
    public private(set) var beginCount = 0
    public private(set) var endCount = 0
    public private(set) var lastReason: String?

    public init() {}

    public var isSuppressing: Bool { beginCount > endCount }

    public func begin(reason: String) {
        guard !isSuppressing else { return }
        beginCount += 1
        lastReason = reason
    }

    public func end() {
        guard isSuppressing else { return }
        endCount += 1
    }
}
