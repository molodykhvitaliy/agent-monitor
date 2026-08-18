import Foundation
import Testing

@testable import AgentBarIngest

@Suite("Ingest token")
struct IngestTokenTests {

    @Test("A generated token is long, printable and unguessable")
    func generates() {
        let first = IngestToken.generate()
        let second = IngestToken.generate()
        #expect(first.value.count >= 40)
        #expect(first.value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(first.value != second.value)
    }

    @Test(
        "Refuses a stored value that could not have been a token",
        arguments: ["", "short", String(repeating: "x", count: 513), "has space", "has\ttab"]
    )
    func refusesUnusableValues(value: String) {
        #expect(IngestToken(value) == nil)
    }

    @Test("Matches only the exact value")
    func matchesExactly() throws {
        let token = try #require(IngestToken(String(repeating: "a", count: 32)))
        #expect(token.matches(String(repeating: "a", count: 32)))
        #expect(!token.matches(String(repeating: "a", count: 31)))
        #expect(!token.matches(String(repeating: "a", count: 33)))
        #expect(!token.matches(String(repeating: "a", count: 31) + "b"))
        #expect(!token.matches(""))
    }
}

@Suite("Credential store")
struct CredentialStoreTests {

    @Test("Creates a token readable only by its owner, in a directory to match")
    func createsPrivately() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let nested = directory.url.appending(path: "AgentBar", directoryHint: .isDirectory)
        let paths = IngestPaths(directory: nested)
        let stored = try FileCredentialStore(url: paths.tokenURL).loadOrCreate()

        #expect(stored.origin == .created)
        #expect(directory.mode(of: paths.tokenURL) == 0o600)
        #expect(directory.mode(of: nested) == 0o700)
    }

    @Test("Loads the same token the next time")
    func loadsExisting() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let store = FileCredentialStore(url: directory.paths.tokenURL)
        let created = try store.loadOrCreate()
        let loaded = try store.loadOrCreate()
        #expect(loaded.origin == .loaded)
        #expect(loaded.token == created.token)
    }

    /// A token nobody can use is worse than no token: the endpoint would refuse
    /// every request and look like a networking fault. It is replaced, and the
    /// replacement is announced, because every hook already installed is now
    /// carrying the old secret.
    @Test("Replaces an unusable stored token and says so")
    func replacesUnusable() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let diagnostics = CollectingDiagnostics()
        let url = directory.paths.tokenURL
        try Data("nope".utf8).write(to: url)

        let stored = try FileCredentialStore(url: url, diagnostics: diagnostics).loadOrCreate()
        #expect(stored.origin == .replaced)
        #expect(directory.mode(of: url) == 0o600)
        #expect(
            diagnostics.contains {
                if case .credentialReplaced = $0 { return true }
                return false
            })
    }

    /// Tightened rather than rotated: a loose permission bit is far more likely
    /// to be a restored backup than an attack, and rotating would break an
    /// installed hook over it.
    @Test("Tightens a token anyone could read, and keeps its value")
    func tightensLoosePermissions() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let diagnostics = CollectingDiagnostics()
        let url = directory.paths.tokenURL
        let store = FileCredentialStore(url: url, diagnostics: diagnostics)
        let created = try store.loadOrCreate()
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false))

        let reloaded = try store.loadOrCreate()
        #expect(reloaded.token == created.token)
        #expect(directory.mode(of: url) == 0o600)
        #expect(
            diagnostics.contains {
                if case .credentialPermissionsTightened = $0 { return true }
                return false
            })
    }

    @Test("Trims the newline an editor would leave behind")
    func trimsWhitespace() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.paths.tokenURL
        let value = String(repeating: "t", count: 32)
        try Data("\(value)\n".utf8).write(to: url)
        let stored = try FileCredentialStore(url: url).loadOrCreate()
        #expect(stored.origin == .loaded)
        #expect(stored.token.value == value)
    }
}

@Suite("Endpoint discovery")
struct EndpointDiscoveryTests {

    private func descriptor(port: UInt16 = 47821) -> EndpointDescriptor {
        EndpointDescriptor(
            port: port, socketPath: "/tmp/x.sock", tokenPath: "/tmp/token",
            processIdentifier: 4242, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Publishes, reads back, and retracts")
    func roundTrips() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let file = EndpointDiscoveryFile(url: directory.paths.discoveryURL)

        try file.publish(descriptor())
        let read = try #require(file.read())
        #expect(read.port == 47821)
        #expect(read.processIdentifier == 4242)
        #expect(read.hookURLPrefix == "http://127.0.0.1:47821/v1/hooks")

        try file.retract()
        #expect(file.read() == nil)
        #expect(throws: Never.self) { try file.retract() }
    }

    /// A discovery file is the first thing anybody pastes into a bug report.
    @Test("Names the token's path and never its value")
    func carriesNoSecret() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.paths.discoveryURL
        try EndpointDiscoveryFile(url: url).publish(descriptor())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("tokenPath"))
        #expect(!text.lowercased().contains("\"token\""))
        #expect(directory.mode(of: url) == 0o600)
    }

    @Test("Treats a file from a version it does not know as absent")
    func refusesUnknownVersion() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.paths.discoveryURL
        try Data(#"{"version": 99, "host": "127.0.0.1", "port": 1}"#.utf8).write(to: url)
        #expect(EndpointDiscoveryFile(url: url).read() == nil)
    }

    @Test("Treats an unreadable file as absent rather than failing")
    func degradesOnGarbage() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let url = directory.paths.discoveryURL
        try Data("not json".utf8).write(to: url)
        #expect(EndpointDiscoveryFile(url: url).read() == nil)
    }
}
