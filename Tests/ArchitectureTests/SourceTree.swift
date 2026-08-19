import Foundation
import Testing

/// Reads the checked-out sources. Anchored on `#filePath` so it resolves the
/// real working tree rather than a build sandbox.
enum SourceTree {
    static let sourcesDirectory = URL(filePath: #filePath)
        .deletingLastPathComponent()  // ArchitectureTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repository root
        .appending(path: "Sources", directoryHint: .isDirectory)

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

    static func imports(inModule module: String) throws -> Set<String> {
        let root = sourcesDirectory.appending(path: module, directoryHint: .isDirectory)
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
        let root = sourcesDirectory.appending(path: module, directoryHint: .isDirectory)
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
