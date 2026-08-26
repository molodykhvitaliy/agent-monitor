import AgentBarUI
import AppKit
import Foundation

/// The settings window's two step-11 surfaces, joined to the app that assembles
/// them.
///
/// Split from the notification half of the bridge for length, and the split
/// falls where the subject changes: everything here is about the app's own
/// health and the app's own removal rather than about what it sends.
extension NotificationSettingsBridge {

    // MARK: - Diagnostics

    func diagnostics() async -> DiagnosticsReport {
        guard let diagnostics else {
            return DiagnosticsReport(
                checks: [
                    DiagnosticsCheck(
                        id: "unavailable",
                        title: String(localized: "Self-test", comment: "Self-test check"),
                        verdict: .fail,
                        detail: String(
                            localized: "not wired up in this build",
                            comment: "Self-test detail when diagnostics are absent"))
                ],
                counters: [], recent: [], resources: "", takenAt: Date())
        }
        return await diagnostics.report()
    }

    func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Removal

    func removeEverything() async -> RemovalReport {
        guard let removal else {
            return RemovalReport(steps: [
                RemovalStep(
                    id: "unavailable",
                    title: String(localized: "Removal", comment: "Removal step"),
                    location: "—",
                    outcome: .failed(
                        reason: String(
                            localized: "This build of AgentBar has no uninstaller wired up",
                            comment: "The removal service is absent"),
                        remedy: String(
                            localized: """
                                Remove the AgentBar entries from ~/.claude/settings.json and \
                                ~/.codex/hooks.json by hand, then delete \
                                ~/Library/Application Support/AgentBar.
                                """,
                            comment: "How to uninstall by hand when the service is absent")))
            ])
        }
        return await removal.removeEverything()
    }

    /// Shows the running application in the Finder. Never deletes it: a running
    /// app unlinking its own bundle is a trick, and the last step of an
    /// uninstall belongs to the person doing it.
    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func quitApplication() {
        NSApp.terminate(nil)
    }

    // MARK: - Caffeine

    func caffeine() -> CaffeineIndicator { caffeineBridge.indicator() }

    func setCaffeine(_ setting: CaffeineSetting) { caffeineBridge.set(setting) }
}
