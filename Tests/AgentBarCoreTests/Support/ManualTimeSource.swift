import Foundation
import Synchronization

@testable import AgentBarCore

/// A clock the test drives by hand.
///
/// The whole point of `TimeSource` being injectable: a watchdog suite that
/// slept for its own timeouts would take hours and still be flaky. Advancing
/// both readings together also makes it possible to simulate the machine
/// sleeping — a single large jump is exactly what `ContinuousClock` reports on
/// wake.
final class ManualTimeSource: TimeSource {
    private struct Reading {
        var elapsed: Duration
        var wall: Date
    }

    private let reading: Mutex<Reading>

    init(wallTime: Date = Fixture.epoch) {
        reading = Mutex(Reading(elapsed: .zero, wall: wallTime))
    }

    var now: MonotonicInstant {
        MonotonicInstant.origin.advanced(by: reading.withLock { $0.elapsed })
    }

    var wallTime: Date {
        reading.withLock { $0.wall }
    }

    /// Moves both readings forward, the way real time does.
    func advance(by amount: Duration) {
        reading.withLock {
            $0.elapsed += amount
            $0.wall = $0.wall.addingTimeInterval(amount.asTimeInterval)
        }
    }

    /// Moves the wall clock without moving the monotonic one — an NTP
    /// correction, or the user changing the date. Nothing measured may notice.
    func skewWallClock(by amount: Duration) {
        reading.withLock { $0.wall = $0.wall.addingTimeInterval(amount.asTimeInterval) }
    }
}

extension Duration {
    var asTimeInterval: TimeInterval {
        let (whole, attoseconds) = components
        return TimeInterval(whole) + TimeInterval(attoseconds) * 1e-18
    }
}

extension Duration {
    static func minutes(_ count: Int) -> Duration { .seconds(count * 60) }
    static func hours(_ count: Int) -> Duration { .seconds(count * 60 * 60) }
}
