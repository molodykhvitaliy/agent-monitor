import AgentBarCore
import SwiftUI

/// The settings window.
///
/// > **A surface `docs/dev/design-spec.md` deferred.** Step 05 reserved the
/// > footer gear for "the deferred settings screen" and left it unspecified;
/// > step 07 needs the sound matrix to be editable, so it lands here. It is
/// > deliberately built from **native form controls** rather than from the
/// > panel's glass vocabulary: a settings window is system chrome, macOS users
/// > know what one looks like, and inventing a second visual language for it
/// > would need the dark chip inks the design system says do not exist yet.
/// > What it does take from the design system is the type scale, the ink
/// > tokens, the provider badge and the state shapes — so a Waiting row in the
/// > matrix is recognisably the same Waiting as everywhere else.
public struct SettingsView: View {
    /// Internal rather than private: the sections in `SettingsSections.swift`
    /// are an extension of this type, and an extension in another file cannot
    /// see a private member.
    let model: SettingsModel

    @Environment(\.accessibilityPreferences) var accessibility

    public init(model: SettingsModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            permissionSection
            eventsSection
            quietHoursSection
            focusSection
            soundsSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 520)
        .task { await model.refresh() }
    }

    // MARK: - Permission

    /// Shown only when there is something wrong, and it is the first thing in
    /// the window when there is: every other setting is moot if macOS will not
    /// deliver.
    @ViewBuilder private var permissionSection: some View {
        if let problem = model.permission.problem {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Space.small) {
                    StateShapeView(
                        kind: .failed,
                        size: StateShapeView.rowSize(for: .failed),
                        color: ColorToken.stateFailed.color)
                    Text(problem)
                        .font(DesignTokens.Text.body)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DesignTokens.Space.small)
                    if model.permission.canRequest {
                        Button {
                            Task { await model.requestPermission() }
                        } label: {
                            Text("Allow…", comment: "Button that opens the system prompt")
                        }
                    } else {
                        Button(action: model.openSystemSettings) {
                            Text("Open System Settings", comment: "Button")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Events

    private var eventsSection: some View {
        Section {
            Toggle(
                isOn: Binding(
                    get: { model.preferences.isEnabled }, set: { model.setEnabled($0) })
            ) {
                Text("Send notifications", comment: "Global notification switch")
            }
            NotificationMatrixView(model: model)
            testRow
        } header: {
            sectionHeader(String(localized: "Events", comment: "Settings section"))
        } footer: {
            footnote(
                String(
                    localized: """
                        A burst of activity in one session produces one notification, not one \
                        per event.
                        """,
                    comment: "Explains notification coalescing"))
        }
    }

    /// The step's own validation criterion, handed to the user.
    private var testRow: some View {
        HStack(spacing: DesignTokens.Space.small) {
            ForEach(model.providers, id: \.self) { provider in
                Button {
                    Task { await model.sendTest(for: provider) }
                } label: {
                    Text(
                        "Test \(provider.displayName)",
                        comment: "Button that fires one notification per event")
                }
                // Not merely because the test would fail: a button whose whole
                // purpose is proving that notifications arrive must not be
                // pressable when it is known in advance that none can.
                .disabled(
                    model.isTesting != nil || !model.preferences.isEnabled
                        || !model.permission.canDeliver)
            }
            Spacer(minLength: DesignTokens.Space.small)
            if let message = model.lastMessage {
                Text(message.text)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(
                        message.isFault
                            ? ColorToken.stateFailed.color : accessibility.secondaryInk.color)
            }
        }
    }

    // MARK: - Shared pieces

    func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Text.sectionLabel)
            .textCase(.uppercase)
            .tracking(DesignTokens.Text.sectionLabelTracking)
            .foregroundStyle(accessibility.secondaryInk.color)
    }

    func footnote(_ text: String) -> some View {
        Text(text)
            .font(DesignTokens.Text.caption)
            .foregroundStyle(accessibility.secondaryInk.color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
