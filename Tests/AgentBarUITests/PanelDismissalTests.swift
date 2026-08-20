import AppKit
import Testing

@testable import AgentBarUI

/// Which clicks close the panel.
///
/// The defect: pressing the menu-bar icon a second time did not close the panel,
/// it reopened it. Two handlers see that click — the global mouse monitor that
/// dismisses the panel, and the status item button's own action that toggles it
/// — and the monitor runs first, on mouse-down. It closed the panel, the action
/// then found it closed, and opened it again. Net effect: a toggle that only
/// ever opens.
///
/// The rule is that the button owns what a click on the button means. This is
/// that rule, as a function, so it can be tested without a menu bar.
@MainActor
@Suite("Panel dismissal")
struct PanelDismissalTests {
    private let statusItem = NSRect(x: 1200, y: 1050, width: 30, height: 24)

    @Test("A click on the status item is left to the status item")
    func ignoresTheStatusItem() {
        #expect(
            !PanelDismissal.dismisses(
                .leftMouseDown, at: NSPoint(x: 1215, y: 1060), statusItem: statusItem))
    }

    /// The edges belong to the button too — `NSRect.contains` excludes the far
    /// edge, which is the behaviour a click at the boundary should get.
    @Test("The near edge counts as the status item")
    func includesTheNearEdge() {
        #expect(
            !PanelDismissal.dismisses(
                .leftMouseDown, at: NSPoint(x: 1200, y: 1050), statusItem: statusItem))
    }

    @Test("A click anywhere else closes the panel")
    func dismissesElsewhere() {
        #expect(
            PanelDismissal.dismisses(
                .leftMouseDown, at: NSPoint(x: 400, y: 400), statusItem: statusItem))
        // Directly below the item, which is where the panel itself is — the
        // panel's own clicks are not global events, so this is a click on some
        // other window and closing is right.
        #expect(
            PanelDismissal.dismisses(
                .leftMouseDown, at: NSPoint(x: 1215, y: 800), statusItem: statusItem))
    }

    /// A menu bar that has gone — a display detached mid-click — is not a
    /// reason to stop dismissing. Failing open here leaves a panel that cannot
    /// be closed by clicking away.
    @Test("With no status item to compare against, a click still dismisses")
    func dismissesWithoutAnAnchor() {
        #expect(
            PanelDismissal.dismisses(
                .leftMouseDown, at: NSPoint(x: 1215, y: 1060), statusItem: nil))
    }

    /// The exemption may be no wider than the buttons the status item actually
    /// acts on. It sends its action on left and right only, so a middle-click
    /// exempted here would be a click neither handler answers — and a panel
    /// that neither closes.
    @Test("A button the status item does not handle still dismisses")
    func dismissesOnAnUnhandledButton() {
        let onTheItem = NSPoint(x: 1215, y: 1060)
        #expect(!PanelDismissal.dismisses(.leftMouseDown, at: onTheItem, statusItem: statusItem))
        #expect(!PanelDismissal.dismisses(.rightMouseDown, at: onTheItem, statusItem: statusItem))
        #expect(PanelDismissal.dismisses(.otherMouseDown, at: onTheItem, statusItem: statusItem))
    }
}
