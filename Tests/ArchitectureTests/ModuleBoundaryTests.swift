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
        // Ordered, lossless JSON. Knows neither provider and reaches nothing,
        // which is what lets both adapters share it without importing each
        // other — the rule that decided where it lives.
        "AgentBarJSON": [],
        "AgentBarIngest": ["AgentBarCore"],
        // The one edge that points at the transport rather than straight at the
        // core: `EventDecoding` is the seam AgentBarIngest publishes for
        // adapters, and conforming to it where the payload knowledge lives is
        // what keeps provider JSON inside the adapter.
        "ClaudeCodeAdapter": ["AgentBarCore", "AgentBarIngest", "AgentBarJSON"],
        "CodexAdapter": ["AgentBarCore", "AgentBarIngest", "AgentBarJSON"],
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
        // Raw syscalls open sockets too, and a rule that policed only
        // Network.framework would have said nothing about the one module that
        // actually connects outwards. `CodexAdapter` holds the helper's relay;
        // `AgentBarPower` and `AgentBarIngest` need none of it.
        //
        // The helper's entry point drains stdin and the app reads its own
        // `proc_pid_rusage` for the diagnostics surface, so both app targets
        // import it too. Neither is a widening of the socket rule: the outbound
        // syscalls have their own check below, and it runs over `Apps/` as well.
        "Darwin": ["CodexAdapter", "AgentBar", "agentbar-helper"],
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

    /// Ways to open an outbound connection with a syscall rather than a
    /// framework, and the one module allowed to.
    ///
    /// `CodexAdapter` is that module: the Codex helper cannot use
    /// Network.framework (see `frameworksRestrictedToModules`) and dials a
    /// loopback address directly. Everything else in the tree answers
    /// connections and opens none, and this is what keeps that true.
    ///
    /// `socket(` is deliberately **not** on the list: a listener creates one too,
    /// and `AgentBarIngest` legitimately does. What distinguishes dialling out is
    /// the connect and the address it is given — and reaching either needs
    /// `import Darwin`, which the table above already restricts.
    static let outboundSyscalls = ["Darwin.connect(", "sendto(", "inet_pton("]
    static let outboundSyscallsAllowedIn: Set<String> = ["CodexAdapter"]

    /// Ways to spawn a child process, and the one module allowed to.
    ///
    /// `CodexAppServer` runs `codex app-server` on stdio, and that is the only
    /// subprocess AgentBar ever creates. Keeping the construction in one module
    /// is what makes "the child is always killed" a property somebody owns: a
    /// `Process` started anywhere else is one nothing tears down, and the
    /// symptom is a `codex` left running after a quit.
    ///
    /// Matched as `Process()` rather than as `Process`, so `ProcessInfo` — which
    /// reads the environment and spawns nothing — does not trip it.
    static let spawnSymbols = ["Process()", "posix_spawn", "NSTask"]
    static let spawnAllowedIn: Set<String> = ["CodexAppServer"]

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

    @Test("Every scanned tree is a directory with Swift in it")
    func scannedTreesExist() throws {
        let trees = try SourceTree.scannableTrees()
        #expect(!trees.isEmpty, "nothing to scan — the scanner is looking in the wrong place")
        for target in SourceTree.appTargets {
            #expect(
                trees.contains { $0.name == target },
                """
                \(target) is not in the scanned set. The four capability guards below cover \
                Apps/ as well as Sources/, and a renamed app target would silently take \
                1 600 lines back out of them.
                """
            )
        }
        // A tree that cannot be enumerated records its own issue inside
        // `imports`; asking for them here is what makes that fire.
        for tree in trees { _ = try SourceTree.imports(in: tree) }
    }

    @Test("A restricted framework appears only where it is allowed")
    func restrictedFrameworksStayPut() throws {
        let trees = try SourceTree.scannableTrees()
        for (framework, allowed) in Self.frameworksRestrictedToModules {
            for tree in trees where !allowed.contains(tree.name) {
                let imports = try SourceTree.imports(in: tree)
                #expect(
                    !imports.contains(framework),
                    """
                    \(tree.name) imports \(framework), which only \(allowed.sorted()) may. \
                    Opening a socket outside AgentBarIngest is how the loopback-only \
                    guarantee in ADR-0002 stops being true — see docs/dev/tos-boundary.md.
                    """
                )
            }
        }
    }

    @Test("Nothing first-party can originate a request to a remote host")
    func noRemoteClientExists() throws {
        for tree in try SourceTree.scannableTrees() {
            let hits = try SourceTree.occurrences(of: Self.remoteClientSymbols, in: tree)
            #expect(
                hits.isEmpty,
                """
                \(tree.name) references \(hits.sorted()). AgentBar answers connections and \
                originates none; a remote HTTP client in the graph is the failure \
                docs/dev/tos-boundary.md §5.2 exists to prevent.
                """
            )
        }
    }

    @Test("Nothing outside the helper's relay dials out with a syscall")
    func noRawOutboundConnectionExists() throws {
        let trees = try SourceTree.scannableTrees()
        for tree in trees where !Self.outboundSyscallsAllowedIn.contains(tree.name) {
            let hits = try SourceTree.occurrences(of: Self.outboundSyscalls, in: tree)
            #expect(
                hits.isEmpty,
                """
                \(tree.name) references \(hits.sorted()). Opening a socket by hand outside \
                \(Self.outboundSyscallsAllowedIn.sorted()) is how the loopback-only guarantee \
                in ADR-0002 stops being true without anybody noticing.
                """
            )
        }
    }

    @Test("Nothing outside the App Server client spawns a process")
    func noOtherModuleSpawns() throws {
        let trees = try SourceTree.scannableTrees()
        for tree in trees where !Self.spawnAllowedIn.contains(tree.name) {
            let hits = try SourceTree.occurrences(of: Self.spawnSymbols, in: tree)
            #expect(
                hits.isEmpty,
                """
                \(tree.name) references \(hits.sorted()). Only \(Self.spawnAllowedIn.sorted()) \
                may spawn a child, because only one module can be held to killing it — see \
                docs/dev/architecture.md.
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
