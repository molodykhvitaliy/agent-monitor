import Foundation

/// How a writing thread got on, handed back to the test that started it.
///
/// Both suites that write into a pipe do it from a `Thread` rather than a
/// `Task`: the real writer is a separate process that this one's cooperative
/// pool cannot starve, and a harness that *can* be starved is not faithful about
/// which side is slow. That leaves the ordinary problem of getting a value back
/// off a thread, and a semaphore is the whole of the answer — the count is
/// written before `signal()` and read after `wait()`, which is the happens-before
/// edge that makes the `@unchecked Sendable` honest.
///
/// > **It carries the failure as well as the count.** The first version of this
/// > recorded `payload.count` unconditionally after a `try?`, which turned the
/// > one assertion guarding "the helper never hands Codex a broken pipe" into a
/// > tautology: a helper that stopped draining would give the writer `EPIPE`,
/// > the `try?` would eat it, and the test would report a complete write and
/// > pass. A swallowed error and a successful write must not look the same.
final class WriteOutcome: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var written = 0
    private var failure: (any Error)?

    /// The writer finished, whole or not.
    func finish(written: Int, failure: (any Error)? = nil) {
        self.written = written
        self.failure = failure
        done.signal()
    }

    /// Blocks until the writer has finished, then reports what it managed.
    ///
    /// Callers must make sure the writer can always reach `finish` — for a
    /// blocked `write` that means closing the read end first, which is why the
    /// pipes here are marked `F_SETNOSIGPIPE`: the close turns the block into an
    /// `EPIPE` the loop can see rather than a signal that kills the process.
    func wait() -> (written: Int, failure: (any Error)?) {
        done.wait()
        return (written, failure)
    }

    /// The byte count alone, for the callers that assert on it directly.
    func waitForCount() -> Int { wait().written }
}
