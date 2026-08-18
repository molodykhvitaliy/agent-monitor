import Foundation
import Synchronization

/// Runs work that must produce an answer by a fixed time, whatever the work does.
///
/// A task group would be the obvious tool and is the wrong one: a group waits
/// for every child before it returns, so a handler that ignores cancellation
/// delays the response exactly as long as if there were no deadline at all.
/// Here the timer hands back an answer on its own, and the overrunning work is
/// cancelled and then abandoned — its late result is dropped rather than waited
/// for.
///
/// That distinction is the whole reason this exists. The synchronous path this
/// endpoint reserves is the Approve/Deny backlog item, where the work being
/// raced is a human deciding, and where "the timeout expired" must resolve to no
/// decision at all. A deadline that can be outlasted would eventually resolve to
/// whatever the handler said late, which for a permission prompt is the one
/// outcome this project forbids.
enum Deadline {
    /// The value the work produced, or `nil` if the deadline came first.
    static func run<Value: Sendable>(
        within timeout: Duration,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let mailbox = Mailbox<Value>()
        let work = Task { mailbox.deliver(await operation()) }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            mailbox.deliver(nil)
        }
        defer {
            work.cancel()
            timer.cancel()
        }
        return await mailbox.take()
    }
}

/// A single-use slot: whichever of the two racers arrives first wins, and the
/// other's answer is discarded.
///
/// `filled` carries the value, and it has to. The two racers are unstructured
/// tasks started before the caller reaches `take()`, so an answer routinely
/// arrives while the slot is still `empty` — a handler that returns without
/// suspending wins that race a measurable fraction of the time. A `filled` case
/// with nothing in it silently turned those into "the deadline came first",
/// which for the reserved Approve/Deny path would mean discarding a decision a
/// human had already given and reporting a timeout instead.
private final class Mailbox<Value: Sendable>: Sendable {
    private enum Slot {
        case empty
        case waiting(CheckedContinuation<Value?, Never>)
        case filled(Value?)
    }

    private let slot = Mutex(Slot.empty)

    func deliver(_ value: Value?) {
        let waiter: CheckedContinuation<Value?, Never>? = slot.withLock { current in
            switch current {
            case .filled:
                // The race is already decided; a late answer is dropped.
                return nil
            case .empty:
                current = .filled(value)
                return nil
            case .waiting(let continuation):
                current = .filled(value)
                return continuation
            }
        }
        waiter?.resume(returning: value)
    }

    func take() async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            let delivered: Value?? = slot.withLock { current in
                switch current {
                case .empty:
                    current = .waiting(continuation)
                    return nil
                case .filled(let value):
                    return .some(value)
                case .waiting:
                    // Single consumer by construction; there is no second taker.
                    return .some(nil)
                }
            }
            if let delivered { continuation.resume(returning: delivered) }
        }
    }
}
