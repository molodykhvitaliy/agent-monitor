import AgentBarCore
import Foundation

/// Receives the state moves an applied event caused.
///
/// The endpoint's push leg. Without it a state change is visible only to
/// whoever next takes a snapshot, so the one signal AgentBar exists for — an
/// agent that has stopped and needs a person — would wait for a poll. The
/// handler already has the `[ApplyOutcome]` in its hand; this is what stops it
/// throwing them away.
///
/// Deliberately not a callback the store owns. `SessionStore` is the domain and
/// must not know that anything is listening; the observation belongs to the
/// boundary that applied the event.
public protocol StateChangeSink: Sendable {
    /// Called with the moves one request produced, in the order they happened,
    /// and never with an empty array.
    ///
    /// Called from the connection's own task. Implementations must not block:
    /// a sink that waits is a hook handler that waits, and nothing AgentBar
    /// installs may delay an agent.
    func record(_ changes: [StateChange])
}

/// Drops everything. The default, so an endpoint stood up in a test or by a
/// caller with no interest in liveness needs no observer.
public struct UnobservedStateChanges: StateChangeSink {
    public init() {}
    public func record(_ changes: [StateChange]) {}
}
