import Foundation

/// The seam over IOKit: something that can hold at most one power assertion.
///
/// A protocol rather than a direct call so the controller's decisions are
/// testable without taking a real assertion — a suite that kept the developer's
/// Mac awake while it ran would be its own bug — and so the one file that
/// imports IOKit stays one file.
///
/// The holder owns the assertion id rather than handing it out. There is only
/// ever one, its lifetime is the controller's, and an id in a caller's hand is
/// an id that can be leaked past the release.
@MainActor
public protocol PowerAsserting: AnyObject {
    /// Whether the Mac is being kept awake **right now** — not merely whether an
    /// id is owned. An implementation whose assertion carries a lease reports
    /// `false` once that lease has run out, even though the id is still valid
    /// and can be armed again.
    var isHeld: Bool { get }

    /// Takes an assertion with a lease. Throws if the system refused, in which
    /// case nothing is held.
    ///
    /// - Parameters:
    ///   - name: what `pmset -g assertions` calls it.
    ///   - details: the line beneath the name, saying why it is held.
    ///   - lease: how long the assertion survives without being renewed.
    /// - Throws: `PowerAssertionError` when the system refused.
    func take(name: String, details: String, lease: Duration) throws

    /// Re-arms the lease and refreshes the details of the assertion already
    /// held. Throws if the system refused; whether anything is still held is
    /// then reported by `isHeld`.
    func renew(details: String, lease: Duration) throws

    /// Releases the assertion. Throws if the system refused, and drops the
    /// assertion either way: every documented failure means there was nothing
    /// there to release.
    func release() throws
}

/// An IOKit call that did not succeed, carrying the code it returned.
///
/// A named error rather than an ignored return value: a power assertion that
/// was refused and reported as taken is the one failure the user cannot
/// diagnose, because the only symptom is a Mac that went to sleep during a
/// build.
public struct PowerAssertionError: Error, Sendable, Hashable, CustomStringConvertible {
    /// The IOKit function that failed, for the log.
    public let operation: String
    /// The `IOReturn` it returned.
    public let code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    public var description: String {
        "\(operation) failed with IOReturn 0x\(String(UInt32(bitPattern: code), radix: 16))"
    }
}
