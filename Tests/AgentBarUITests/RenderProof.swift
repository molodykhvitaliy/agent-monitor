import AgentBarCore
import AppKit
import CoreImage
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
        let plans = SessionStateKind.allCases.map { GlyphFigure.plan(for: $0) }
        try RenderOutput.write(Self.strip(of: plans, scale: 8), to: "glyphs")
    }

    /// The Waiting pulse, frame by frame, which is the one thing a still cannot
    /// show and the one animation that ships.
    @Test("Every frame of the Waiting pulse")
    func renderPulseFrames() throws {
        let count = GlyphFigure.frameCount(for: DesignTokens.Motion.waitingPulse)
        let plans = (0..<count).map { index in
            GlyphFigure.plan(
                for: .waiting,
                phase: GlyphFigure.waitingRestingPhase + Double(index) / Double(count))
        }
        try RenderOutput.write(Self.strip(of: plans, scale: 4), to: "glyph-pulse")
    }

    /// One row of figures on white, so a person can judge them side by side at a
    /// size the menu bar never draws.
    private static func strip(of plans: [GlyphPlan], scale: CGFloat) -> NSImage {
        let cell = GlyphFigure.canvas * scale
        let size = NSSize(width: cell * CGFloat(plans.count), height: cell)
        let strip = NSImage(size: size)
        strip.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, plan) in plans.enumerated() {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform()
            transform.translateX(by: CGFloat(index) * cell, yBy: 0)
            transform.concat()
            GlyphRenderer.draw(plan, size: cell)
            NSGraphicsContext.restoreGraphicsState()
        }
        strip.unlockFocus()
        return strip
    }

    /// Every step of the first run, in both appearances. The one surface with
    /// no other way to be looked at: it shows once, on a machine that has never
    /// run the app.
    @Test("The five onboarding steps")
    func renderOnboarding() async throws {
        for step in OnboardingStep.allCases {
            let model = await Self.onboardingModel(at: step)
            for dark in [false, true] {
                guard
                    let image = RenderOutput.snapshot(
                        OnboardingView(model: model, onOpenSettings: {})
                            .environment(
                                \.accessibilityPreferences, AccessibilityPreferences.shared),
                        dark: dark)
                else { continue }
                try RenderOutput.write(
                    image,
                    to: "onboarding-\(step.number)-\(step.rawValue)"
                        + (dark ? "-dark" : "-light"))
            }
        }
    }

    /// A flow parked on one step, with a half-finished install behind it —
    /// Claude Code connected and Codex installed but not trusted, which is the
    /// state that exercises every branch of the two install steps at once.
    private static func onboardingModel(at step: OnboardingStep) async -> OnboardingModel {
        let panel = StubServices()
        panel.storedStatuses = [
            UIFixture.status(.claudeCode, .connected),
            UIFixture.status(.codex, .notTrusted),
        ]
        let model = OnboardingModel(
            panel: panel, settings: StubSettingsServices(),
            state: OnboardingState(defaults: UserDefaults(suiteName: "render") ?? .standard))
        await model.refresh()
        while model.step != step, model.step != .done { await model.next() }
        return model
    }

    /// The four squares a banner can carry, at the size they are generated and
    /// again with the colour taken out — because the rule they have to obey is
    /// "silhouette first", and a colour render cannot show whether they do.
    @Test("The four attachment squares, in colour and in grey")
    func renderAttachments() throws {
        for verb in NotificationVerb.allCases {
            guard
                let image = RenderOutput.snapshot(
                    EventAttachmentArt(verb: verb, size: 128), dark: false)
            else { continue }
            try RenderOutput.write(image, to: "attachment-\(verb.rawValue)")
            if let grey = image.desaturated() {
                try RenderOutput.write(grey, to: "attachment-\(verb.rawValue)-grey")
            }
        }
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
    ///
    /// > **At the size the window actually opens at, not at its natural size.**
    /// > Rendering the form unconstrained was what hid the sizing defect this
    /// > step fixed: the natural size is 744 × 1226, the render was happy with
    /// > it, and the window adopted it and ran off the bottom of the screen.
    /// > Constrained to `SettingsWindowLayout.ideal`, the PNG is what the user
    /// > sees — including whether the matrix still fits across.
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
            .frame(
                width: SettingsWindowLayout.ideal.width,
                height: SettingsWindowLayout.ideal.height)
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
                provider: .codex, name: "Weekly", fractionUsed: 0.34,
                resetsAt: Date().addingTimeInterval(7800)),
            UsageWindow(
                provider: .codex, name: "Extra", fractionUsed: nil,
                resetsAt: Date().addingTimeInterval(3 * 86400)),
        ]
        return services
    }
}

extension NSImage {
    /// The same image with its colour removed, for judging a silhouette.
    ///
    /// A development aid, not an assertion — `EventAttachmentTests` is what
    /// actually holds the rule. This is for looking at.
    func desaturated() -> NSImage? {
        guard let tiff = tiffRepresentation,
            let source = CIImage(data: tiff),
            let filter = CIFilter(name: "CIPhotoEffectMono")
        else { return nil }
        filter.setValue(source, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
