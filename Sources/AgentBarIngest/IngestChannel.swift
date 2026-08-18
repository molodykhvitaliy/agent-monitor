import Foundation
import Network
import Synchronization

/// Shortened so a continuation's type fits on the line its closure opens, which
/// is what both linters want and what keeps these bridges readable.
typealias VoidContinuation = CheckedContinuation<Void, any Error>
typealias DataContinuation = CheckedContinuation<Data?, any Error>

/// One connection, as async reads and writes.
///
/// Every hazard Network.framework's callback API brings lives here rather than
/// spread through the serve loop: a state handler that fires more than once, a
/// receive whose completion arrives after the connection was cancelled, a send
/// to a peer that has already gone. Each of those is a continuation resumed
/// twice or never, and both are crashes rather than errors.
final class IngestChannel: Sendable {
    private let connection: NWConnection
    private let closed = Mutex(false)

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    /// Starts the connection and waits for it to be usable.
    func start(on queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: VoidContinuation) in
            let box = Mutex<VoidContinuation?>(continuation)
            let resume: @Sendable ((any Error)?) -> Void = { error in
                let pending = box.withLock { current -> VoidContinuation? in
                    defer { current = nil }
                    return current
                }
                guard let pending else { return }
                if let error {
                    pending.resume(throwing: error)
                } else {
                    pending.resume()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: resume(nil)
                case .failed(let error), .waiting(let error): resume(error)
                case .cancelled: resume(CancellationError())
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// The next bytes, or `nil` once the peer has finished sending.
    func receive(maximumLength: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { (continuation: DataContinuation) in
            connection.receive(
                minimumIncompleteLength: 1, maximumLength: maximumLength
            ) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if isComplete, data?.isEmpty ?? true {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: VoidContinuation) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
    }

    /// Cancels the connection. Idempotent, and safe to call from a racing task —
    /// which is how the idle timeout unblocks a `receive` that would otherwise
    /// wait for a peer that has stopped talking.
    func close() {
        let alreadyClosed = closed.withLock { current -> Bool in
            defer { current = true }
            return current
        }
        guard !alreadyClosed else { return }
        connection.cancel()
    }
}
