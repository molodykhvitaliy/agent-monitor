import AgentBarCore
import Foundation
import Testing

@testable import CodexAppServer

/// How often a reading is taken, and by whose asking.
///
/// Split from `QuotaServiceTests` because these are not about the *policy* of a
/// reading — whether it lands, whether a failure clears the last one — but about
/// its **cost**. Every one of them is a request the user's own Codex makes
/// against their own account, so each number here is a decision recorded in
/// [ADR-0011](../../docs/adr/ADR-0011-limits-are-read-when-someone-is-looking.md)
/// rather than a tuning knob.
@Suite("Quota cadence")
struct QuotaCadenceTests {
    typealias Clock = QuotaServiceTests.Clock
    typealias Spawns = QuotaServiceTests.Spawns

    static func liveBody() throws -> String { try QuotaServiceTests.liveBody() }

    /// An open panel is the one moment somebody is looking at the bars, so it
    /// gets a shorter leash than a background clock — the complaint this closes
    /// is a number that only ever moved when a turn finished.
    /// Through the entry point the app calls, not through `refresh` directly.
    /// The spacing an open panel gets is chosen inside `refreshForWatcher`, and
    /// that choice is the one with a cost attached: drop it and an open panel
    /// becomes a child process every second.
    @Test("The panel's own entry point keeps the tighter spacing")
    func watcherEntryPointIsSpaced() async throws {
        let clock = Clock()
        let spawns = Spawns()
        let body = try Self.liveBody()
        spawns.configure = { $1.reactions[AccountMethods.rateLimits] = [.result(body)] }
        let service = QuotaServiceTests.service(clock: clock, spawns: spawns)

        await service.refreshForWatcher()
        #expect(spawns.count == 1)

        // A second later — the open panel's own clock — nothing is spawned.
        clock.advance(by: .seconds(1))
        await service.refreshForWatcher()
        #expect(spawns.count == 1)

        // One tick short of the gap, still nothing.
        clock.advance(by: QuotaSettings.watchingSpacing - .seconds(2))
        await service.refreshForWatcher()
        #expect(spawns.count == 1)

        clock.advance(by: .seconds(1))
        await service.refreshForWatcher()
        #expect(spawns.count == 2)
    }

    /// And a finished turn keeps the wider one, through its own entry point.
    @Test("A finished turn keeps the background spacing")
    func turnEntryPointIsSpaced() async throws {
        let clock = Clock()
        let spawns = Spawns()
        let body = try Self.liveBody()
        spawns.configure = { $1.reactions[AccountMethods.rateLimits] = [.result(body)] }
        let service = QuotaServiceTests.service(clock: clock, spawns: spawns)

        await service.refreshAfterTurn()
        clock.advance(by: QuotaSettings.watchingSpacing)
        await service.refreshAfterTurn()
        #expect(spawns.count == 1)

        clock.advance(by: QuotaSettings.minimumSpacing)
        await service.refreshAfterTurn()
        #expect(spawns.count == 2)
    }

    @Test("Someone watching the panel gets a fresher reading than a background clock")
    func watchingReadsSooner() async throws {
        let clock = Clock()
        let spawns = Spawns()
        let body = try Self.liveBody()
        spawns.configure = { $1.reactions[AccountMethods.rateLimits] = [.result(body)] }
        let service = QuotaServiceTests.service(clock: clock, spawns: spawns)

        await service.refresh(reason: "launch")
        #expect(spawns.count == 1)

        // Past the watching gap but well inside the background one: a
        // background caller is still refused here.
        clock.advance(by: QuotaSettings.watchingSpacing)
        await service.refresh(reason: "interval")
        #expect(spawns.count == 1)

        await service.refresh(reason: "panel open", spacing: QuotaSettings.watchingSpacing)
        #expect(spawns.count == 2)
    }

    /// And it is a shorter leash, not no leash. The panel's clock ticks once a
    /// second; without the spacing that would be a child process a second.
    @Test("Watching is throttled too")
    func watchingIsStillThrottled() async throws {
        let clock = Clock()
        let spawns = Spawns()
        let body = try Self.liveBody()
        spawns.configure = { $1.reactions[AccountMethods.rateLimits] = [.result(body)] }
        let service = QuotaServiceTests.service(clock: clock, spawns: spawns)

        for _ in 0..<10 {
            await service.refresh(reason: "panel open", spacing: QuotaSettings.watchingSpacing)
            clock.advance(by: .seconds(1))
        }
        #expect(spawns.count == 1)
    }

    /// The cadences have to stay in this order, and the order is the argument
    /// for the whole design: the tightest gap is the one a person asked for by
    /// looking, and even that is a minute. Every read is a request the user's
    /// own Codex makes against their own account, so nothing here may drift
    /// towards something that reads as automation
    /// ([tos-boundary.md](../../docs/dev/tos-boundary.md)).
    /// The other end of `OpenPanelTickTests.windowIsSane`, which reasons about
    /// this number and cannot see it: `AgentBarUI` may import only
    /// `AgentBarCore`. Change it here and that comparison stops meaning what it
    /// says, so it is pinned to the literal on this side.
    @Test("The watching gap is a minute")
    func spacingIsAMinute() {
        #expect(QuotaSettings.watchingSpacing == .seconds(60))
    }

    @Test("The cadences stay ordered, and the tightest of them is a minute")
    func cadencesAreOrdered() {
        #expect(QuotaSettings.watchingSpacing >= .seconds(60))
        #expect(QuotaSettings.watchingSpacing < QuotaSettings.minimumSpacing)
        #expect(QuotaSettings.minimumSpacing < QuotaSettings.defaultInterval)
        #expect(QuotaSettings.defaultInterval >= QuotaSettings.minimumInterval)
        #expect(QuotaSettings.defaultInterval <= QuotaSettings.maximumInterval)
    }
}
