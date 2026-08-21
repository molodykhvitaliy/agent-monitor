import Foundation
import os

// Framing the child's output, split from the file that owns the child.
//
// Two jobs that share one lock and nothing else: `CodexProcessTransport` decides
// when a process starts and how it is guaranteed to die, and this decides where
// one JSON-RPC message ends and the next begins. Keeping them apart is also what
// keeps either readable.
extension CodexProcessTransport {
    /// Splits stdout into lines, holding a partial line until its newline
    /// arrives.
    ///
    /// A JSON object is never split across reads in practice, but "in practice"
    /// is not a framing rule, and the failure it would cause — one dropped
    /// reply, once, under load — is exactly the kind nobody reproduces.
    func absorb(_ data: Data) {
        guard !data.isEmpty else {
            // Zero bytes from a readability handler is end of file.
            closeStream()
            return
        }
        let drained = state.withLock { state -> Drained in
            guard !state.ended else { return Drained() }
            state.pending.append(data)
            var lines: [Data] = []
            while let newline = state.pending.firstIndex(of: 0x0A) {
                let line = state.pending[state.pending.startIndex..<newline]
                state.pending = state.pending[state.pending.index(after: newline)...]
                if !line.isEmpty { lines.append(Data(line)) }
            }
            // Whatever is left has no newline in it. Past the limit that is not
            // a partial reply any more, and holding on to it is the one place
            // this transport could grow without bound. Dropping it resynchronises
            // on the next newline: the fragment that follows fails to decode and
            // is ignored as unrelated traffic, which is what a broken frame
            // should cost.
            var overflowed: Int?
            if state.pending.count > CodexProcessTransport.pendingLimit {
                overflowed = state.pending.count
                state.pending.removeAll()
            }
            return Drained(
                lines: lines, continuation: state.continuation, overflowed: overflowed)
        }
        // Said out loud rather than dropped in silence. This is a bound rather
        // than an error path, but a megabyte of a child's output going missing
        // with no trace is exactly the kind of quiet the project's own rule
        // about silent failure is written against.
        if let overflowed = drained.overflowed {
            CodexProcessTransport.logger.notice(
                """
                codex app-server sent \(overflowed, privacy: .public) bytes with no newline \
                in them; the buffer was dropped and framing resumes at the next one
                """)
        }
        guard let continuation = drained.continuation else { return }
        // Yielded outside the lock: a consumer resumed by `yield` must never
        // run while this thread still holds it.
        for line in drained.lines { continuation.yield(line) }
    }

    func absorbDiagnostics(_ data: Data) {
        guard !data.isEmpty else { return }
        state.withLock {
            $0.diagnostics.append(data)
            if $0.diagnostics.count > CodexProcessTransport.diagnosticLimit {
                $0.diagnostics.removeFirst(
                    $0.diagnostics.count - CodexProcessTransport.diagnosticLimit)
            }
        }
    }

    /// Ends the stream without touching the process — the child has already
    /// gone, or its output has.
    ///
    /// Marks stdin unwritable rather than closing it. Closing races a `send`
    /// that has already taken the handle and would turn a `SIGPIPE` into an
    /// `EBADF`; the flag stops the write before it starts, and `end()` still
    /// owns the close.
    func closeStream() {
        let continuation = state.withLock {
            $0.writable = false
            let value = $0.continuation
            $0.continuation = nil
            return value
        }
        continuation?.finish()
    }

    /// Whether a `SIGKILL` is still pending. Internal, for the suite.
    var hasPendingKill: Bool { state.withLock { $0.escalation != nil } }

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
