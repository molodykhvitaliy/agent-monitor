import AgentBarCore
import AgentBarIngest
import Foundation
import Testing

@testable import ClaudeCodeAdapter

@Suite("Reporting install status")
struct InstallStatusTests {

    @Test("Nothing installed reads as nothing installed, overlap still reported")
    func reportsNotInstalled() throws {
        let scratch = try ScratchSettings(
            contents: try Fixtures.data("settings-with-foreign-hooks"))
        let report = try scratch.installer().report(for: try .test())
        #expect(report.state == .notInstalled)
        #expect(!report.isInstalled)
        #expect(!report.overlaps.isEmpty)
    }

    @Test("A fresh install reads as installed")
    func reportsInstalled() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        let endpoint = try ClaudeCodeEndpoint.test()
        try scratch.installer().install(endpoint)
        #expect(try scratch.installer().report(for: endpoint).state == .installed)
    }

    @Test("Hooks with no endpoint bound read as unreachable, without probing anything")
    func reportsEndpointUnavailable() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        try scratch.installer().install(try .test())
        #expect(try scratch.installer().report(for: nil).state == .endpointUnavailable)
    }

    @Test("A settings file that cannot be read is a state, not a thrown error")
    func reportsUnreadableSettings() throws {
        let scratch = try ScratchSettings(contents: Data("{ truncated".utf8))
        let report = try scratch.installer().report(for: try .test())
        guard case .settingsUnreadable = report.state else {
            Issue.record("expected .settingsUnreadable, got \(report.state)")
            return
        }
        #expect(!report.isInstalled)
    }

    @Test("A bound endpoint and its token become the URL that gets written")
    func buildsAnEndpointFromABoundListener() throws {
        let token = try #require(IngestToken(String(repeating: "t", count: 32)))
        let endpoint = try #require(
            ClaudeCodeEndpoint(
                bound: BoundEndpoint(port: 47825, socketPath: nil), token: token))
        // A literal address, never a name: a listener on 127.0.0.1 refuses ::1.
        #expect(endpoint.url.absoluteString == "http://127.0.0.1:47825/v1/hooks/claude-code")
        #expect(endpoint.authorizationHeader == "Bearer \(token.value)")
        #expect(ClaudeCodeEndpoint.isAgentBarURL(endpoint.url.absoluteString))
    }

    @Test("A moved port and a replaced token are both reported as repairable")
    func reportsDrift() throws {
        let scratch = try ScratchSettings(
            contents: Data(#"{"allowedHttpHookUrls":["https://example.test/hook"]}"#.utf8))
        try scratch.installer().install(try .test(port: 47821, token: "old"))
        let report = try scratch.installer().report(for: try .test(port: 47825, token: "new"))

        guard case .needsRepair(let drift) = report.state else {
            Issue.record("expected repairable drift, got \(report.state)")
            return
        }
        #expect(drift.contains { if case .endpointChanged = $0 { true } else { false } })
        #expect(drift.contains(.tokenChanged))
        #expect(drift.contains(.urlNotAllowed))
        // One fact each, however many handlers carry it. Found by reading a
        // live report that repeated the same sentence ten times.
        #expect(drift.filter { if case .endpointChanged = $0 { true } else { false } }.count == 1)
        #expect(drift.count == 3)
    }

    @Test("A handler an older version installed is reported as obsolete")
    func reportsObsoleteHandlers() throws {
        let scratch = try ScratchSettings(contents: Data("{}\n".utf8))
        let endpoint = try ClaudeCodeEndpoint.test()
        try scratch.installer().install(endpoint)

        // As if a previous release had also installed on PreCompact.
        var root = try #require(JSONParser.parse(scratch.data).object)
        var hooks = try #require(root["hooks"]?.object)
        hooks["PreCompact"] = try #require(hooks["Stop"])
        root["hooks"] = .object(hooks)
        try JSONWriter.data(.object(root)).write(to: scratch.url)

        guard case .needsRepair(let drift) = try scratch.installer().report(for: endpoint).state
        else {
            Issue.record("expected repairable drift")
            return
        }
        #expect(drift.contains(.obsoleteHandler(event: "PreCompact")))

        // And repairing means removing it: install writes the plan, not a union
        // of every plan there has ever been.
        try scratch.installer().install(endpoint)
        #expect(try scratch.installer().report(for: endpoint).state == .installed)
    }
}
