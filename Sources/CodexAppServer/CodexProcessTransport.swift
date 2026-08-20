import Foundation
import os

/// `codex app-server` as a child process on stdio.
///
/// The only subprocess AgentBar ever spawns, and the reason `Process` is
/// restricted to this module by `ModuleBoundaryTests`.
///
/// **The child is always killed**, on the success path as much as the timeout
/// path. Verified on 2026-08-19: the server exits within 10 ms of `SIGTERM`
/// whether idle or with a request in flight, while closing stdin alone takes up
/// to 2.7 s because it finishes answering first. Waiting politely for that would
/// leave a child alive across a quit, so the signal is not a fallback — it is the
/// shutdown, and closing stdin is only the courtesy before it.
///
/// The signal is sent from **two** places, because `end()` can arrive before the
/// spawn it is meant to undo. `end()` sends it to a running child; `start()`
/// sends it to one that came up after an `end()` had already been and gone. A
/// transport that has been ended, or that already holds a child, refuses to
/// start at all — a second child would make the first unreachable, which is the
/// same leak from the other direction.
///
/// **stderr is drained and kept.** A pipe nobody reads fills at 64 KB and blocks
/// the writer, which for this child would be a hang rather than a diagnostic;
/// and the tail is worth keeping, because the first thing a broken `config.toml`
/// produces is a line there and nothing at all on stdout.
public final class CodexProcessTransport: AppServerTransport {
    static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "quota")

    /// How much of stderr is remembered for a diagnostic. Enough for a few lines
    /// of the child's own log output, bounded so a chatty one cannot grow the
    /// heap.
    static let diagnosticLimit = 4096

    /// How long a child gets to honour `SIGTERM` before it is killed outright.
    ///
    /// `terminate()` is a request, and a request is not a guarantee. The
    /// measured Codex exits inside 10 ms, so this number is never reached in
    /// practice — it exists for the build that blocks the signal, or wedges
    /// while handling it. Without it "the child is always killed" is a claim
    /// about the child's cooperation rather than about this transport, and a
    /// menu-bar app that leaves a Rust runtime behind on every reading is the
    /// process leak this project cannot ship.
    ///
    /// > **It cannot fire on the quit path, and that is a deliberate trade.** The
    /// > escalation is a task in this process, so an `end()` reached from
    /// > `applicationWillTerminate` is followed by the process exiting long
    /// > before the grace elapses — and waiting for it would mean a Quit that
    /// > sits for two seconds, which for an `LSUIElement` app whose only Quit
    /// > lives in a panel footer is the worse failure. That path is covered by
    /// > the mechanism ADR-0009 already relies on: the stdin pipe's write end
    /// > closes when this process goes and the child exits on the EOF within
    /// > 2.74 s. The escalation covers every path where AgentBar is still alive.
    static let terminationGrace: Duration = .seconds(2)

    /// How much unterminated stdout is buffered before the stream is treated as
    /// broken rather than as slow.
    ///
    /// The App Server's replies are newline-delimited and small — the largest
    /// AgentBar asks for is a rate-limit reading. A child writing megabytes with
    /// no newline in them is not sending a reply this transport is going to be
    /// able to parse, and buffering it to the end of a twenty-second budget
    /// would trade a parse failure for heap growth. One megabyte is far above
    /// anything real and far below anything that matters.
    static let pendingLimit = 1024 * 1024

    private let executable: URL
    /// Every mutable thing this transport owns, behind one lock. The readability
    /// handlers run on Foundation's own queue while `end()` may be called from
    /// anywhere, so there is no single actor to put this on.
    let state: OSAllocatedUnfairLock<State>

    /// What one read produced: the whole lines in it, where to send them, and
    /// how much unterminated output had to be discarded on the way — see
    /// `pendingLimit`.
    struct Drained {
        var lines: [Data] = []
        var continuation: AsyncStream<Data>.Continuation?
        var overflowed: Int?
    }

    struct State {
        var process: Process?
        var input: FileHandle?
        var output: FileHandle?
        var errors: FileHandle?
        var continuation: AsyncStream<Data>.Continuation?
        /// Bytes read from stdout that do not yet end in a newline.
        var pending = Data()
        var diagnostics = Data()
        var ended = false
        /// Whether stdin is still worth writing to.
        ///
        /// Cleared when the child's output ends, which is the moment it has
        /// almost certainly gone. Writing into a pipe with no reader raises
        /// `SIGPIPE`, and a signal is not something a `catch` can answer — see
        /// `send`.
        var writable = true
        /// The pending `SIGKILL`, cancelled the moment the child exits.
        var escalation: Task<Void, Never>?
        /// How many times `Process.run()` was actually reached.
        ///
        /// For the suite. The two guards in `start()` fail in the same visible
        /// way — a thrown `.disconnected` — but they differ in whether a child
        /// was ever created, and "spawns nothing at all" is the stronger of the
        /// two claims.
        var spawns = 0
    }

    /// The grace this transport gives, injectable so the suite can prove the
    /// escalation without sitting out the production number.
    private let terminationGrace: Duration

    public convenience init(executable: URL) {
        self.init(executable: executable, terminationGrace: Self.terminationGrace)
    }

    /// Internal, and the suite is the only caller: proving the escalation
    /// against the production grace would mean a test that sits still for two
    /// seconds, and the number is not what is under test.
    init(executable: URL, terminationGrace: Duration) {
        self.executable = executable
        self.terminationGrace = terminationGrace
        state = OSAllocatedUnfairLock(initialState: State())
    }

    public func start() throws -> AsyncStream<Data> {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        // The environment is inherited rather than cleared: Codex finds
        // ~/.codex through HOME, and a scrubbed environment would send it
        // somewhere the user has never configured. This is the same process the
        // user would get by typing the command.
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        // The transport is claimed *before* the spawn. `end()` is allowed to
        // arrive at any moment from any thread, and a transport that had already
        // been ended would otherwise start a child that nothing is left to kill:
        // the second `end()` returns early, having seen the flag its first call
        // set.
        let claimed = state.withLock { state -> Bool in
            // Not merely "has not ended": a transport that already holds a child
            // must refuse too, or the second `start()` would overwrite the first
            // child's handles and leave it running with nothing able to reach it.
            guard !state.ended, state.process == nil else { return false }
            state.process = process
            state.input = input.fileHandleForWriting
            state.output = output.fileHandleForReading
            state.errors = errors.fileHandleForReading
            state.continuation = continuation
            return true
        }
        guard claimed else {
            continuation.finish()
            throw AppServerError.disconnected
        }

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.absorb(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.absorbDiagnostics(handle.availableData)
        }
        // A child that dies on its own must finish the stream, or a caller
        // waiting for a reply that will never come waits out its whole deadline
        // instead of the milliseconds the exit took.
        process.terminationHandler = { [weak self] _ in
            // The child has gone, so there is nothing left to escalate against
            // and a pending kill would be aimed at a process identifier the
            // kernel is free to hand to somebody else.
            self?.cancelEscalation()
            self?.closeStream()
        }

        do {
            state.withLock { $0.spawns += 1 }
            willSpawn?()
            try process.run()
        } catch {
            end()
            throw AppServerError.cannotStart(error.localizedDescription)
        }

        // `end()` may have run while the spawn was in flight. It would have
        // found a `Process` that was not yet running, sent no signal, and marked
        // the transport ended — so this is the last place that can notice, and
        // nothing else will.
        guard !state.withLock({ $0.ended }) else {
            // `end()` ran while the spawn was in flight. It found a `Process`
            // that was not yet running, sent no signal, and marked the transport
            // ended — so this is the last place that can notice, and nothing
            // else will.
            if process.isRunning {
                process.terminate()
                escalate(process)
            }
            continuation.finish()
            throw AppServerError.disconnected
        }
        return stream
    }

    /// Writes one line to the child.
    ///
    /// **Refuses once the child's output has ended.** The parent's copy of the
    /// stdin pipe's read end is closed by `Process` at spawn — that is what lets
    /// closing the write end give the child EOF — so a write after the child
    /// exits goes into a pipe with no reader, and that raises `SIGPIPE` rather
    /// than returning an error. A signal is not something a `catch` can answer,
    /// and a crash here would break the rule that AgentBar's absence is
    /// indistinguishable from its never having existed.
    ///
    /// The window is real rather than theoretical: a child that fails on a bad
    /// `config.toml` writes to stderr and exits, and the very next thing the
    /// exchange does is send `initialize`.
    public func send(_ line: Data) throws {
        let handle = state.withLock { $0.ended || !$0.writable ? nil : $0.input }
        guard let handle else { throw AppServerError.disconnected }
        var payload = line
        payload.append(0x0A)
        do {
            try handle.write(contentsOf: payload)
        } catch {
            throw AppServerError.disconnected
        }
    }

    /// Ends the conversation and the child with it. Idempotent, and never blocks.
    ///
    /// Nothing waits for the exit. `Process` observes its child itself in order
    /// to fire `terminationHandler`, so there is no zombie to reap by hand and
    /// nothing here has to sit on a thread until a signal lands.
    public func end() {
        let (process, input, output, errors, continuation, wasEnded) = state.withLock {
            let previously = $0.ended
            $0.ended = true
            let values = ($0.process, $0.input, $0.output, $0.errors, $0.continuation, previously)
            $0.input = nil
            $0.output = nil
            $0.errors = nil
            $0.continuation = nil
            return values
        }
        guard !wasEnded else { return }

        // Cleared before the signal: a handler firing against a half-torn-down
        // transport is the shape of a crash on quit.
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        // Closing stdin first lets an idle server exit on its own terms; the
        // signal below does not wait to find out whether it did.
        try? input?.close()
        continuation?.finish()

        if let process, process.isRunning {
            process.terminate()
            escalate(process)
        }
    }

    /// Arms the `SIGKILL` that follows a `SIGTERM` nobody answered.
    ///
    /// Never blocks and never waits: `end()` runs on the quit path, and a quit
    /// that sits on a thread for two seconds is a quit the user notices. The
    /// child's own `terminationHandler` cancels this the instant it exits, so
    /// the ordinary path arms a task that is cancelled milliseconds later and
    /// signals nothing.
    private func escalate(_ process: Process) {
        let child = ChildProcess(process)
        let task = Task.detached { [grace = terminationGrace] in
            do {
                try await Task.sleep(for: grace)
            } catch {
                return  // Cancelled: the child exited on the signal it was sent.
            }
            child.killIfStillRunning()
        }
        // Replacing rather than adding: `end()` is idempotent and returns early
        // on its second call, so there is never more than one of these.
        let previous = state.withLock { current -> Task<Void, Never>? in
            let previous = current.escalation
            current.escalation = task
            return previous
        }
        previous?.cancel()
    }

    private func cancelEscalation() {
        let pending = state.withLock { current -> Task<Void, Never>? in
            let pending = current.escalation
            current.escalation = nil
            return pending
        }
        pending?.cancel()
    }

    /// Whether the child is still alive.
    ///
    /// Internal, and for the suite: "the process is gone" is the claim this
    /// transport actually makes, and asserting it from the outside is the only
    /// way to prove it. Nothing in the app reads it — a caller that needed to
    /// know would be a caller deciding whether to kill again.
    var isChildRunning: Bool {
        state.withLock { $0.process?.isRunning ?? false }
    }

    /// How many child processes this transport has tried to create. Zero or one,
    /// and the suite is the only caller.
    var spawnCount: Int { state.withLock { $0.spawns } }

    /// Run immediately before `Process.run()`, if set.
    ///
    /// A seam for one test and nothing else. The guard after `run()` exists for
    /// an `end()` that arrives *during* the spawn, and that interleaving cannot
    /// be produced from outside — so the suite is given the one moment it needs
    /// rather than the guard going untested.
    nonisolated(unsafe) var willSpawn: (@Sendable () -> Void)?
}
