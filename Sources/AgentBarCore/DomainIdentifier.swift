/// Shared shape for the opaque string identifiers the domain carries.
///
/// Every id arrives from a provider as a bare string. Giving each one its own
/// type costs four lines and makes passing a `SessionID` where a `ToolUseID`
/// belongs a compile error rather than a dictionary lookup that silently misses.
public protocol DomainIdentifier: Hashable, Comparable, Sendable, CustomStringConvertible {
    var value: String { get }
    init(_ value: String)
}

extension DomainIdentifier {
    public var description: String { value }

    /// Ordering exists so collections derived from a dictionary can be sorted
    /// into a stable list. It carries no meaning beyond determinism.
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.value < rhs.value }
}

/// A conversation with an agent, as the provider identifies it.
///
/// Not unique over time: Claude Code reuses the id when a session is resumed,
/// which is why `SessionStore` guards against a stale `sessionEnded` reviving
/// a session that has since come back.
public struct SessionID: DomainIdentifier {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// One request-and-response cycle inside a session.
public struct TurnID: DomainIdentifier {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// A single tool invocation, used to pair a start with its finish.
public struct ToolUseID: DomainIdentifier {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// A subagent working on behalf of a session.
public struct AgentID: DomainIdentifier {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// The grouping key for sessions that share a working directory.
public struct ProjectID: DomainIdentifier {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// A pending permission request. Reserved for the Approve/Deny backlog item.
public struct PermissionRequestID: DomainIdentifier {
    public let value: String
    public init(_ value: String) { self.value = value }
}
