import AgentBarCore
import Foundation
import Testing

@testable import AgentBarUI

/// What the panel redraws for, and what it does not.
///
/// Every publication from `PanelModel` invalidates the whole panel — every row,
/// every localised string, every formatted date — and the open clock re-reads it
/// once a second whether or not anything moved. A model that published each of
/// those readings would redraw sixty times a minute to draw the same pixels,
/// which is most of what made a panel full of finished sessions expensive.
///
/// Two claims, and they are different in kind. One is about this code: the
/// `refreshSnapshot` guard. The other is about the **toolchain** — that
/// Observation suppresses an assignment whose value is equal — and it is
/// load-bearing for the two places that deliberately have no guard, so it is
/// asserted here rather than trusted in a comment.
@MainActor
@Suite("Panel publication")
struct PanelPublicationTests {

    private func model(_ services: StubServices) -> PanelModel {
        PanelModel(services: services)
    }

    /// Counts publications from `withObservationTracking`, whose `onChange` is
    /// `@Sendable` and fires during the mutation.
    private final class Publications: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func record() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

    /// Every publication rebuilds every row of the panel, and the open clock
    /// re-reads once a second whether or not anything moved.
    ///
    /// Observation suppresses an assignment whose value is equal, so most of
    /// this model needs no help. `StoreSnapshot` is the exception and the reason
    /// `refreshSnapshot` has a guard at all: `takenAt` is a fresh `Date` on
    /// every read, so two readings of an unchanged store are never equal and the
    /// framework would publish all sixty of them a minute. This pins the guard
    /// on exactly that difference — two readings that differ **only** in
    /// `takenAt` must not redraw anything.
    @Test("A reading that differs only in when it was taken is not published")
    func unchangedReadingsDoNotPublish() async {
        let services = StubServices()
        let sessions = [UIFixture.session("a")]
        services.storedSnapshot = UIFixture.snapshot(sessions)
        let model = model(services)
        await model.refreshSnapshot()

        let publications = Publications()
        var observed = 0
        // Read into something the optimiser cannot drop: a tracking block that
        // registers nothing is a test that passes whatever the code does.
        withObservationTracking {
            observed = model.snapshot.projects.count
        } onChange: {
            publications.record()
        }
        #expect(observed == 1, "the tracking block has to have actually read something")

        for tick in 1...4 {
            services.storedSnapshot = StoreSnapshot(
                takenAt: UIFixture.epoch.addingTimeInterval(TimeInterval(tick)),
                projects: services.storedSnapshot.projects)
            await model.refreshSnapshot()
        }
        #expect(
            publications.value == 0,
            "\(publications.value) redraws for a panel whose only change was the clock")

        // A reading that really did move still lands, or the guard would be a
        // panel that quietly stopped updating. The registration above is still
        // armed: `onChange` fires once and only once, and it has not fired yet,
        // which is the whole of the claim made above.
        services.storedSnapshot = UIFixture.snapshot([
            UIFixture.session("a"), UIFixture.session("b"),
        ])
        await model.refreshSnapshot()
        #expect(publications.value == 1)
    }

    /// The premise the two *absent* guards rest on.
    ///
    /// `refreshUsage` and `CaffeineController.apply` assign unconditionally,
    /// because Observation suppresses an assignment whose value is equal. That
    /// claim is load-bearing — `usage` is re-read on the open panel's
    /// one-second clock and read by `LimitsSectionView` inside the panel body,
    /// so if it were false an unchanged reading would invalidate the whole panel
    /// sixty times a minute, which is the cost this work exists to remove — and
    /// it is a claim about the toolchain rather than about this code. So it is
    /// asserted here rather than in a comment: if a future Swift stops
    /// suppressing, this fails and the guards go back.
    @Test("Observation suppresses an assignment whose value is equal")
    func equalAssignmentsAreSuppressedByObservation() async {
        let services = StubServices()
        services.storedWindows = [
            UsageWindow(provider: .codex, name: "Weekly", fractionUsed: 0.5, resetsAt: nil)
        ]
        let model = model(services)
        await model.refreshUsage()

        let publications = Publications()
        var observed = 0
        withObservationTracking {
            observed = model.usage.count
        } onChange: {
            publications.record()
        }
        #expect(observed == 1, "the tracking block has to have actually read something")

        // The same windows, four times over, exactly as the open clock re-reads
        // them. `onChange` is one-shot, so a single suppressed assignment would
        // not prove much; four is the cadence.
        for _ in 0..<4 { await model.refreshUsage() }
        #expect(
            publications.value == 0,
            """
            \(publications.value) publications for an unchanged `[UsageWindow]` — Observation \
            no longer suppresses equal assignments, and `refreshUsage` needs its guard back
            """)

        // And the registration is still live, which is what makes the silence
        // above mean "suppressed" rather than "already consumed".
        services.storedWindows = [
            UsageWindow(provider: .codex, name: "Weekly", fractionUsed: 0.6, resetsAt: nil)
        ]
        await model.refreshUsage()
        #expect(publications.value == 1)
    }
}
