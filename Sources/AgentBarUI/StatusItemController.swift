import AppKit

/// Owns the menu-bar presence for the whole app lifetime.
///
/// At this stage it renders a placeholder and offers nothing but Quit. Step 06
/// replaces the menu with a non-activating panel hosting the session list;
/// the ownership and lifetime contract established here does not change.
///
/// `LSUIElement` apps have no Dock icon and no application menu, so the status
/// item is the only way a user can quit. That is why a skeleton with "nothing
/// else" still carries a Quit item.
public final class StatusItemController {
    /// Held for the app's lifetime: `NSStatusBar` drops an item as soon as its
    /// last strong reference goes away, which silently removes it from the bar.
    private let statusItem: NSStatusItem

    public init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureButton()
        statusItem.menu = makePlaceholderMenu()
    }

    /// Removes the item from the menu bar. Present so teardown is explicit
    /// rather than a side effect of deallocation.
    public func remove() {
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    private func configureButton() {
        guard let button = statusItem.button else {
            // Documented as optional; in practice non-nil for a status item
            // created from NSStatusBar.system. Nothing to configure if it is
            // absent, and failing to launch over it would be worse than an
            // unlabelled item.
            return
        }
        let description = String(
            localized: "AgentBar",
            comment: "Accessibility label for the menu-bar item"
        )
        let image = NSImage(
            systemSymbolName: Self.placeholderSymbolName,
            accessibilityDescription: description
        )
        if let image {
            image.isTemplate = true
            button.image = image
        } else {
            // Symbol names can be withdrawn between macOS releases. A missing
            // glyph must not produce an invisible, unclickable status item.
            button.title = "AB"
        }
        button.setAccessibilityLabel(description)
    }

    private func makePlaceholderMenu() -> NSMenu {
        let menu = NSMenu()

        let status = NSMenuItem()
        status.title = String(
            localized: "AgentBar \(Self.shortVersion) — no sessions yet",
            comment: "Placeholder menu title shown before session monitoring exists"
        )
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: String(localized: "Quit AgentBar", comment: "Menu item that terminates the app"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }

    /// Stands in until step 05 delivers the state-dependent icon set.
    private static let placeholderSymbolName = "circle.dashed"

    private static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }
}
