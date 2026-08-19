import Foundation
import IOKit.pwr_mgt
import os

/// The real assertion, and the only file in AgentBar that imports IOKit.
///
/// `kIOPMAssertionTypePreventUserIdleSystemSleep` is the narrowest type that
/// does the job: it stops the *idle* timer putting the system to sleep and
/// nothing else. It deliberately does not keep the display awake, and it cannot
/// survive the lid closing — no assertion type can — which is why the interface
/// says so in the one place the toggle lives.
///
/// **The assertion carries a lease.** It is created with
/// `kIOPMAssertionTimeoutKey` and `kIOPMAssertionTimeoutActionTurnOff`, and the
/// controller re-arms it on a timer far shorter than the lease. Process death
/// already releases an assertion, and the watchdog already stops a session
/// staying `working` for ever; what the lease closes is the third hole — a live
/// process whose evaluation has stopped. Without it, a wedged main actor keeps
/// the Mac awake until the user notices and quits.
///
/// `TurnOff` rather than `Release` because the id stays valid after the lease
/// expires: `IOPMAssertionSetProperty` re-arms it and turns the assertion back
/// on, so a recovery needs no bookkeeping about whether the id is still real.
/// Verified on macOS 27 — see `docs/dev/platform-integration.md` §7.
@MainActor
public final class IOKitPowerAssertion: PowerAsserting {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "caffeine")

    /// `nonisolated(unsafe)` so `deinit` can let go of it. The id is only ever
    /// written from the main actor; the deinitialiser is the one reader that
    /// cannot be, and it runs when nothing else holds a reference.
    nonisolated(unsafe) private var assertion: IOPMAssertionID?
    /// When the current lease runs out. Read by `isHeld`, because owning an id
    /// and keeping the Mac awake stopped being the same thing the moment the
    /// assertion gained a timeout.
    private var armedUntil: ContinuousClock.Instant?

    public init() {}

    /// The last resort. A holder that is dropped without being released — a
    /// controller that goes out of scope, a test that forgets — would otherwise
    /// keep the Mac awake until the process ends. The kernel would still clean
    /// up on process death, but "until you quit AgentBar" is not the guarantee
    /// this module makes.
    deinit {
        guard let assertion else { return }
        _ = IOPMAssertionRelease(assertion)
    }

    /// Whether the assertion is holding the Mac awake **right now**.
    ///
    /// Not merely whether an id is owned. `TimeoutActionTurnOff` leaves the id
    /// valid after the lease expires and the assertion switched off, so an
    /// `assertion != nil` answer would report a hold that stopped minutes ago —
    /// the one direction
    /// [ADR-0007](../../docs/adr/ADR-0007-caffeine-is-a-leased-process-owned-assertion.md)
    /// says the indicator must never lie in. Erring towards "not holding" also
    /// costs nothing: the controller's answer to that is to arm it again.
    public var isHeld: Bool {
        guard assertion != nil, let armedUntil else { return false }
        return ContinuousClock.now < armedUntil
    }

    public func take(name: String, details: String, lease: Duration) throws {
        guard assertion == nil else { return try renew(details: details, lease: lease) }
        var created = IOPMAssertionID(0)
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleSystemSleep,
            kIOPMAssertionNameKey as String: name,
            kIOPMAssertionDetailsKey as String: details,
            kIOPMAssertionTimeoutKey as String: Self.seconds(lease),
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionTurnOff,
        ]
        let result = IOPMAssertionCreateWithProperties(properties as CFDictionary, &created)
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError(operation: "IOPMAssertionCreateWithProperties", code: result)
        }
        assertion = created
        armedUntil = ContinuousClock.now.advanced(by: lease)
        Self.logger.notice("power assertion taken: \(details, privacy: .public)")
    }

    /// Re-arms the lease, then refreshes the details.
    ///
    /// In that order on purpose: the lease is what keeps the Mac awake and the
    /// details are what explains it, so a refusal on the second must not have
    /// cost the first. A failure to update the details is still reported —
    /// `pmset -g assertions` showing a stale reason is a small lie, and this
    /// module's whole job is not telling small lies about power.
    public func renew(details: String, lease: Duration) throws {
        guard let assertion else {
            throw PowerAssertionError(
                operation: "IOPMAssertionSetProperty", code: kIOReturnNoDevice)
        }
        let armed = IOPMAssertionSetProperty(
            assertion, kIOPMAssertionTimeoutKey as CFString, Self.seconds(lease))
        guard armed == kIOReturnSuccess else {
            throw PowerAssertionError(operation: "IOPMAssertionSetProperty(Timeout)", code: armed)
        }
        armedUntil = ContinuousClock.now.advanced(by: lease)
        let described = IOPMAssertionSetProperty(
            assertion, kIOPMAssertionDetailsKey as CFString, details as CFString)
        guard described == kIOReturnSuccess else {
            throw PowerAssertionError(
                operation: "IOPMAssertionSetProperty(Details)", code: described)
        }
    }

    public func release() throws {
        guard let held = assertion else { return }
        // Dropped before the result is checked. Every documented failure of
        // `IOPMAssertionRelease` means the id is not one the system knows, and
        // keeping it would leave this holder refusing to take a new assertion
        // for ever on the strength of one it does not have.
        assertion = nil
        armedUntil = nil
        let result = IOPMAssertionRelease(held)
        guard result == kIOReturnSuccess else {
            throw PowerAssertionError(operation: "IOPMAssertionRelease", code: result)
        }
        Self.logger.notice("power assertion released")
    }

    /// The lease as IOKit wants it. Whole seconds, and never zero: a zero
    /// timeout is documented as "no timeout", which would turn the safety net
    /// into a permanent assertion — the exact failure it exists to prevent.
    private static func seconds(_ lease: Duration) -> CFNumber {
        max(1, lease.components.seconds) as CFNumber
    }
}
