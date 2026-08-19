import Foundation
import Testing

// Guards the two boundaries the compiler cannot express.
//
// A system framework needs no package dependency, so `import AppKit` inside
// AgentBarCore compiles happily and silently breaks the invariant every later
// step relies on. Likewise, Package.swift declares which modules *may* be
// imported, but nothing stops a source file importing a module the manifest
// never listed once the app target links them all together.
//
// The scanner is deliberately literal: it reads the source text rather than the
// build graph. It can over-report (an `import` at the start of a line inside a
// block comment), never meaningfully under-report, and a false alarm is a loud
// failure that takes seconds to explain.

/// The boundary checks are only as good as the parser underneath them, and the
/// interesting inputs — `@_spi(A, B) import X`, an import inside a comment —
/// either cannot be written as a compiling fixture or would fail the suite for
/// the wrong reason. So the parser is exercised directly.
@Suite("Import scanner")
struct ImportScannerTests {

    @Test(
        "Recognises every form an import can take",
        arguments: [
            ("import AppKit", "AppKit"),
            ("internal import AppKit", "AppKit"),
            ("public import SwiftUI", "SwiftUI"),
            ("package import IOKit", "IOKit"),
            ("fileprivate import Combine", "Combine"),
            ("@preconcurrency import UserNotifications", "UserNotifications"),
            ("@_exported import Network", "Network"),
            ("@_spi(Private, Other) import ServiceManagement", "ServiceManagement"),
            ("@testable import AgentBarCore", "AgentBarCore"),
            ("\timport\tIOKit", "IOKit"),
            ("  import   AppKit  ", "AppKit"),
            ("import struct Foundation.Data", "Foundation"),
            ("import class AppKit.NSImage", "AppKit"),
            ("import Foundation.NSString", "Foundation"),
            ("import os", "os"),
            ("import os.log", "os"),
            ("import struct os.Logger", "os"),
            ("#if canImport(AppKit)", "AppKit"),
            ("#if !canImport( IOKit )", "IOKit"),
        ]
    )
    func recognisesImport(source: String, expected: String) {
        #expect(SourceTree.importedModules(in: source).contains(expected))
    }

    @Test(
        "Ignores text that is not an import",
        arguments: [
            "// import AppKit is forbidden in this module",
            "/// See also: import AppKit",
            "let importantValue = 1",
            "func reimportEverything() {}",
        ]
    )
    func ignoresNonImport(source: String) {
        #expect(SourceTree.importedModules(in: source).isEmpty)
    }
}

@Suite("Module boundaries")
struct ModuleBoundaryTests {

    /// The intra-package edges each module is allowed to have, mirroring
    /// `Package.swift`. Dependencies point inward: everything may reach
    /// AgentBarCore, AgentBarCore may reach nothing, and no adapter may reach
    /// another adapter.
    static let allowedInternalDependencies: [String: Set<String>] = [
        "AgentBarCore": [],
        "AgentBarIngest": ["AgentBarCore"],
        // The one edge that points at the transport rather than straight at the
        // core: `EventDecoding` is the seam AgentBarIngest publishes for
        // adapters, and conforming to it where the payload knowledge lives is
        // what keeps provider JSON inside the adapter.
        "ClaudeCodeAdapter": ["AgentBarCore", "AgentBarIngest"],
        "CodexAdapter": ["AgentBarCore"],
        "CodexAppServer": ["AgentBarCore"],
        "AgentBarNotifications": ["AgentBarCore"],
        "AgentBarPower": ["AgentBarCore"],
        "AgentBarUI": ["AgentBarCore"],
    ]

    /// Everything AgentBarCore is allowed to import. An allowlist rather than a
    /// list of banned frameworks: a denylist admits every framework nobody
    /// thought of, which is precisely how a domain quietly grows a dependency on
    /// AppKit, Dispatch or CryptoKit. Widening this set is a decision, and this
    /// test is where it gets made.
    static let frameworksAllowedInCore: Set<String> = ["Foundation"]

    /// Frameworks only one module may reach for.
    ///
    /// `Network` is how a socket gets opened, and ADR-0002's guarantee is that
    /// AgentBar talks to loopback and to nothing else. Keeping the framework
    /// inside one module means a socket appearing anywhere else is a failing
    /// test rather than a diff nobody looked at twice. `IOKit` is the same
    /// argument about power: one module takes the assertion, so one module can
    /// be held to releasing it.
    static let frameworksRestrictedToModules: [String: Set<String>] = [
        "Network": ["AgentBarIngest"],
        // A power assertion is process-owned and released when the process
        // dies, which is the whole reason AgentBar takes one instead of
        // spawning `caffeinate`. One owner means one release path: an
        // assertion created anywhere else is one `CaffeineController` cannot
        // let go of, and the symptom is a Mac that never sleeps again.
        "IOKit": ["AgentBarPower"],
    ]

    /// Ways to originate an HTTP request to an arbitrary host.
    ///
    /// ADR-0002 §5.2 says there is no remote HTTP client in the dependency
    /// graph, and until now that was upheld by review alone. The ingest endpoint
    /// is a *server*: it answers connections and opens none, so nothing under
    /// `Sources` has any business constructing one of these.
    static let remoteClientSymbols = [
        "URLSession", "URLRequest", "NSURLConnection", "NWBrowser",
    ]

    @Test("Every module directory has a declared dependency policy")
    func moduleInventoryIsComplete() throws {
        let discovered = try SourceTree.moduleNames()
        #expect(
            !discovered.isEmpty,
            "no modules found under Sources — the scanner is looking in the wrong place")
        #expect(
            discovered == Set(Self.allowedInternalDependencies.keys),
            """
            Sources/ and the allowed-dependency table disagree. A new module is an \
            architectural decision: add it to Package.swift, to this table, and to \
            docs/dev/architecture.md.
            """
        )
    }

    @Test("AgentBarCore imports nothing outside its allowlist")
    func coreStaysPure() throws {
        let imports = try SourceTree.imports(inModule: "AgentBarCore")
        let violations = imports.subtracting(Self.frameworksAllowedInCore)
        #expect(
            violations.isEmpty,
            """
            AgentBarCore may import only \(Self.frameworksAllowedInCore.sorted()); \
            found \(violations.sorted()). It must stay free of platform frameworks, \
            filesystem access and sockets — see docs/dev/architecture.md.
            """
        )
    }

    /// Symbols that would let AgentBarCore reach outside itself.
    ///
    /// The import allowlist stops a new framework arriving, but `Foundation`
    /// alone is enough to read a file, spawn a process, open a socket or start
    /// a timer — and the domain is only testable, and only honest about time,
    /// for as long as it does none of those. The store deliberately owns no
    /// timer either: whoever holds the run loop calls `sweep()`.
    static let ioSymbolsForbiddenInCore = [
        "FileManager", "FileHandle", "Pipe", "Process",
        "URLSession", "NSXPCConnection",
        "DispatchQueue", "Thread", "Timer", "RunLoop",
        "NotificationCenter", "UserDefaults", "Bundle",
        "resolvingSymlinksInPath", "checkResourceIsReachable",
    ]

    @Test("AgentBarCore reaches nothing outside itself")
    func coreDoesNoInputOutput() throws {
        let hits = try SourceTree.occurrences(
            of: Self.ioSymbolsForbiddenInCore, inModule: "AgentBarCore")
        #expect(
            hits.isEmpty,
            """
            AgentBarCore must stay pure logic; found \(hits.sorted()). Injecting the \
            capability through a protocol — the way `TimeSource` supplies the clock — \
            keeps the domain testable and the boundary in docs/dev/architecture.md real.
            """
        )
    }

    @Test("A restricted framework appears only where it is allowed")
    func restrictedFrameworksStayPut() throws {
        let moduleNames = try SourceTree.moduleNames()
        for (framework, allowed) in Self.frameworksRestrictedToModules {
            for module in moduleNames.sorted() where !allowed.contains(module) {
                let imports = try SourceTree.imports(inModule: module)
                #expect(
                    !imports.contains(framework),
                    """
                    \(module) imports \(framework), which only \(allowed.sorted()) may. \
                    Opening a socket outside AgentBarIngest is how the loopback-only \
                    guarantee in ADR-0002 stops being true — see docs/dev/tos-boundary.md.
                    """
                )
            }
        }
    }

    @Test("Nothing under Sources can originate a request to a remote host")
    func noRemoteClientExists() throws {
        let moduleNames = try SourceTree.moduleNames()
        #expect(!moduleNames.isEmpty, "no modules found — the scanner looked in the wrong place")
        for module in moduleNames.sorted() {
            let hits = try SourceTree.occurrences(of: Self.remoteClientSymbols, inModule: module)
            #expect(
                hits.isEmpty,
                """
                \(module) references \(hits.sorted()). AgentBar answers connections and \
                originates none; a remote HTTP client in the graph is the failure \
                docs/dev/tos-boundary.md §5.2 exists to prevent.
                """
            )
        }
    }

    @Test("Module dependencies point inward")
    func dependenciesPointInward() throws {
        let moduleNames = try SourceTree.moduleNames()
        for module in moduleNames.sorted() {
            let allowed = Self.allowedInternalDependencies[module] ?? []
            let actual = try SourceTree.imports(inModule: module).intersection(moduleNames)
            let violations = actual.subtracting(allowed).subtracting([module])
            #expect(
                violations.isEmpty,
                "\(module) may only import \(allowed.sorted()); found \(violations.sorted())"
            )
        }
    }
}

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
