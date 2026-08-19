import AgentBarCore
import AppKit
import SwiftUI
import Testing

@testable import AgentBarUI

/// Where the render proof writes, when it is asked to run at all.
///
/// A free type rather than a member of the suite: a `@Suite` trait cannot refer
/// to the type it is attached to.
enum RenderOutput {
    nonisolated static var directory: String? {
        ProcessInfo.processInfo.environment["AGENTBAR_RENDER"]
    }

    @MainActor
    static func write(_ image: NSImage, to name: String) throws {
        guard let directory,
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        // Created rather than required. The documented incantation names a
        // directory that does not exist yet, and the failure it produced was a
        // "file doesn't exist" four tests over from the missing `mkdir`.
        let folder = URL(filePath: directory, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appending(path: "\(name).png"))
    }

    /// Renders a view offscreen at its natural size, in one appearance.
    @MainActor
    static func snapshot(_ view: some View, dark: Bool) -> NSImage? {
        let hosting = NSHostingView(
            rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = NSImage(size: hosting.bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

/// Renders every panel state to PNGs so a person can look at them.
///
/// Not an assertion — a development tool, and the answer to the one question a
/// unit test cannot ask: whether the panel is *pleasant*. It is what caught the
/// provider badge rendering as an ✕, which every other test was happy with.
///
/// Off unless asked for, because it writes files:
///
/// ```
/// AGENTBAR_RENDER=/tmp/agentbar swift test --filter AgentBarUITests
/// ```
@MainActor
@Suite(
    "Render proof",
    .disabled(if: RenderOutput.directory == nil, "set AGENTBAR_RENDER to a directory"))
struct RenderProof {

    @Test("The panel, in both appearances")
    func renderPanel() async throws {
        let model = PanelModel(services: Self.busyServices())
        await model.refreshIntegrations()
        await model.refreshSnapshot()
        try shoot(model, named: "panel-list")

        model.showsIntegrationCard = true
        try shoot(model, named: "panel-card")

        try shoot(PanelModel(services: StubServices()), named: "panel-quiet")

        // A list that fits must not fade: the fade says "there is more below".
        let short = StubServices()
        short.storedSnapshot = UIFixture.snapshot([
            UIFixture.session("a", project: "/Users/dev/code/agentbar-web", state: .idle)
        ])
        short.storedStatuses = [UIFixture.status(.claudeCode, .connected)]
        let shortModel = PanelModel(services: short)
        await shortModel.refreshIntegrations()
        await shortModel.refreshSnapshot()
        try shoot(shortModel, named: "panel-short")
    }

    @Test("The five status glyphs, at eight times size")
    func renderGlyphs() throws {
        let scale: CGFloat = 8
        let kinds = SessionStateKind.allCases
        let size = NSSize(
            width: StatusItemGlyph.canvas * CGFloat(kinds.count) * scale,
            height: StatusItemGlyph.canvas * scale)
        let strip = NSImage(size: size)
        strip.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, kind) in kinds.enumerated() {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(
                by: CGFloat(index) * StatusItemGlyph.canvas * scale, yBy: 0)
            transform.scale(by: scale)
            transform.concat()
            StatusItemGlyph.draw(kind)
            NSGraphicsContext.restoreGraphicsState()
        }
        strip.unlockFocus()
        try RenderOutput.write(strip, to: "glyphs")
    }

    @Test("Both provider badges, large enough to judge")
    func renderBadges() throws {
        for provider in Provider.allCases {
            guard
                let image = RenderOutput.snapshot(
                    ProviderBadge(provider: provider, size: 104).padding(8), dark: false)
            else { continue }
            try RenderOutput.write(image, to: "badge-\(provider.rawValue)")
        }
    }

    /// The settings window, which the panel's own render cannot reach.
    ///
    /// Rendered in the state that is easiest to get wrong: Caffeine holding, so
    /// the live status line and the picker are both showing something.
    @Test("The settings window, in both appearances")
    func renderSettings() throws {
        let services = StubSettingsServices()
        // Both providers, because the app registers both from step 09 on: the
        // matrix gains a second column there, and a column that does not fit is
        // exactly what this render exists to catch. The cells have to be given
        // too — the stub's default matrix has one provider in it, and a column
        // whose cells are missing renders as a header over empty space, which
        // is what the first run of this render showed.
        services.providers = [.claudeCode, .codex]
        services.stored = NotificationPreferences(
            cells: services.providers.flatMap { provider in
                NotificationVerb.allCases.map { verb in
                    NotificationCell(
                        provider: provider, verb: verb, isEnabled: provider == .claudeCode,
                        soundID: "AgentBar \(verb.title).aiff")
                }
            })
        services.caffeineIndicator = CaffeineIndicator(
            setting: .whileWorking, isHolding: true, workingSessionCount: 2)
        let view = SettingsView(model: SettingsModel(services: services))
            .environment(\.accessibilityPreferences, AccessibilityPreferences.shared)
        for dark in [false, true] {
            guard let image = RenderOutput.snapshot(view, dark: dark) else { continue }
            try RenderOutput.write(image, to: "settings-\(dark ? "dark" : "light")")
        }
    }

    private func shoot(_ model: PanelModel, named name: String) throws {
        for dark in [false, true] {
            guard
                let image = RenderOutput.snapshot(
                    PanelView(model: model, onSettings: {}, onQuit: {})
                        .environment(\.accessibilityPreferences, AccessibilityPreferences.shared),
                    dark: dark)
            else { continue }
            try RenderOutput.write(image, to: "\(name)-\(dark ? "dark" : "light")")
        }
    }

    /// Several projects, a dozen sessions, every state — the load the step's
    /// validation asks for.
    private static func busyServices() -> StubServices {
        let services = StubServices()
        // Two of these sessions are working, so the footer's Caffeine indicator
        // renders in the state that is hardest to get right: holding.
        services.caffeineIndicator = CaffeineIndicator(
            setting: .whileWorking, isHolding: true, workingSessionCount: 2)
        services.storedSnapshot = UIFixture.snapshot([
            UIFixture.session(
                "a", project: "/Users/dev/code/agentbar-web",
                state: .waitingInput(question: "Which database should the migration target?")),
            UIFixture.session(
                "b", project: "/Users/dev/code/agentbar-web", state: .working,
                tool: ToolRef(name: "Bash", invocation: "swift test --parallel"),
                subagents: 2, timeInState: .seconds(252)),
            UIFixture.session(
                "c", project: "/Users/dev/code/agentbar-web", state: .working, tool: nil,
                timeInState: .seconds(4)),
            UIFixture.session(
                "d", provider: .codex, project: "/Users/dev/code/growth-scripts",
                state: .failed(reason: "Rate limit reached"), timeInState: .seconds(900)),
            UIFixture.session(
                "e", provider: .codex, project: "/Users/dev/code/growth-scripts",
                state: .idle, timeInState: .seconds(4800)),
            UIFixture.session(
                "f", project: "/Users/dev/code/infra-scripts", state: .unknown,
                timeInState: .seconds(180), silence: .seconds(1080)),
            UIFixture.session(
                "g", project: "/Users/dev/worktrees/feature-x/agentbar-web", state: .idle,
                timeInState: .seconds(60)),
        ])
        services.storedStatuses = [
            UIFixture.status(.claudeCode, .connected),
            UIFixture.status(.codex, .notTrusted),
        ]
        services.storedWindows = [
            // Relative to now, because `LimitsSectionView` renders against the
            // clock and a fixed epoch would draw a nonsense reset time.
            UsageWindow(
                name: "Weekly", fractionUsed: 0.34,
                resetsAt: Date().addingTimeInterval(7800)),
            UsageWindow(
                name: "Extra", fractionUsed: nil,
                resetsAt: Date().addingTimeInterval(3 * 86400)),
        ]
        return services
    }
}
