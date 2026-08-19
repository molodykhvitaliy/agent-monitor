import AgentBarCore
import Foundation

/// What a project is called on screen, when two of them are called the same
/// thing.
///
/// `ProjectRef.name` is the last path component, so `~/code/app` and
/// `~/worktrees/feature-x/app` both render as `app` — adjacent, identical
/// headers with nothing to tell them apart, which is exactly the case a
/// developer using worktrees hits.
///
/// The disambiguator comes from `root`, never from `worktree`:
/// `worktree.repositoryName` is wrong in precisely the case that triggers the
/// rule, because a linked worktree whose leaf equals the repository's own name
/// gives `app · app`, which distinguishes nothing.
///
/// The result is **one computed value reused everywhere the project is named** —
/// the group header, the row's tooltip and the row's accessibility label.
/// Rendering it only in the header would leave a VoiceOver user with two
/// identical `app`s.
nonisolated public struct ProjectLabels: Sendable, Hashable {
    private let suffixes: [ProjectID: String]

    /// Computes the labels for one snapshot's worth of projects.
    public init(projects: [ProjectRef]) {
        var suffixes: [ProjectID: String] = [:]
        let collisions = Dictionary(grouping: projects) { $0.name.lowercased() }
            .values
            .filter { $0.count > 1 }

        for group in collisions {
            // Walk up one component at a time until every member of the
            // colliding set has a distinct suffix — `~/a/x/app` and `~/b/x/app`
            // both yield `x`, so the rule has to be able to reach `a` and `b`.
            let parents = group.map { Self.components(above: $0.root) }
            let depth = (1...max(1, parents.map(\.count).max() ?? 1)).first { depth in
                Set(parents.map { Self.suffix($0, depth: depth) }).count == group.count
            }
            guard let depth else { continue }
            for (project, parent) in zip(group, parents) {
                let suffix = Self.suffix(parent, depth: depth)
                guard !suffix.isEmpty else { continue }
                suffixes[project.id] = suffix
            }
        }
        self.suffixes = suffixes
    }

    /// The bare name when it is unambiguous, `app · feature-x` when it is not.
    ///
    /// The suffix is muted where it is rendered — Caption in `ink400` — but it
    /// is part of the name everywhere the name is used, including where there
    /// is no styling to mute it with.
    public func label(for project: ProjectRef) -> String {
        guard let suffix = suffixes[project.id] else { return project.name }
        return project.name + DesignTokens.separator + suffix
    }

    /// Whether this project needed disambiguating, so a header can style the
    /// suffix without re-deriving it.
    public func suffix(for project: ProjectRef) -> String? { suffixes[project.id] }

    /// Path components above the project's own leaf, nearest first.
    private static func components(above root: URL) -> [String] {
        let named = root.pathComponents.filter { $0 != "/" }
        return Array(named.dropLast().reversed())
    }

    /// The nearest `depth` components, in path order.
    private static func suffix(_ parents: [String], depth: Int) -> String {
        parents.prefix(depth).reversed().joined(separator: "/")
    }
}
