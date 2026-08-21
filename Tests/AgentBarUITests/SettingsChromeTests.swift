import AgentBarCore
import AppKit
import SwiftUI
import Testing

@testable import AgentBarUI

/// The window's own chrome, against a real `NSWindow`.
///
/// Visual v2 took this window's title bar away — `fullSizeContentView`, a
/// transparent bar, a hidden title — so the traffic lights sit on the sidebar's
/// glass. Every consequence of that is a **platform fact** rather than a
/// preference, and this repository's rule about platform facts is that they are
/// verified rather than remembered. Each of these fails if AppKit changes its
/// mind, which is exactly when somebody needs to hear about it.
///
/// The windows here are created and never ordered front, activated or shown.
@MainActor
@Suite("Settings window chrome")
struct SettingsWindowChromeTests {

    /// A window built the way `SettingsWindowController` builds one.
    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        return window
    }

    /// The regression the shrink path had, in one assertion.
    ///
    /// `fitToScreen` compares the window's current size against the room it has
    /// and resizes when it no longer fits. Read that size from
    /// `contentLayoutRect` — the part *not obscured by the title bar* — and it
    /// comes back a title bar short of what `setContentSize` just set, so every
    /// showing shrinks the window again. Nothing else would notice: no
    /// exception, no failing layout, just a window that loses an inch a visit.
    @Test("The size the window reports is the size it was set to")
    func currentSizeRoundTrips() {
        let window = self.window()
        let wanted = NSSize(width: 880, height: 560)
        window.setContentSize(wanted)

        #expect(SettingsWindowLayout.currentContentSize(of: window) == wanted)
        // And the trap, named so it cannot be walked back into: the tempting
        // alternative reads short by exactly the title bar.
        #expect(window.contentLayoutRect.size != wanted)
        #expect(window.contentLayoutRect.height < wanted.height)
    }

    /// A window whose frame *is* its content rect adds no chrome, so nothing may
    /// be subtracted from the screen on its behalf.
    @Test("A full-size content view adds no chrome to subtract")
    func chromeIsNothing() {
        #expect(window().frameRect(forContentRect: .zero).size == .zero)
    }

    /// Where the room for the traffic lights comes from.
    ///
    /// The sidebar spends only `markTopPadding` above its mark; the rest is this
    /// inset, which AppKit publishes and SwiftUI lays the whole view out inside.
    /// Paying for it a second time in the view pushes the interface an inch down
    /// the window; not accounting for it at all puts the buttons on a bare
    /// strip. Both were live possibilities while this was built, and the number
    /// is asserted here rather than spelled anywhere in the view.
    @Test("The window publishes a title-bar safe area for the view to sit inside")
    func publishesASafeArea() throws {
        let window = self.window()
        window.contentView = NSView()
        let inset = try #require(window.contentView?.safeAreaInsets)
        #expect(inset.top > 0, "the sidebar's content would sit under the traffic lights")
        #expect(inset.left == 0 && inset.right == 0 && inset.bottom == 0)
        // The same number, from the other direction: an ordinary titled window
        // has no safe area because its content starts below the bar.
        #expect(inset.top == window.frame.height - window.contentLayoutRect.height)
    }
}

/// The window's navigation, which is a list the sidebar and the content pane
/// both build from.
@MainActor
@Suite("Settings sections")
struct SettingsSectionTests {

    /// The window opens on the section the preview block lives in, because that
    /// is the block every other setting is about.
    @Test("A fresh window opens on Notifications")
    func opensOnNotifications() {
        #expect(SettingsModel(services: StubSettingsServices()).section == .notifications)
        #expect(SettingsSection.allCases.first == .notifications)
    }

    /// A sidebar is a list a person reads at a glance, and two rows that look
    /// or read alike are two rows they have to try in turn. Cheap to assert and
    /// exactly the kind of thing a seventh section added in a hurry breaks.
    @Test("Every section is distinguishable from every other")
    func sectionsAreDistinct() {
        let titles = SettingsSection.allCases.map(\.title)
        let symbols = SettingsSection.allCases.map(\.symbol)
        #expect(Set(titles).count == SettingsSection.allCases.count)
        #expect(Set(symbols).count == SettingsSection.allCases.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
        // Every symbol has to exist, or the row draws an empty box: a name that
        // SF Symbols does not know fails silently in `Image(systemName:)`.
        for symbol in symbols {
            #expect(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "\(symbol) is not an SF Symbol on this system")
        }
    }

    /// Pressing a row asks the pane to move, and pressing the **same** row asks
    /// again.
    ///
    /// The second half is the one worth a test. The lit row deliberately does
    /// not follow the scroll, so a user can press `Sounds`, scroll away by hand,
    /// and press the still-lit `Sounds` to come back — the most natural gesture
    /// there is in a scroll-anchored sidebar, and one a view keyed on the
    /// section alone would silently ignore because nothing changed.
    @Test("Asking for a section twice is two requests, not one")
    func repeatedRequestsAreDistinct() {
        let model = SettingsModel(services: StubSettingsServices())
        let first = model.navigation

        model.show(.sounds)
        #expect(model.section == .sounds)
        #expect(model.navigation != first)

        let second = model.navigation
        model.show(.sounds)
        #expect(model.section == .sounds)
        #expect(model.navigation != second, "a repeated press has to be a new request")
    }

    /// The one thing about the About pane worth pinning: it never shows a
    /// version it does not have. A `0.0` invented from a missing key reads as a
    /// real version, and the whole point of the line is that it is checkable.
    @Test("A bundle with no version says so rather than inventing one")
    func versionDegrades() {
        // `Bundle.main` under `swift test` is the test runner, which carries no
        // `CFBundleShortVersionString` — so this is the degraded path, taken for
        // real rather than simulated.
        let summary = SettingsView.versionSummary
        #expect(!summary.isEmpty)
        #expect(summary != "0.0")
    }
}
