import AgentBarCore
import Foundation
import Testing

@testable import AgentBarNotifications

/// A busy turn moves a session several times a second. Without this the product
/// would be unusable within a minute of installing it.
@Suite("Coalescing")
struct CoalescingTests {

    private let start = MonotonicInstant.origin

    @Test("A burst on one session produces one notification, the newest")
    func newestWins() {
        var coalescer = NotificationCoalescer()
        coalescer.enqueue(
            Fixture.draft(event: .waiting, at: Fixture.epoch))
        coalescer.enqueue(
            Fixture.draft(event: .finished, at: Fixture.epoch.addingTimeInterval(0.3)))

        let drained = coalescer.drain()
        #expect(drained.count == 1)
        #expect(drained.first?.event == .finished)
    }

    /// Ordering is by when the store observed the change, not by arrival: a
    /// late-delivered older event must not jump the queue.
    @Test("An older draft does not replace a newer one")
    func olderDraftIsIgnored() {
        var coalescer = NotificationCoalescer()
        coalescer.enqueue(Fixture.draft(event: .finished, at: Fixture.epoch.addingTimeInterval(5)))
        coalescer.enqueue(Fixture.draft(event: .waiting, at: Fixture.epoch))

        #expect(coalescer.drain().first?.event == .finished)
    }

    @Test("Separate sessions each keep their own notification")
    func sessionsAreIndependent() {
        var coalescer = NotificationCoalescer()
        coalescer.enqueue(Fixture.draft("a", event: .waiting))
        coalescer.enqueue(Fixture.draft("b", event: .failed))
        #expect(coalescer.drain().count == 2)
    }

    @Test("New urgent news invalidates an older deferred draft for the same session")
    func urgentNewsDiscardsStaleDeferredDraft() {
        var coalescer = NotificationCoalescer()
        coalescer.enqueue(Fixture.draft(event: .finished, at: Fixture.epoch))

        coalescer.discardPending(
            through: Fixture.epoch.addingTimeInterval(0.1), for: SessionID("s1"))

        #expect(coalescer.drain().isEmpty)
    }

    @Test("An out-of-order older urgent event does not discard newer Finished news")
    func olderUrgentNewsKeepsNewerDeferredDraft() {
        var coalescer = NotificationCoalescer()
        let finishedAt = Fixture.epoch.addingTimeInterval(1)
        coalescer.enqueue(Fixture.draft(event: .finished, at: finishedAt))

        coalescer.discardPending(through: Fixture.epoch, for: SessionID("s1"))

        #expect(coalescer.drain().first?.at == finishedAt)
    }

    /// A dictionary has no order, and two banners appearing in a different order
    /// on two runs is what makes a user distrust the app.
    @Test("Delivery is ordered by observation time, then by session")
    func deterministicOrder() {
        var coalescer = NotificationCoalescer()
        coalescer.enqueue(Fixture.draft("z", at: Fixture.epoch.addingTimeInterval(1)))
        coalescer.enqueue(Fixture.draft("a", at: Fixture.epoch))
        coalescer.enqueue(Fixture.draft("m", at: Fixture.epoch))

        let order = coalescer.drain().map(\.sessionId.value)
        #expect(order == ["a", "m", "z"])
    }

    @Test("Draining an empty queue is nothing, not a crash")
    func drainingEmpty() {
        var coalescer = NotificationCoalescer()
        #expect(coalescer.isEmpty)
        #expect(coalescer.drain().isEmpty)
    }

    /// `drain` deliberately does **not** record a delivery: what starts the
    /// repeat window is the decision to deliver, which happens after the gate.
    @Test("Draining alone starts no repeat window")
    func drainDoesNotRecordDelivery() {
        var coalescer = NotificationCoalescer()
        let draft = Fixture.draft(event: .waiting)
        coalescer.enqueue(draft)
        _ = coalescer.drain()
        // A draft the gate suppressed must not stop the same news arriving the
        // moment the reason for suppressing it goes away.
        #expect(!coalescer.isRepeat(draft, now: start))
    }

    @Test("An identical notification is a repeat inside the window")
    func repeatSuppressed() {
        var coalescer = NotificationCoalescer()
        let draft = Fixture.draft(event: .waiting)
        coalescer.recordDelivery(of: draft, at: start)
        #expect(coalescer.isRepeat(draft, now: start.advanced(by: .seconds(1))))
    }

    @Test("The same notification is news again once the window has passed")
    func repeatAllowedLater() {
        var coalescer = NotificationCoalescer()
        let draft = Fixture.draft(event: .waiting)
        coalescer.recordDelivery(of: draft, at: start)
        let later = start.advanced(by: NotificationCoalescer.urgentRepeatWindow + .seconds(1))
        #expect(!coalescer.isRepeat(draft, now: later))
    }

    /// The case that matters: an agent that asks a *different* question is
    /// genuinely new information and must get through.
    @Test("A different question is not a repeat")
    func differentBodyIsNews() {
        var coalescer = NotificationCoalescer()
        coalescer.recordDelivery(
            of: Fixture.draft(event: .question, body: "Which branch?"), at: start)
        #expect(
            !coalescer.isRepeat(
                Fixture.draft(event: .question, body: "Overwrite the file?"),
                now: start.advanced(by: .seconds(2))))
    }

    @Test("Only the same approval fingerprint is a repeat")
    func approvalFingerprintDistinguishesRequests() {
        var coalescer = NotificationCoalescer()
        let delivered = Fixture.draft(
            event: .approval, body: "Run command", fingerprint: "codex:one")
        coalescer.recordDelivery(of: delivered, at: start)

        #expect(
            coalescer.isRepeat(
                delivered, now: start.advanced(by: .milliseconds(100))))
        #expect(
            !coalescer.isRepeat(
                Fixture.draft(
                    event: .approval, body: "Run command", fingerprint: "codex:two"),
                now: start.advanced(by: .milliseconds(100))))
    }

    @Test("An intervening approval does not make an earlier fingerprint new again")
    func remembersMultipleRecentFingerprintsPerSession() {
        var coalescer = NotificationCoalescer()
        let first = Fixture.draft(
            event: .approval, body: "Run command", fingerprint: "codex:one")
        let second = Fixture.draft(
            event: .approval, body: "Run command", fingerprint: "codex:two")
        coalescer.recordDelivery(of: first, at: start)
        coalescer.recordDelivery(of: second, at: start.advanced(by: .milliseconds(50)))

        #expect(
            coalescer.isRepeat(
                first, now: start.advanced(by: .milliseconds(100))))
    }

    @Test("A different verb for the same session is not a repeat")
    func differentEventIsNews() {
        var coalescer = NotificationCoalescer()
        coalescer.recordDelivery(of: Fixture.draft(event: .waiting), at: start)
        #expect(
            !coalescer.isRepeat(
                Fixture.draft(event: .failed, body: "boom"), now: start.advanced(by: .seconds(1))))
    }

    @Test("Another session's delivery is not this session's repeat")
    func repeatsArePerSession() {
        var coalescer = NotificationCoalescer()
        coalescer.recordDelivery(of: Fixture.draft("a", event: .waiting), at: start)
        #expect(!coalescer.isRepeat(Fixture.draft("b", event: .waiting), now: start))
    }

    /// Without expiry the delivery map grows for the life of the process.
    @Test("Delivery memory does not grow without bound")
    func forgetsOldDeliveries() {
        var coalescer = NotificationCoalescer()
        for index in 0..<50 {
            coalescer.recordDelivery(of: Fixture.draft("s\(index)"), at: start)
        }
        let muchLater = start.advanced(by: NotificationCoalescer.repeatWindow * 10)
        // Recording anything sweeps the expired entries, and the old one is
        // then no longer a repeat — which is only possible if it was dropped.
        coalescer.recordDelivery(of: Fixture.draft("fresh"), at: muchLater)
        #expect(!coalescer.isRepeat(Fixture.draft("s0"), now: muchLater))
    }
}
