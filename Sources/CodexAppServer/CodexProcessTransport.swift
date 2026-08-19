import Foundation
import os

/// `codex app-server` as a child process on stdio.
///
/// The only subprocess AgentBar ever spawns, and the reason `Process` is
/// restricted to this module by `ModuleBoundaryTests`.
///
/// **The child is always killed.** `end()` closes stdin and then sends `SIGTERM`
/// unconditionally — on the success path as much as the timeout path. Verified
/// on 2026-08-19: the server exits within 10 ms of `SIGTERM` whether idle or
/// with a request in flight, while closing stdin alone takes up to 2.7 s because
/// it finishes answering first. Waiting politely for that would leave a child
/// alive across a quit, so the signal is not a fallback — it is the shutdown.
///
/// **stderr is drained and kept.** A pipe nobody reads fills at 64 KB and blocks
/// the writer, which for this child would be a hang rather than a diagnostic;
/// and the tail is worth keeping, because the first thing a broken `config.toml`
/// produces is a line there and nothing at all on stdout.
public final class CodexProcessTransport: AppServerTransport {
    /// How much of stderr is remembered for a diagnostic. Enough for a few lines
    /// of the child's own log output, bounded so a chatty one cannot grow the
    /// heap.
    static let diagnosticLimit = 4096

    private let executable: URL
    /// Every mutable thing this transport owns, behind one lock. The readability
    /// handlers run on Foundation's own queue while `end()` may be called from
    /// anywhere, so there is no single actor to put this on.
    private let state: OSAllocatedUnfairLock<State>

    /// What one read produced: the whole lines in it, and where to send them.
    private typealias Drained = ([Data], AsyncStream<Data>.Continuation?)

    private struct State {
        var process: Process?
        var input: FileHandle?
        var output: FileHandle?
        var errors: FileHandle?
        var continuation: AsyncStream<Data>.Continuation?
        /// Bytes read from stdout that do not yet end in a newline.
        var pending = Data()
        var diagnostics = Data()
        var ended = false
    }

    public init(executable: URL) {
        self.executable = executable
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
        state.withLock {
            $0.process = process
            $0.input = input.fileHandleForWriting
            $0.output = output.fileHandleForReading
            $0.errors = errors.fileHandleForReading
            $0.continuation = continuation
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
        process.terminationHandler = { [weak self] _ in self?.closeStream() }

        do {
            try process.run()
        } catch {
            end()
            throw AppServerError.cannotStart(error.localizedDescription)
        }
        return stream
    }

    public func send(_ line: Data) throws {
        let handle = state.withLock { $0.ended ? nil : $0.input }
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

        if let process, process.isRunning { process.terminate() }
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

    // MARK: - Reading

    /// Splits stdout into lines, holding a partial line until its newline
    /// arrives.
    ///
    /// A JSON object is never split across reads in practice, but "in practice"
    /// is not a framing rule, and the failure it would cause — one dropped
    /// reply, once, under load — is exactly the kind nobody reproduces.
    private func absorb(_ data: Data) {
        guard !data.isEmpty else {
            // Zero bytes from a readability handler is end of file.
            closeStream()
            return
        }
        let (complete, continuation) = state.withLock { state -> Drained in
            guard !state.ended else { return ([], nil) }
            state.pending.append(data)
            var lines: [Data] = []
            while let newline = state.pending.firstIndex(of: 0x0A) {
                let line = state.pending[state.pending.startIndex..<newline]
                state.pending = state.pending[state.pending.index(after: newline)...]
                if !line.isEmpty { lines.append(Data(line)) }
            }
            return (lines, state.continuation)
        }
        guard let continuation else { return }
        // Yielded outside the lock: a consumer resumed by `yield` must never
        // run while this thread still holds it.
        for line in complete { continuation.yield(line) }
    }

    private func absorbDiagnostics(_ data: Data) {
        guard !data.isEmpty else { return }
        state.withLock {
            $0.diagnostics.append(data)
            if $0.diagnostics.count > Self.diagnosticLimit {
                $0.diagnostics.removeFirst($0.diagnostics.count - Self.diagnosticLimit)
            }
        }
    }

    /// Ends the stream without touching the process — the child has already
    /// gone, or its output has.
    private func closeStream() {
        let continuation = state.withLock {
            let value = $0.continuation
            $0.continuation = nil
            return value
        }
        continuation?.finish()
    }

    /// The tail of what the child wrote to stderr, for a log line.
    ///
    /// Bounded and stripped of control characters, because it reaches the log as
    /// `.public` and every byte of it came from outside this process.
    public func diagnostics() -> String? {
        let data = state.withLock { $0.diagnostics }
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        let scalars = text.unicodeScalars.filter {
            $0 == "\n" || !CharacterSet.controlCharacters.contains($0)
        }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
