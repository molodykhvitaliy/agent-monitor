import Foundation
import Testing

/// Reads the checked-out sources. Anchored on `#filePath` so it resolves the
/// real working tree rather than a build sandbox.
enum SourceTree {
    static let repositoryRoot = URL(filePath: #filePath)
        .deletingLastPathComponent()  // ArchitectureTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root

    static let sourcesDirectory = repositoryRoot.appending(
        path: "Sources", directoryHint: .isDirectory)

    /// The two bundles in `Apps/`, scanned as if they were modules.
    ///
    /// > **They are not modules and the guards apply to them anyway.** `Apps/`
    /// > holds the assembly point and the Codex helper's entry point — about
    /// > sixteen hundred lines including all the provider trust logic — and
    /// > until this existed every boundary test scanned `Sources/` only. Nothing
    /// > there violated any of them, which is not the same as nothing being able
    /// > to: a `URLSession` or a `Process()` in `AgentBarMain.swift` would have
    /// > passed `make check` completely, and the assembly point is exactly where
    /// > a future edit reaches for both.
    /// >
    /// > They are kept out of `moduleNames()` because the dependency table
    /// > mirrors `Package.swift` and these two have no entry there. The checks
    /// > that are about *capability* rather than about the module graph run over
    /// > `scannableTrees()`, which is both.
    static let appTargets = ["AgentBar", "agentbar-helper"]

    static let appsDirectory = repositoryRoot.appending(
        path: "Apps", directoryHint: .isDirectory)

    /// A directory the scanners walk, and the name it is reported under.
    struct Tree: Hashable {
        let name: String
        let url: URL
    }

    static func moduleNames() throws -> Set<String> {
        let entries = try FileManager.default.contentsOfDirectory(
            at: sourcesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return Set(
            try entries
                .filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
                .map(\.lastPathComponent)
        )
    }

    /// Every first-party Swift tree: the modules, then the two app targets.
    static func scannableTrees() throws -> [Tree] {
        let modules = try moduleNames().sorted().map {
            Tree(name: $0, url: sourcesDirectory.appending(path: $0, directoryHint: .isDirectory))
        }
        let apps = appTargets.map {
            Tree(name: $0, url: appsDirectory.appending(path: $0, directoryHint: .isDirectory))
        }
        return modules + apps
    }

    static func imports(inModule module: String) throws -> Set<String> {
        try imports(
            in: sourcesDirectory.appending(path: module, directoryHint: .isDirectory),
            named: module)
    }

    static func imports(in tree: Tree) throws -> Set<String> {
        try imports(in: tree.url, named: tree.name)
    }

    private static func imports(in root: URL, named module: String) throws -> Set<String> {
        var found: Set<String> = []
        var sawSwiftFile = false

        guard let walker = FileManager.default.enumerator(atPath: root.path(percentEncoded: false))
        else {
            Issue.record("cannot enumerate \(root.path(percentEncoded: false))")
            return []
        }
        for case let relativePath as String in walker where relativePath.hasSuffix(".swift") {
            sawSwiftFile = true
            let contents = try String(
                contentsOf: root.appending(path: relativePath), encoding: .utf8)
            found.formUnion(importedModules(in: contents))
        }

        // Without this the suite would pass cheerfully against an empty or
        // mistyped directory — the precise false negative it exists to prevent.
        #expect(sawSwiftFile, "no Swift sources found in \(module)")
        return found
    }

    /// Reports every mention of a forbidden symbol, as `file:line: symbol`.
    ///
    /// Text matching, like the import scan: a symbol inside a string literal is
    /// reported too, which is the direction this check is allowed to fail in.
    static func occurrences(of symbols: [String], inModule module: String) throws -> [String] {
        try occurrences(
            of: symbols,
            in: sourcesDirectory.appending(path: module, directoryHint: .isDirectory),
            named: module)
    }

    static func occurrences(of symbols: [String], in tree: Tree) throws -> [String] {
        try occurrences(of: symbols, in: tree.url, named: tree.name)
    }

    private static func occurrences(
        of symbols: [String], in root: URL, named module: String
    ) throws -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root.path(percentEncoded: false))
        else {
            Issue.record("cannot enumerate \(root.path(percentEncoded: false))")
            return []
        }
        var found: [String] = []
        var sawSwiftFile = false
        for case let relativePath as String in walker where relativePath.hasSuffix(".swift") {
            sawSwiftFile = true
            let contents = try String(
                contentsOf: root.appending(path: relativePath), encoding: .utf8)
            let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
            for (offset, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                found += symbols.filter(line.contains).map {
                    "\(relativePath):\(offset + 1): \($0)"
                }
            }
        }
        // A renamed directory yields an enumerator over nothing, and a guard
        // that reports clean because it could not look is worse than no guard.
        #expect(sawSwiftFile, "no Swift sources found in \(module)")
        return found
    }

    /// Matches `import` as a whitespace-delimited token anywhere on the line
    /// rather than only at its start. Attributes that carry arguments —
    /// `@available(macOS 26, *) import AppKit` — and SE-0409 access-level
    /// modifiers — `internal import AppKit` — would otherwise hide an import
    /// from a prefix check, which is a silent under-report in the guard that
    /// protects the domain's purity.
    ///
    /// The cost is that an `import` inside a string literal is reported too.
    /// Over-reporting is the direction this check is allowed to fail in.
    /// Computed rather than stored: `Regex` is not `Sendable`, so a static
    /// constant is a data race under Swift 6 strict concurrency.
    static var importStatement: Regex<(Substring, Substring)> {
        // The optional lowercase word is a declaration kind, as in
        // `import struct Foundation.Data`. Backtracking handles a module whose
        // own name is lowercase, such as `import os`.
        /(?:^|\s)import\s+(?:[a-z]+\s+)?([A-Za-z_][A-Za-z0-9_]*)/
    }

    /// A conditional import still links the framework, so `canImport` counts.
    static var conditionalImport: Regex<(Substring, Substring)> {
        /canImport\(\s*([A-Za-z_][A-Za-z0-9_]*)/
    }

    /// Extracts module names from `import` statements and `canImport` checks.
    static func importedModules(in source: String) -> Set<String> {
        var result: Set<String> = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") { continue }
            for match in line.matches(of: importStatement) {
                result.insert(String(match.1))
            }
            for match in line.matches(of: conditionalImport) {
                result.insert(String(match.1))
            }
        }
        return result
    }
}
