import AgentBarCore
import AppKit
import SwiftUI
import Testing

@testable import AgentBarUI

/// The half of the render proof that needs a **window** rather than a view.
///
/// Split from `RenderProof` for length alone; it is the same suite, and the
/// `@Suite` trait that gates the whole thing on `AGENTBAR_RENDER` covers these
/// too — an extension cannot carry its own.
@MainActor
extension RenderProof {

    /// The settings window **including its own chrome**, which is the one thing
    /// a view snapshot cannot show.
    ///
    /// This window took its title bar away in visual v2: the buttons sit
    /// directly on the sidebar's glass, the way every native macOS window with a
    /// sidebar has since Big Sur. That is three separate decisions —
    /// `fullSizeContentView`, a transparent title bar, and a surface that
    /// ignores the safe area the buttons live in — and getting any one of them
    /// wrong produces something that still passes every layout test: a bare
    /// strip above the sidebar, or a whole interface pushed an inch down the
    /// window because the safe-area inset was paid for twice.
    ///
    /// Captured from the window's **frame view**, the superview of the content
    /// view, because that is where AppKit draws the buttons. Nothing here needs
    /// screen recording: the view draws itself into a bitmap.
    @Test("The settings window, chrome and all")
    func renderSettingsWindow() async throws {
        for dark in [false, true] {
            let model = SettingsModel(services: Self.previewedSettings())
            let controller = SettingsWindowController(model: model)
            controller.show()
            defer { controller.close() }
            guard let window = controller.renderedWindow else { continue }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            try await Self.shootWindow(window, named: "settings-window-\(dark ? "dark" : "light")")

            // The sidebar's whole claim, asserted rather than described: asking
            // for the last section has to actually move the content pane. Both
            // step-11 sections are shot on the way, because neither has been
            // seen anywhere but here. The
            // anchors live on the section headings, which is where a
            // `ScrollViewReader` can find them — see `sectionHeader`. A missing
            // anchor makes `scrollTo` a silent no-op, so an unmoved scroller is
            // exactly the symptom worth catching.
            //
            // > This is the one assertion that needs a real window, and it is
            // > therefore in the gated proof rather than in `make check`. The
            // > alternative was an `NSWindow` shown from the main suite on every
            // > run, which is a heavier dependency than the claim is worth.
            let before = try #require(Self.scrollOffset(in: window), "no scroll view in the window")
            model.show(.diagnostics)
            try await Self.shootWindow(
                window, named: "settings-window-diagnostics-\(dark ? "dark" : "light")")
            // The **last** section, so the assertion covers the whole scroll
            // rather than a section that happens to be near the top.
            model.show(.removal)
            // With a report on screen, because the section at rest is one button
            // and the part worth looking at is the four verdicts.
            await model.removeEverything()
            model.show(.removal)
            try await Self.shootWindow(
                window, named: "settings-window-removal-\(dark ? "dark" : "light")")
            let after = try #require(Self.scrollOffset(in: window))
            // Not `after > before`: whether a scroll offset grows or shrinks
            // depends on the flippedness of the document view SwiftUI builds
            // under a `Form`, which is not the thing being claimed. The claim
            // is only that the request moved the scroller at all.
            #expect(
                after != before,
                "asking for .removal left the content pane where it was — is the anchor registered?"
            )
        }
    }

    /// How far the settings form has been scrolled, in points from the top.
    ///
    /// Read off the `NSScrollView` SwiftUI builds under the `Form`, because the
    /// scroll position is not something SwiftUI itself will report.
    private static func scrollOffset(in window: NSWindow) -> CGFloat? {
        guard let root = window.contentView else { return nil }
        var pending = [root]
        while let view = pending.first {
            pending.removeFirst()
            if let scroll = view as? NSScrollView { return scroll.contentView.bounds.origin.y }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Draws a window, chrome included, into a PNG.
    ///
    /// From the **frame view** — the superview of the content view — because
    /// that is where AppKit draws the traffic lights, and this window's chrome
    /// is the thing being proved. Nothing here needs screen recording: the view
    /// draws itself into a bitmap.
    private static func shootWindow(_ window: NSWindow, named name: String) async throws {
        // Let the main run loop turn before the capture. SwiftUI applies a state
        // change on a later pass, and the scroll that change drives is animated
        // over `Motion.rise` — a bitmap taken in the same turn is a picture of
        // the frame before anything moved. Sleeping on the main actor is what
        // hands the run loop back; `RunLoop.run(until:)` is unavailable from an
        // async context and would deadlock the actor if it were not.
        try? await Task.sleep(for: .milliseconds(800))
        guard let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        frameView.displayIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else {
            return
        }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let image = NSImage(size: frameView.bounds.size)
        image.addRepresentation(rep)
        try RenderOutput.write(image, to: name)
    }

    /// Both providers with their cells, and Codex switched off — the state that
    /// shows the matrix, the preview's ordered choice, and a disabled column at
    /// once.
    private static func previewedSettings() -> StubSettingsServices {
        let services = StubSettingsServices()
        services.providers = [.claudeCode, .codex]
        services.stored = NotificationPreferences(
            cells: services.providers.flatMap { provider in
                NotificationVerb.allCases.map { verb in
                    NotificationCell(
                        provider: provider, verb: verb, isEnabled: provider == .claudeCode,
                        soundID: StubSettingsServices.defaultSoundID(for: verb))
                }
            })
        services.caffeineIndicator = CaffeineIndicator(
            setting: .whileWorking, isHolding: true, workingSessionCount: 2)
        services.diagnosticsReport = Self.diagnostics
        services.removalReport = Self.removal
        return services
    }

    /// A self-test with one of each verdict in it. The point of shooting this
    /// section at all is that a warning and a fault are legible as *different*
    /// things from three feet away, and a report with three passes in it proves
    /// nothing about that.
    private static var diagnostics: DiagnosticsReport {
        DiagnosticsReport(
            checks: [
                DiagnosticsCheck(
                    id: "endpoint", title: "Loopback endpoint", verdict: .pass,
                    detail: "127.0.0.1:47821 · ingest.sock"),
                DiagnosticsCheck(
                    id: "claude", title: "Claude Code hooks", verdict: .pass,
                    detail: "Connected"),
                DiagnosticsCheck(
                    id: "codex", title: "Codex hooks", verdict: .warn,
                    detail: "Installed, not trusted",
                    remedy: "Codex has no record of these hooks. Review them in /hooks."),
                DiagnosticsCheck(
                    id: "notifications", title: "Notification permission", verdict: .fail,
                    detail: "refused",
                    remedy: """
                        Turn AgentBar on in System Settings › Notifications. Nothing AgentBar \
                        sends will be shown until you do.
                        """),
            ],
            counters: [
                DiagnosticsCounter(id: "deliveries", label: "deliveries", value: 412),
                DiagnosticsCounter(id: "applied", label: "applied", value: 388),
                DiagnosticsCounter(id: "ignored", label: "ignored", value: 24),
                DiagnosticsCounter(
                    id: "rejected", label: "could not decode", value: 2, isFault: true),
                DiagnosticsCounter(
                    id: "unauthorized", label: "unauthorised", value: 0, isFault: true),
                DiagnosticsCounter(
                    id: "malformed", label: "malformed", value: 0, isFault: true),
            ],
            recent: [
                DiagnosticsEntry(
                    id: 3, at: Date(timeIntervalSince1970: 1_700_000_100), severity: .fault,
                    message: "handler for /v1/hooks/codex overran its deadline"),
                DiagnosticsEntry(
                    id: 2, at: Date(timeIntervalSince1970: 1_700_000_060), severity: .notice,
                    message: "could not decode 118 bytes posted to /v1/hooks/codex"),
                DiagnosticsEntry(
                    id: 1, at: Date(timeIntervalSince1970: 1_700_000_000), severity: .info,
                    message: "ingest listening on 127.0.0.1:47821, socket ingest.sock"),
            ],
            resources: "71 MB resident · 2.4 s of processor time in 1 h 12 m · 0.06 % of a core",
            takenAt: Date(timeIntervalSince1970: 1_700_000_120))
    }

    /// A removal that went mostly right, which is the only version of this
    /// report worth looking at: it is the one that has to make a refusal and a
    /// deliberate omission tell themselves apart at a glance.
    private static var removal: RemovalReport {
        RemovalReport(steps: [
            RemovalStep(
                id: "endpoint", title: "Event endpoint", location: "127.0.0.1",
                outcome: .removed(detail: "Stopped listening.")),
            RemovalStep(
                id: "claude-hooks", title: "Claude Code hooks",
                location: "~/.claude/settings.json",
                outcome: .removed(
                    detail: "The file as it was is at ~/.claude/settings.json.bak.20260826.")),
            RemovalStep(
                id: "codex-hooks", title: "Codex hooks", location: "~/.codex/hooks.json",
                outcome: .nothingToRemove),
            RemovalStep(
                id: "codex-trust", title: "Codex trust record", location: "~/.codex/config.toml",
                outcome: .leftAlone(
                    reason: "AgentBar never writes this file, so Codex's record stays where it is.",
                    remedy: """
                        To clear it anyway, delete the [hooks.state] entries whose key contains \
                        hooks.json and agentbar-helper.
                        """)),
            RemovalStep(
                id: "codex-helper", title: "Codex helper",
                location: "~/Library/Application Support/AgentBar/bin/agentbar-helper",
                outcome: .failed(
                    reason: "permission denied",
                    remedy: """
                        Delete ~/Library/Application Support/AgentBar/bin/agentbar-helper by hand.
                        """)),
        ])
    }
}
