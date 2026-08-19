import AgentBarCore
import SwiftUI

/// The rest of the settings window: the three global controls and the general
/// section.
///
/// Split from `SettingsView` for length alone — one screen of form is one type
/// however many sections it has, and the sections share the window's model, its
/// accessibility environment and its two copy helpers.
extension SettingsView {

    // MARK: - Quiet hours

    var quietHoursSection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { model.preferences.quietHoursEnabled },
                    set: { model.setQuietHours(enabled: $0) })
            ) {
                Text("Quiet hours", comment: "Settings toggle")
            }
            HStack(spacing: DesignTokens.Space.medium) {
                hourPicker(
                    String(localized: "From", comment: "Quiet hours start"),
                    minute: model.preferences.quietStartMinute,
                    edge: .start)
                hourPicker(
                    String(localized: "Until", comment: "Quiet hours end"),
                    minute: model.preferences.quietEndMinute,
                    edge: .end)
            }
            .disabled(!model.preferences.quietHoursEnabled)
        } header: {
            sectionHeader(String(localized: "Quiet Hours", comment: "Settings section"))
        } footer: {
            footnote(
                String(
                    localized: """
                        A window that ends earlier than it starts crosses midnight. Setting both \
                        to the same time means no quiet hours at all.
                        """,
                    comment: "Explains the quiet-hours window"))
        }
    }

    enum QuietEdge {
        case start
        case end
    }

    /// Half-hour granularity: 48 entries is a menu a person can still scan, and
    /// nobody has ever needed their quiet hours to start at 22:17.
    ///
    /// Takes an edge rather than a setter closure: passing a main-actor-isolated
    /// method as a `Binding`'s `set` crashes the 6.3.3 compiler in IRGen, on a
    /// reabstraction thunk for the isolated function type. Naming the two cases
    /// costs four lines and needs no workaround comment at the call site.
    func hourPicker(_ label: String, minute: Int, edge: QuietEdge) -> some View {
        Picker(
            selection: Binding(
                get: { minute },
                set: { value in
                    switch edge {
                    case .start: model.setQuietHours(startMinute: value)
                    case .end: model.setQuietHours(endMinute: value)
                    }
                })
        ) {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { value in
                Text(value.clockFaceTime).tag(value)
            }
        } label: {
            Text(label)
        }
        .frame(maxWidth: 220)
    }

    // MARK: - Focus

    var focusSection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { model.preferences.focusSuppressionEnabled },
                    set: { model.setFocusSuppression(enabled: $0) })
            ) {
                Text("Stay quiet while these apps are frontmost", comment: "Settings toggle")
            }
            focusList
        } header: {
            sectionHeader(String(localized: "While You're Working", comment: "Settings section"))
        } footer: {
            footnote(
                String(
                    localized: """
                        AgentBar can see which application is frontmost, but not which project \
                        its window belongs to — so this silences every project, not just the one \
                        you are looking at.
                        """,
                    comment: "Explains the limits of focus suppression"))
        }
    }

    var focusList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
            ForEach(model.preferences.focusApplications) { application in
                HStack {
                    Text(application.name)
                        .font(DesignTokens.Text.body)
                    Text(application.bundleIdentifier)
                        .font(DesignTokens.Text.caption)
                        .foregroundStyle(accessibility.secondaryInk.color)
                    Spacer(minLength: DesignTokens.Space.small)
                    Button {
                        model.removeFocusApplication(application)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        String(
                            localized: "Remove \(application.name)",
                            comment: "Focus-suppression list button"))
                }
            }
            Button {
                Task { await model.addFocusApplication() }
            } label: {
                Text("Add Application…", comment: "Button")
            }
            .disabled(model.isPicking)
        }
        .disabled(!model.preferences.focusSuppressionEnabled)
    }

    // MARK: - Sounds

    var soundsSection: some View {
        Section {
            HStack(spacing: DesignTokens.Space.small) {
                Button {
                    Task { await model.addSound() }
                } label: {
                    Text("Add Sound File…", comment: "Button")
                }
                .disabled(model.isPicking)
                Button(action: model.revealSoundsFolder) {
                    Text("Reveal Sounds Folder", comment: "Button")
                }
            }
            ForEach(model.soundProblems, id: \.self) { problem in
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.small) {
                    StateShapeView(
                        kind: .failed,
                        size: StateShapeView.rowSize(for: .failed),
                        color: ColorToken.stateFailed.color)
                    Text(problem)
                        .font(DesignTokens.Text.caption)
                        .foregroundStyle(ColorToken.stateFailed.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            sectionHeader(String(localized: "Sounds", comment: "Settings section"))
        } footer: {
            footnote(
                String(
                    localized: """
                        macOS plays notification sounds only from AgentBar's own bundle and from \
                        your Sounds folder, so a file added here is copied there. Sounds must be \
                        .aiff, .wav or .caf, and shorter than 30 seconds.
                        """,
                    comment: "Explains where notification sounds must live"))
        }
    }

    // MARK: - General

    var generalSection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { model.launchAtLogin.isEnabled },
                    set: { model.launchAtLogin.set($0) })
            ) {
                Text("Launch at login", comment: "Settings toggle")
            }
            if let error = model.launchAtLogin.lastError {
                Text(error)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(ColorToken.stateFailed.color)
            }
        } header: {
            sectionHeader(String(localized: "General", comment: "Settings section"))
        } footer: {
            footnote(
                String(
                    localized: """
                        AgentBar has no Dock icon, so an app you have to start by hand every \
                        morning is one you stop using.
                        """,
                    comment: "Explains launch at login"))
        }
    }

}

extension SettingsView {

    // MARK: - Caffeine

    /// The full three-state control behind the footer's two-state button, and
    /// the only place with room for the limitation the brief requires stating.
    ///
    /// The status line is live: `model.caffeine` reaches an observable
    /// controller, so it follows the assertion rather than the window's last
    /// refresh. It is deliberately shown for every setting — a Caffeine that is
    /// off beside three working agents is exactly the situation a user opens
    /// this window to understand.
    var caffeineSection: some View {
        Section {
            Picker(
                selection: Binding(
                    get: { model.caffeine.setting },
                    set: { model.setCaffeine($0) })
            ) {
                ForEach(CaffeineSetting.allCases) { setting in
                    Text(setting.title).tag(setting)
                }
            } label: {
                Text("Keep the Mac awake", comment: "Caffeine picker label")
            }
            .pickerStyle(.inline)

            caffeineStatus
        } header: {
            sectionHeader(String(localized: "Caffeine", comment: "Settings section"))
        } footer: {
            footnote(CaffeineIndicator.limitation)
        }
    }

    /// One line, carrying the state shape as well as the sentence — the same
    /// rule the footer and every row follow, because colour never carries a
    /// state on its own.
    @ViewBuilder private var caffeineStatus: some View {
        let indicator = model.caffeine
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.small) {
            StateShapeView(
                kind: indicator.appearance == .failed ? .failed : .working,
                size: StateShapeView.rowSize(for: .working),
                color: (indicator.tint ?? .ink400).color)
            Text(indicator.summary)
                .font(DesignTokens.Text.caption)
                .foregroundStyle(
                    indicator.appearance == .failed
                        ? ColorToken.stateFailed.color : accessibility.secondaryInk.color
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
