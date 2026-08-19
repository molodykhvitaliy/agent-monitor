import Foundation
import Observation
import ServiceManagement
import os

/// Whether macOS starts AgentBar when the user logs in.
///
/// `SMAppService.mainApp` registers the app itself, which is the only form that
/// works for an `LSUIElement` app without a separate login-item helper bundle.
/// Registration is the user's decision and reversible from System Settings ›
/// General › Login Items, so the toggle here can find itself out of date — which
/// is why `refresh()` exists and why the read is the service's status rather
/// than a stored preference.
///
/// > It lives in the settings window's `General` section (step 07). A menu-bar
/// > app the user has to launch by hand every morning is not one they keep,
/// > which is why it was the first setting to exist and the reason the window
/// > has a `General` section for step 08's Caffeine to join.
@Observable
@MainActor
public final class LaunchAtLogin {
    private static let logger = Logger(
        subsystem: "com.molodykhvitalii.AgentBar", category: "login-item")

    public private(set) var isEnabled: Bool
    /// Set when the last change failed, so the caller can say so rather than
    /// silently showing the wrong state.
    public private(set) var lastError: String?

    public init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Re-reads the service's own status.
    ///
    /// Called from `SettingsModel.refresh()` — on the window appearing and every
    /// time the app becomes active again. The user can revoke the registration
    /// in System Settings › General › Login Items and AgentBar is not told, so a
    /// toggle read once at launch would offer to unregister something already
    /// unregistered.
    public func refresh() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters, and reports a failure rather than swallowing
    /// it. A refusal leaves the previous state, which `refresh()` then confirms.
    public func set(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = "\(error)"
            let verb = enabled ? "registered" : "unregistered"
            Self.logger.error(
                "login item could not be \(verb, privacy: .public): \(error, privacy: .public)")
        }
        refresh()
    }
}
