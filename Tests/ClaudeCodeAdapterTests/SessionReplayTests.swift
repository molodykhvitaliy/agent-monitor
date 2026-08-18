import AgentBarCore
import AgentBarIngest
import Foundation
import Testing

@testable import ClaudeCodeAdapter

/// Whole sessions, replayed through the decoder into a real `SessionStore` in
/// the order Claude Code delivered them.
///
/// The unit tests prove one payload decodes; these prove the sequence adds up to
/// a session a person would recognise, which is the only claim step 04 is
/// actually making.
@Suite("Recorded sessions drive the store")
struct SessionReplayTests {

    /// Replays a recorded session one payload at a time, one second apart, and
    /// hands back the reading after each.
    static func replay(_ fixture: String) async throws -> [(payload: Data, snapshot: StoreSnapshot)]
    {
        let clock = ManualClock()
        let store = SessionStore(clock: clock)
        let decoder = ClaudeCodeEventDecoder()
        var readings: [(Data, StoreSnapshot)] = []
        for payload in try Fixtures.session(fixture) {
            clock.advance(by: 1)
            let context = EventDecodingContext(
                receivedAt: clock.wallTime, transport: .loopback, resolver: PathProjectResolver())
            await store.apply(contentsOf: try decoder.decode(payload, in: context))
            readings.append((payload, await store.snapshot()))
        }
        return readings.map { (payload: $0.0, snapshot: $0.1) }
    }

    static func states(_ readings: [(payload: Data, snapshot: StoreSnapshot)]) -> [String] {
        readings.map { reading in
            let name = (try? JSONParser.parse(reading.payload).object?["hook_event_name"]?.string)
            let state = reading.snapshot.sessions.first.map { "\($0.state.kind.rawValue)" }
            return "\(name ?? "?") → \(state ?? "gone")"
        }
    }

    @Test("A session of ordinary work runs working, working, then idle")
    func replaysToolSession() async throws {
        let readings = try await Self.replay("session-with-tools")
        #expect(
            Self.states(readings) == [
                "UserPromptSubmit → working",
                "PreToolUse → working",
                "PostToolUse → working",
                "PreToolUse → working",
                "PostToolUseFailure → working",
                "PreToolUse → working",
                "PostToolUse → working",
                "PreToolUse → working",
                "PostToolUse → working",
                "Stop → idle",
                "SessionEnd → gone",
            ])
    }

    @Test("A failed tool call does not leave a tool running")
    func closesFailedToolCalls() async throws {
        let readings = try await Self.replay("session-with-tools")
        // The reading taken right after PostToolUseFailure.
        let afterFailure = try #require(readings[4].snapshot.sessions.first)
        #expect(afterFailure.currentTool == nil)
        // And the successful pair before it closed too.
        #expect(try #require(readings[2].snapshot.sessions.first).currentTool == nil)
        // While a call is open, the row names it.
        #expect(try #require(readings[1].snapshot.sessions.first).currentTool?.name == "Bash")
    }

    @Test("A subagent is counted while it runs and only while it runs")
    func countsSubagents() async throws {
        let readings = try await Self.replay("session-with-subagent")
        let counts = readings.map { $0.snapshot.sessions.first?.activeSubagentCount ?? -1 }
        #expect(counts == [0, 0, 1, 1, 1, 0, 0, 0, -1])
    }

    @Test("A subagent that outlives the turn does not resurrect the session")
    func aLateSubagentFarewellDoesNotResurrect() async throws {
        // The Agent tool takes `run_in_background`, and `Stop` carries a
        // `background_tasks` array, so a subagent structurally outlives the turn
        // that spawned it. Its farewell then lands after `Stop` has already
        // moved the session to idle. Real payloads, delivered in an order that
        // really happens.
        let payloads = try Fixtures.session("session-with-subagent")
        func payload(_ name: String) throws -> Data {
            try #require(
                payloads.first {
                    (try? JSONParser.parse($0).object?["hook_event_name"]?.string) == name
                })
        }

        let clock = ManualClock()
        let store = SessionStore(clock: clock)
        let decoder = ClaudeCodeEventDecoder()
        func apply(_ body: Data) async {
            clock.advance(by: 1)
            let context = EventDecodingContext(
                receivedAt: clock.wallTime, transport: .loopback, resolver: PathProjectResolver())
            if let events = try? decoder.decode(body, in: context) {
                await store.apply(contentsOf: events)
            }
        }

        await apply(try payload("UserPromptSubmit"))
        await apply(try payload("SubagentStart"))
        #expect(await store.snapshot().sessions.first?.state.kind == .working)
        await apply(try payload("Stop"))
        #expect(await store.snapshot().sessions.first?.state.kind == .idle)

        await apply(try payload("SubagentStop"))
        // Working again here would be a session only the watchdog could end,
        // holding the power assertion open with it.
        let after = try #require(await store.snapshot().sessions.first)
        #expect(after.state.kind == .idle)
        #expect(after.activeSubagentCount == 0)
    }

    @Test("A turn that died on an API error leaves the session failed")
    func replaysFailedSession() async throws {
        let readings = try await Self.replay("session-that-failed")
        #expect(
            Self.states(readings) == [
                "UserPromptSubmit → working",
                "StopFailure → failed",
                "SessionEnd → gone",
            ])
        let failed = try #require(readings[1].snapshot.sessions.first)
        #expect(failed.state == .failed(reason: "Authentication failed"))
    }

    @Test("The project a session is grouped under comes from its working directory")
    func groupsByProject() async throws {
        let readings = try await Self.replay("session-with-tools")
        let group = try #require(readings[0].snapshot.projects.first)
        #expect(group.project.name == "probe")
        #expect(group.sessions.count == 1)
    }

    @Test("A permission prompt moves a working session to waiting, and back")
    func replaysWaiting() async throws {
        let clock = ManualClock()
        let store = SessionStore(clock: clock)
        let decoder = ClaudeCodeEventDecoder()

        func apply(_ fixture: String) async {
            clock.advance(by: 1)
            let context = EventDecodingContext(
                receivedAt: clock.wallTime, transport: .loopback, resolver: PathProjectResolver())
            guard let payload = try? Fixtures.data(fixture),
                let events = try? decoder.decode(payload, in: context)
            else { return }
            await store.apply(contentsOf: events)
        }

        // The recorded prompt and the recorded notification are from the same
        // session id, so this is one session's life.
        await apply("pre-tool-use-bash")
        #expect(await store.snapshot().sessions.first?.state.kind == .working)
        await apply("notification-permission-prompt")
        #expect(await store.snapshot().sessions.first?.state.kind == .waiting)
        // Whatever the person decides, the next tool result puts the session
        // back to work — no path leaves it stuck waiting.
        await apply("post-tool-use-bash")
        #expect(await store.snapshot().sessions.first?.state.kind == .working)
    }
}
