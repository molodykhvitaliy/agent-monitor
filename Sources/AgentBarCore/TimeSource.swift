import Foundation

/// A point on a monotonic timeline.
///
/// Only the difference between two instants from the same source is meaningful;
/// the origin is arbitrary. Deliberately not convertible to a `Date`, so an
/// elapsed time can never be computed from a wall clock by accident.
public struct MonotonicInstant: Sendable, Hashable, Comparable {
    /// The zero point. Useful to a test that wants a known starting position.
    public static let origin = MonotonicInstant(sinceOrigin: .zero)

    private let sinceOrigin: Duration

    public func advanced(by amount: Duration) -> MonotonicInstant {
        MonotonicInstant(sinceOrigin: sinceOrigin + amount)
    }

    public static func < (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Bool {
        lhs.sinceOrigin < rhs.sinceOrigin
    }

    /// Time elapsed from `rhs` to `lhs`; negative if they are the other way round.
    public static func - (lhs: MonotonicInstant, rhs: MonotonicInstant) -> Duration {
        lhs.sinceOrigin - rhs.sinceOrigin
    }
}

/// The domain's only reading of time, injectable so watchdog tests advance time
/// instead of sleeping.
///
/// Two readings, with different jobs. `now` measures: every duration, every
/// staleness decision and every timeout comes from it. `wallTime` is for
/// display and for stamping when something was observed — never for measuring
/// an interval, because it moves when NTP corrects the clock or the user
/// changes the date.
public protocol TimeSource: Sendable {
    var now: MonotonicInstant { get }
    var wallTime: Date { get }
}

/// The production time source.
///
/// `ContinuousClock` is the correct backing here because it keeps counting
/// while the Mac is asleep: a session that fell silent before a three-hour
/// sleep must read as three hours stale on wake. `SuspendingClock` stops during
/// sleep and would resurrect every stale session the moment the lid opens, and
/// `Date` is not monotonic at all.
public struct SystemTimeSource: TimeSource {
    /// Fixed for the life of the process and shared by every instance, so
    /// instants taken through different copies remain comparable.
    private static let origin = ContinuousClock().now

    public init() {}

    public var now: MonotonicInstant {
        let elapsed = SystemTimeSource.origin.duration(to: ContinuousClock().now)
        return MonotonicInstant.origin.advanced(by: elapsed)
    }

    public var wallTime: Date { Date() }
}
