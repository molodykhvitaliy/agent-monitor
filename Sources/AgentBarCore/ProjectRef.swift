import Foundation

/// The place a session is working in, and the key sessions are grouped by.
///
/// Two agents running in the same directory are two sessions in one group —
/// grouped, never merged. Two checkouts of the same repository are two groups,
/// because they are two places to work.
public struct ProjectRef: Sendable, Hashable, Identifiable {
    /// Stable grouping key derived from `root`.
    public let id: ProjectID
    /// Folder name, which is what the panel shows. Never the full path.
    public let name: String
    /// Directory the group is keyed to, normalised.
    public let root: URL
    /// Set when `root` is a linked worktree rather than the main checkout.
    public let worktree: WorktreeRef?

    public init(id: ProjectID, name: String, root: URL, worktree: WorktreeRef? = nil) {
        self.id = id
        self.name = name
        self.root = root
        self.worktree = worktree
    }
}

/// The repository a linked worktree belongs to.
///
/// A worktree stays its own project group; this only lets the UI say which
/// repository the group came from. Filling it in requires reading git metadata,
/// which the domain must not do — a resolver injected from outside supplies it.
public struct WorktreeRef: Sendable, Hashable {
    public let repositoryName: String
    public let repositoryRoot: URL

    public init(repositoryName: String, repositoryRoot: URL) {
        self.repositoryName = repositoryName
        self.repositoryRoot = repositoryRoot
    }
}

/// Turns a working directory into the project it belongs to.
///
/// A seam, not a detail: deciding that `~/code/app/src` belongs to `~/code/app`
/// means finding a repository root, which is filesystem work the domain is not
/// allowed to do. The layer that owns I/O injects a resolver that knows better;
/// `PathProjectResolver` is the answer available without touching the disk.
public protocol ProjectResolving: Sendable {
    func project(for cwd: URL) -> ProjectRef
}

/// Derives a project from the path alone.
///
/// Normalises away the differences that would otherwise split one directory
/// into several groups — a trailing slash, an embedded `..`, and the letter
/// case that a case-insensitive volume treats as the same file. What it cannot
/// do is recognise that a subdirectory belongs to its repository root: without
/// reading the disk, `~/code/app` and `~/code/app/src` are simply two paths.
public struct PathProjectResolver: ProjectResolving {
    public init() {}

    public func project(for cwd: URL) -> ProjectRef {
        let root = cwd.standardizedFileURL
        let path = Self.normalisedPath(of: root)
        return ProjectRef(
            id: ProjectID(path.lowercased()),
            name: Self.displayName(for: root, path: path),
            root: root
        )
    }

    /// Absolute path without a trailing separator. `path(percentEncoded:)`
    /// rather than `path` so a directory named `my project` does not become
    /// `my%20project` in the grouping key.
    private static func normalisedPath(of url: URL) -> String {
        let path = url.path(percentEncoded: false)
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    private static func displayName(for url: URL, path: String) -> String {
        let component = url.lastPathComponent
        guard component.isEmpty || component == "/" else { return component }
        return path
    }
}
