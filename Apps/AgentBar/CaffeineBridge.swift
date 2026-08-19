import AgentBarPower
import AgentBarUI

/// Joins both interface seams to the power controller.
///
/// The assembly point's half of the Caffeine surfaces, and the third instance of
/// the same arrangement `ClaudeCodeIntegration` and `NotificationSettingsBridge`
/// already use: `AgentBarUI` may reach only `AgentBarCore`, so the two
/// vocabularies for the three modes are mapped here, where both modules are
/// already linked.
///
/// One bridge serves the panel footer and the settings window, so the button and
/// the picker cannot disagree about what Caffeine is doing. Both reach the same
/// `@Observable` controller, which is what makes both of them live.
@MainActor
final class CaffeineBridge {
    private let controller: CaffeineController

    init(controller: CaffeineController) {
        self.controller = controller
    }

    func indicator() -> CaffeineIndicator {
        let reading = controller.reading
        return CaffeineIndicator(
            setting: Self.setting(for: reading.mode),
            isHolding: reading.isHolding,
            workingSessionCount: reading.workingSessionCount,
            failure: reading.failure)
    }

    func toggle() {
        controller.toggle()
    }

    func set(_ setting: CaffeineSetting) {
        controller.setMode(Self.mode(for: setting))
    }

    // MARK: - Translation

    private static func setting(for mode: CaffeineMode) -> CaffeineSetting {
        switch mode {
        case .never: .never
        case .whileWorking: .whileWorking
        case .always: .always
        }
    }

    private static func mode(for setting: CaffeineSetting) -> CaffeineMode {
        switch setting {
        case .never: .never
        case .whileWorking: .whileWorking
        case .always: .always
        }
    }
}
