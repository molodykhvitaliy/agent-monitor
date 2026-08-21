import AgentBarCore
import AppKit

/// The two clocks that keep the status item and the panel honest.
///
/// A file of its own for the same reason the first-run flow got one: this is the
/// part of `MenuBarController` that runs forever, and it reads very differently
/// from the parts that respond to a click. The rules it implements are stated on
/// the type itself — push carries every state move, the timers cover only what
/// time alone changes, and the open clock sweeps as well as reads, because the
/// closed one does not run while the panel is up.
extension MenuBarController {

    func scheduleTimer(open: Bool) {
        timer?.invalidate()
        let interval = open ? Self.openInterval : Self.closedInterval
        // Constructed and added by hand rather than `scheduledTimer`, which
        // would install it in `.default` as well: the panel's own tracking loop
        // must not stop the clock while the user drags across a row, and
        // `.common` is the mode that survives it.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.startTick(open: open) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func startTick(open: Bool) {
        Task { await tick(open: open) }
    }

    func tick(open: Bool) async {
        if open {
            switch Self.tick(
                isVisible: panel?.isVisible == true,
                openFor: openedAt.map { ContinuousClock().now - $0 })
            {
            case .retire:
                // The panel went away without telling us. Put the clock back
                // where it belongs and stop asking for anything — including the
                // two repeating indicators inside it.
                model.isOnScreen = false
                openedAt = nil
                scheduleTimer(open: false)
                await model.sweepAndRefresh()
                statusItem?.update(from: model.snapshot)
                return
            case .watch, .show:
                break
            }
            // **Sweeping, not only reading.** The open clock used to re-read the
            // store and leave the retiring to the closed clock, which does not
            // run while the panel is up — so a session the watchdog had given up
            // on stayed on the list, reading `Unknown`, for as long as somebody
            // left the panel open. `unknown` is derived on every read, so the
            // row was always *labelled* correctly; what never happened was it
            // leaving. A sweep is a walk over the live records and an actor hop,
            // which is affordable at this cadence precisely because
            // [ADR-0012](../../docs/adr/ADR-0012-a-finished-session-is-retired-not-doubted.md)
            // keeps that list short.
            await model.sweepAndRefresh()
            // Cheap enough for this clock — an actor hop, no disk — and the only
            // thing that shows a limits refresh landing while the panel is open.
            // Inside the watching window it also *asks* for the next reading;
            // past it the panel goes back to only showing what arrives, because
            // a panel left open is not the same thing as somebody watching it.
            if Self.tick(
                isVisible: true, openFor: openedAt.map { ContinuousClock().now - $0 }) == .watch
            {
                await model.watchUsage()
            } else {
                await model.refreshUsage()
            }
            // The panel is a live list in a borderless window, which does not
            // resize itself to its content. A row appearing or leaving changes
            // the height, so the open clock re-measures as well as re-reads.
            if let button = statusItem?.button { panel?.reposition(under: button) }
        } else {
            // Nothing else retires a session whose agent died — and the power
            // assertion in step 08 depends on that happening.
            await model.sweepAndRefresh()
        }
        statusItem?.update(from: model.snapshot)
    }
}
