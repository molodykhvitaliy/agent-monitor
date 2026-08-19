import AgentBarCore
import Foundation
import Synchronization

/// A clock the replay suites drive by hand.
///
/// A store fed by `SystemTimeSource` would refuse fixtures stamped at a fixed
/// epoch — `SessionStore` rejects an event dated in the future, and rightly so.
final class ManualClock: TimeSource {
    private struct Reading {
        var elapsed: Duration
        var wall: Date
    }

    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private let reading: Mutex<Reading>

    init(wallTime: Date = ManualClock.epoch) {
        reading = Mutex(Reading(elapsed: .zero, wall: wallTime))
    }

    var now: MonotonicInstant {
        MonotonicInstant.origin.advanced(by: reading.withLock { $0.elapsed })
    }

    var wallTime: Date { reading.withLock { $0.wall } }

    func advance(by seconds: Int) {
        reading.withLock {
            $0.elapsed += .seconds(seconds)
            $0.wall = $0.wall.addingTimeInterval(TimeInterval(seconds))
        }
    }
}
