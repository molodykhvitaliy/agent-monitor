import Foundation

/// Carries one child across the boundary between `end()` and the task that
/// finishes what it started.
///
/// `Process` is not `Sendable` and this file is not the place to decide that it
/// should be. What actually crosses is two reads Foundation serialises itself
/// and one syscall, so the unchecked conformance is scoped to exactly that: the
/// box exposes nothing but the kill.
final class ChildProcess: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    /// `SIGKILL`, but only while Foundation still says the child is there.
    ///
    /// The liveness check is what keeps this from being a signal aimed at a
    /// stranger: an exited child is reaped by `Process` itself, and a reaped
    /// child's identifier belongs to the kernel again.
    func killIfStillRunning() {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}
