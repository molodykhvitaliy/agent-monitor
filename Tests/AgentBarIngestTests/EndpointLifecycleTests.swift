import Foundation
import Network
import Synchronization
import Testing

@testable import AgentBarCore
@testable import AgentBarIngest

/// Binding, moving, publishing and cleaning up — everything about the endpoint's
/// life rather than about the requests it answers.
@Suite("Endpoint lifecycle", .serialized)
struct EndpointLifecycleTests {

    @Test("A port already taken moves the endpoint up the ladder and is reported")
    func climbsThePortLadder() async throws {
        let taken = EndpointFactory.candidatePort()
        let blocker = try await BlockingListener.bind(port: taken)
        defer { blocker.cancel() }

        try await EndpointFactory.withEndpoint(preferredPort: taken) { harness in
            #expect(harness.bound.port != taken)
            #expect(harness.bound.port > taken)
            #expect(
                harness.diagnostics.contains {
                    if case .portUnavailable(taken) = $0 { return true }
                    return false
                })
            #expect(
                harness.diagnostics.contains {
                    if case .portMoved(from: taken, _) = $0 { return true }
                    return false
                })
        }
    }

    @Test("Stopping takes down the socket and the discovery file with it")
    func cleansUpOnStop() async throws {
        let harness = try await EndpointFactory.make()
        let socket = try #require(harness.bound.socketPath)
        let discovery = harness.paths.discoveryURL
        #expect(FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)))
        #expect(EndpointDiscoveryFile(url: discovery).read() != nil)

        await harness.service.stop()
        #expect(!FileManager.default.fileExists(atPath: socket.path(percentEncoded: false)))
        #expect(EndpointDiscoveryFile(url: discovery).read() == nil)
        harness.directory.remove()
    }

    /// Network.framework leaves the socket file behind, and binding over it
    /// fails exactly as if the endpoint were live. Telling the two apart is what
    /// makes a launch after a crash work.
    @Test("A socket file left by a crash is cleared on the next start")
    func clearsStaleSocket() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let paths = directory.paths
        try FileCredentialStore.prepareDirectory(paths.directory)
        FileManager.default.createFile(
            atPath: paths.socketURL.path(percentEncoded: false), contents: Data())

        let diagnostics = CollectingDiagnostics()
        let service = IngestService(
            paths: paths, store: SessionStore(),
            configuration: IngestConfiguration(
                preferredPort: EndpointFactory.candidatePort(), portAttempts: 32,
                socketPath: paths.socketURL),
            diagnostics: diagnostics)
        let bound = try await service.start()
        #expect(bound.socketPath != nil)
        #expect(
            diagnostics.contains {
                if case .staleSocketRemoved = $0 { return true }
                return false
            })
        await service.stop()
    }

    @Test("Discovery names the port that was actually taken")
    func publishesTheRealPort() async throws {
        try await EndpointFactory.withEndpoint { harness in
            let descriptor = try #require(
                EndpointDiscoveryFile(url: harness.paths.discoveryURL).read())
            #expect(descriptor.port == harness.bound.port)
            #expect(descriptor.host == "127.0.0.1")
            #expect(descriptor.hookURLPrefix.hasPrefix("http://127.0.0.1:"))
            #expect(descriptor.tokenPath == harness.paths.tokenURL.path(percentEncoded: false))
        }
    }

    @Test("Starting an endpoint twice is refused rather than silently ignored")
    func refusesDoubleStart() async throws {
        try await EndpointFactory.withEndpoint { harness in
            await #expect(throws: IngestEndpointError.alreadyRunning) {
                try await harness.service.start()
            }
        }
    }
}
