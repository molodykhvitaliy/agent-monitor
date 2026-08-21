import Darwin
import Foundation
import Testing

@testable import CodexAdapter

/// The helper's read of standard input, which is the one place in this project
/// that used to be able to wait for ever.
///
/// Codex spawns this binary on **every tool call**. A read with no deadline is
/// therefore not a slow path but an accumulating one: a writer that never closes
/// its end leaves a process behind, the process is reparented to `launchd` when
/// Codex exits, and by the end of a working day there are dozens of them sitting
/// in the directories the sessions ran in. Each of these tests fails if the
/// deadline is removed.
///
/// > **`.serialized`, and the reason is not this suite.** Every test here blocks
/// > a thread inside `poll` for as long as its bound lasts, because the drain is
/// > synchronous — that is what the helper does. Run in parallel these occupy
/// > several of the cooperative pool's threads at once, and the power and
/// > notification suites measure real intervals against that pool. Six clean
/// > runs of the suite before this file existed and two failures in three after
/// > it is the whole of the evidence. The bounds below are also as short as they
/// > can be while still being unambiguous.
@Suite("Helper standard input", .serialized)
struct StandardInputTests {

    /// A pipe whose ends the test owns, closed however the test leaves.
    private final class Pipe {
        let readEnd: Int32
        let writeEnd: Int32
        private var closedWrite = false

        init() throws {
            var descriptors: [Int32] = [0, 0]
            guard pipe(&descriptors) == 0 else {
                throw PipeUnavailable(code: errno)
            }
            let (readEnd, writeEnd) = (descriptors[0], descriptors[1])
            // A write into a pipe whose reader has gone must be an error, never
            // a signal. Every test here leaves a writer running behind a reader
            // that has already given up, and SIGPIPE would take the whole test
            // process — 796 passing tests with it — rather than fail one
            // expectation. Per descriptor, so no other suite's behaviour
            // changes. See the note on `RelayTests.drainsStandardInput`.
            //
            // Asserted, and both descriptors are closed by hand on the failure
            // path: an initialiser that throws after its stored properties are
            // set does not run `deinit`, so `self.readEnd`/`self.writeEnd`
            // assigned below and then abandoned would leak both ends.
            guard fcntl(writeEnd, F_SETNOSIGPIPE, 1) == 0 else {
                let code = errno
                close(readEnd)
                close(writeEnd)
                throw PipeUnavailable(code: code)
            }
            self.readEnd = readEnd
            self.writeEnd = writeEnd
        }

        func write(_ text: String) {
            let bytes = Array(text.utf8)
            bytes.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                _ = Darwin.write(writeEnd, base, buffer.count)
            }
        }

        func closeWriteEnd() {
            guard !closedWrite else { return }
            closedWrite = true
            close(writeEnd)
        }

        deinit {
            closeWriteEnd()
            close(readEnd)
        }
    }

    private struct PipeUnavailable: Error {
        let code: Int32
    }

    @Test("A writer that never closes its end does not hold the helper open")
    func budgetEndsAnUnclosedWrite() throws {
        let pipe = try Pipe()
        // Written before the drain starts, so the quiet period is measuring the
        // silence after a real payload rather than the wait for a first byte.
        pipe.write(#"{"hook_event_name":"Stop"}"#)
        // Deliberately no `closeWriteEnd()`: this is Codex having written the
        // payload and then held the descriptor, which is the shape that produced
        // a six-second hang against the shipped helper.

        let started = ContinuousClock.now
        let drained = StandardInput.drain(
            limit: 1024, quiet: .milliseconds(40), from: pipe.readEnd)
        let took = ContinuousClock.now - started

        #expect(
            drained.outcome == .expired, "the writer never finished, and that has to be reported")
        #expect(took < .milliseconds(400), "took \(took) against a 40 ms quiet period")
    }

    @Test("An unfinished payload is reported rather than relayed")
    func incompletePayloadIsNotWorthSending() throws {
        let pipe = try Pipe()
        pipe.write(#"{"hook_event_"#)

        let drained = StandardInput.drain(
            limit: 1024, quiet: .milliseconds(40), from: pipe.readEnd)

        #expect(drained.outcome == .expired)
        #expect(!drained.isComplete, "a fragment must never go out as though it were a payload")
        #expect(drained.total == 13, "what arrived is still counted, for the diagnostic")
    }

    @Test("A payload whose writer closes is delivered whole, and says so")
    func completePayloadIsNotATimeout() throws {
        let pipe = try Pipe()
        let payload = #"{"hook_event_name":"Stop","session_id":"abc"}"#
        pipe.write(payload)
        pipe.closeWriteEnd()

        let drained = StandardInput.drain(limit: 4096, from: pipe.readEnd)

        #expect(drained.isComplete)
        #expect(drained.total == payload.utf8.count)
        #expect(String(data: drained.data, encoding: .utf8) == payload)
    }

    /// The bounds have to be generous enough that nothing real ever meets them.
    ///
    /// `PostToolUse` carries `tool_response`, which for a large file read is
    /// megabytes — so the question a deadline raises is whether it can now drop
    /// an event that used to arrive. A payload at the endpoint's own limit,
    /// written by a blocking writer through a pipe that holds 64 KB at a time,
    /// is the worst case the helper can legitimately be handed.
    ///
    /// > Run against the **production** bounds, and that is the point. This is
    /// > the assertion that stopped the deadline from being a total: at 4 MB
    /// > through a 64 KB pipe the drain takes about a millisecond on an idle
    /// > machine and 93–105 ms with this suite running in parallel, so a total
    /// > budget tight enough to be polite to the agent would have been within
    /// > 2.5× of dropping a real event on a busy Mac. Measuring **silence**
    /// > instead makes the payload's own size irrelevant: a writer that is
    /// > writing never goes quiet, however long it takes.
    @Test("A payload at the endpoint's limit is not mistaken for a stalled writer")
    func aFullSizePayloadFitsInTheBudget() throws {
        let pipe = try Pipe()
        let size = CodexHelperRelay.maximumPayloadBytes
        // A **thread**, not a `Task`. The real writer is a separate process that
        // this one's cooperative pool cannot starve; a `Task.detached` here is on
        // the same pool as every other suite, so a gap between two 64 KB chunks
        // could be the scheduler rather than the writer — and the production
        // quiet period would correctly call that a stall. The harness has to be
        // faithful about which side is slow.
        let thread = Thread {
            let chunk = [UInt8](repeating: 0x61, count: 64 * 1024)
            var written = 0
            while written < size {
                let sent = chunk.withUnsafeBytes { buffer -> Int in
                    guard let base = buffer.baseAddress else { return 0 }
                    return Darwin.write(pipe.writeEnd, base, min(buffer.count, size - written))
                }
                if sent > 0 {
                    written += sent
                } else if errno != EINTR {
                    break
                }
            }
            pipe.closeWriteEnd()
        }
        thread.start()

        // The production bounds, both of them. Nothing here is given room: the
        // claim is that a payload this size never looks like a stalled writer.
        let drained = StandardInput.drain(limit: size, from: pipe.readEnd)

        #expect(
            drained.isComplete,
            "\(size / 1024) KB of a payload that was still arriving was read as a stalled writer")
        #expect(drained.total == size)
    }

    /// A writer that has not started is not a writer that has stopped.
    ///
    /// The helper is spawned before Codex writes into the pipe, and on a loaded
    /// machine that gap belongs to Codex. Applying the quiet period to it would
    /// abandon a payload that was always going to arrive — which is how the
    /// first version of this drain failed, under nothing worse than this
    /// repository's own suite running in parallel.
    @Test("A slow first byte is bounded by the ceiling, not by the quiet period")
    func theQuietPeriodDoesNotApplyBeforeTheFirstByte() throws {
        let pipe = try Pipe()
        let payload = #"{"hook_event_name":"SessionEnd"}"#
        let thread = Thread {
            // Far longer than the quiet period, comfortably inside the ceiling.
            Thread.sleep(forTimeInterval: 0.09)
            pipe.write(payload)
            pipe.closeWriteEnd()
        }
        thread.start()

        let drained = StandardInput.drain(
            limit: 4096, quiet: .milliseconds(25), ceiling: .seconds(5), from: pipe.readEnd)

        #expect(drained.isComplete)
        #expect(String(data: drained.data, encoding: .utf8) == payload)
    }

    /// The other half of the same claim: silence alone would not be a bound.
    ///
    /// A writer that dribbles resets the quiet period on every byte and would
    /// hold the helper open for as long as it cared to — the unbounded read
    /// again, wearing a deadline. The ceiling is what makes the drain bounded
    /// rather than merely patient.
    @Test("A writer that dribbles for ever is stopped by the ceiling")
    func theCeilingBoundsATricklingWriter() throws {
        let pipe = try Pipe()
        let trickling = Trickle()
        let thread = Thread {
            // One byte every 10 ms, for far longer than the ceiling allows: each
            // one lands inside an 80 ms quiet period, and none of them ends.
            for _ in 0..<200 where !trickling.isStopped {
                pipe.write("x")
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        thread.start()

        let started = ContinuousClock.now
        let drained = StandardInput.drain(
            limit: 4096, quiet: .milliseconds(80), ceiling: .milliseconds(60),
            from: pipe.readEnd)
        let took = ContinuousClock.now - started
        trickling.stop()

        #expect(drained.outcome == .expired)
        #expect(took < .seconds(2), "the ceiling did not bound the trickle: \(took)")
    }

    /// The quieter half of the same defect. The old loop treated `EAGAIN` as end
    /// of input, so a parent that left the descriptor non-blocking — which is
    /// nothing the helper controls — produced a silent, complete loss of the
    /// payload rather than a hang.
    @Test("A non-blocking descriptor is waited on rather than read as empty")
    func nonBlockingDescriptorStillDelivers() throws {
        let pipe = try Pipe()
        let flags = fcntl(pipe.readEnd, F_GETFL, 0)
        #expect(fcntl(pipe.readEnd, F_SETFL, flags | O_NONBLOCK) == 0)

        let payload = #"{"hook_event_name":"PostToolUse"}"#
        // A thread for the same reason the full-size test uses one: the writer
        // must not be competing with the reader for the pool that schedules it.
        let thread = Thread {
            Thread.sleep(forTimeInterval: 0.03)
            pipe.write(payload)
            pipe.closeWriteEnd()
        }
        thread.start()

        let drained = StandardInput.drain(limit: 4096, from: pipe.readEnd)

        #expect(drained.isComplete)
        #expect(String(data: drained.data, encoding: .utf8) == payload)
    }

    /// Lets the trickling writer stop once the drain has given up on it, so the
    /// thread does not outlive the test writing into a closed pipe.
    private final class Trickle: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func stop() {
            lock.lock()
            stopped = true
            lock.unlock()
        }
    }
}
