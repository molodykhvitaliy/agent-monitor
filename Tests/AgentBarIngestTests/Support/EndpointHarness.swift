import Foundation
import Network

@testable import AgentBarCore
@testable import AgentBarIngest

/// A live endpoint with a real store behind it.
struct EndpointHarness {
    let directory: TemporaryDirectory
    let store: SessionStore
    let diagnostics: CollectingDiagnostics
    let service: IngestService
    let bound: BoundEndpoint
    let token: String

    var paths: IngestPaths { directory.paths }

    func client() throws -> TestHTTPClient {
        try TestHTTPClient.loopback(port: bound.port)
    }

    /// Posts one well-formed request and reads the answer.
    func post(
        path: String = IngestRoute.events.path,
        token: String?,
        body: String
    ) async throws -> TestHTTPClient.Response {
        let client = try client()
        try await client.open()
        defer { client.close() }
        try await client.write(
            TestHTTPClient.request(path: path, token: token, body: body, keepAlive: false))
        return try await client.readResponse()
    }

    func tearDown() async {
        await service.stop()
        directory.remove()
    }
}

enum EndpointFactory {
    /// A port well below the ephemeral floor and chosen per harness, so suites
    /// running in parallel do not fight over one number.
    static func candidatePort() -> UInt16 {
        UInt16.random(in: 40000...44000)
    }

    static func make(
        limits: IngestLimits = IngestLimits(),
        deadline: Duration = .seconds(1),
        preferredPort: UInt16? = nil,
        withSocket: Bool = true
    ) async throws -> EndpointHarness {
        let directory = try TemporaryDirectory()
        let paths = directory.paths
        let store = SessionStore()
        let diagnostics = CollectingDiagnostics()
        let configuration = IngestConfiguration(
            preferredPort: preferredPort ?? candidatePort(),
            portAttempts: 32,
            socketPath: withSocket ? paths.socketURL : nil,
            limits: limits,
            responseDeadline: deadline)
        let service = IngestService(
            paths: paths, store: store, configuration: configuration, diagnostics: diagnostics)
        let bound = try await service.start()
        let token = try String(contentsOf: paths.tokenURL, encoding: .utf8)
        return EndpointHarness(
            directory: directory, store: store, diagnostics: diagnostics, service: service,
            bound: bound, token: token)
    }

    /// Runs `body` against a live endpoint and always stops it afterwards.
    ///
    /// A `defer` cannot `await`, and an endpoint left running would hold a port
    /// for the rest of the suite.
    static func withEndpoint(
        limits: IngestLimits = IngestLimits(),
        deadline: Duration = .seconds(1),
        preferredPort: UInt16? = nil,
        withSocket: Bool = true,
        _ body: (EndpointHarness) async throws -> Void
    ) async throws {
        let harness = try await make(
            limits: limits, deadline: deadline, preferredPort: preferredPort,
            withSocket: withSocket)
        do {
            try await body(harness)
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }

    /// The machine's first non-loopback IPv4 address, if it has one.
    static func nonLoopbackAddress() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return nil }
        defer { freeifaddrs(pointer) }
        var current = pointer
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard
                getnameinfo(
                    address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil,
                    0, NI_NUMERICHOST) == 0
            else { continue }
            let text = String(cString: host)
            if text != "127.0.0.1" { return text }
        }
        return nil
    }
}
