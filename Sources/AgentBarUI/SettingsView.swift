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
    /// The height of the window's transparent title bar, published by AppKit as
    /// a safe-area inset and read here so no view spells the number.
    ///
    /// > **`onGeometryChange`, never a `GeometryReader`.** A `GeometryReader` at
    /// > the root would take over this view's sizing, and this view's minimum
    /// > width is load-bearing — it is what stops the matrix being clipped, and
    /// > `SettingsWindowSizingTests` measures it by proposing one point of width.
    /// > `onGeometryChange` reads geometry without participating in layout, and
    /// > publishes only when the value changes; the inset changes once, at the
    /// > first pass. Publishing a *wobbling* measurement out of layout is what
    /// > cost the panel 98 % of a core, and this one cannot wobble.
    @State private var titleBarHeight: CGFloat = 0

    public init(model: SettingsModel) {
        self.model = model
    }

    /// > **A sidebar beside one continuous pane, not a pane switcher.** The two
    /// > readings of the mock were live for a while. `System Settings` switches
    /// > panes, and this window's brief is that native appearance outranks the
    /// > mock — but the mock draws every section in one scroll with the first
    /// > sidebar row lit, and the preview block's whole job is to sit *above
    /// > every section* rather than above one of them. Scrolling keeps both:
    /// > the sections stay one readable column with the preview at its head, and
    /// > the sidebar becomes a way to get to the bottom of it in one press.
    /// >
    /// > **The lit row is the last one pressed, and that is a deliberate
    /// > limit.** Making it follow the scroll position means measuring section
    /// > frames on every scrolled frame, and publishing a measurement out of
    /// > layout is precisely what once cost this app 98 % of a core in the panel.
    /// > A navigation list that is occasionally behind the scroll is a much
    /// > smaller problem than that.
    public var body: some View {
        ScrollViewReader { scroll in
            HStack(spacing: 0) {
                SettingsSidebar(selection: model.section, select: model.show)
                form
            }
            // Keyed on the whole request rather than on the section, so pressing
            // an already-lit row scrolls back to it — see `NavigationRequest`.
            // `initial: true` so the window can be *opened* on a section and not
            // only navigated to one, and so the claim "a sidebar row moves the
            // content" can be driven from outside the view rather than only by
            // a person with a mouse.
            .onChange(of: model.navigation, initial: true) { _, request in
                withAnimation(accessibility.stepAnimation) {
                    scroll.scrollTo(request.section, anchor: .top)
                }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.safeAreaInsets.top
            } action: {
                titleBarHeight = $0
            }
        }
        // Only a floor and a ceiling of infinity: the window fills whatever size
        // it has and the form scrolls when its content is taller. The floor is
        // the window's own minimum rather than a number chosen next to it —
        // when the two disagreed, SwiftUI laid the form out at *its* width and
        // let the overhang be clipped. See `SettingsWindowLayout`.
        .frame(
            minWidth: SettingsWindowLayout.minimum.width, maxWidth: .infinity,
            minHeight: SettingsWindowLayout.minimum.height, maxHeight: .infinity
        )
        .task { await model.refresh() }
    }

    /// The content pane: every section, in one scroll, on a solid fill.
    ///
    /// Still a grouped `Form`. The mock draws its own cards, and a grouped form
    /// already *is* that — `surface` fills separated by contrast rather than by
    /// divider lines, which is the elevation language the design asks for —
    /// while keeping the focus order, VoiceOver behaviour and control metrics
    /// that hand-drawn cards would have to rebuild.
    private var form: some View {
        Form {
            permissionSection
            previewSection
            eventsSection
            quietHoursSection
            focusSection
            soundsSection
            caffeineSection
            generalSection
            aboutSection
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The form draws on `canvas` so the sections read as cards separated by
        // fill contrast rather than by divider lines. The fill runs up behind
        // the transparent title bar for the same reason the sidebar's glass
        // does: content respects the safe area, surfaces do not.
        .scrollContentBackground(.hidden)
        .background { ColorToken.canvas.color.ignoresSafeArea(edges: .top) }
        // A scroll view extends *into* the safe area and insets its content
        // rather than stopping at it, so at rest the first heading sits below
        // the buttons but a scrolled row runs up to the window's top edge. With
        // no title bar to draw a material over it, what a user sees is a control
        // sliced in half against nothing. The same `canvas` the pane already
        // stands on, laid over that strip, turns it back into margin.
        .overlay(alignment: .top) { titleBarScrim }
    }

    /// Covers the title bar's height at the top of the content pane.
    ///
    /// Sized from the safe area rather than from a number: spelling AppKit's
    /// 32 pt here would be a system metric copied into a view, and
    /// `SettingsWindowChromeTests` asserts the window publishes one precisely so
    /// this does not have to guess. Height zero until the first geometry pass,
    /// which is a scrim over nothing rather than a wrong one.
    private var titleBarScrim: some View {
        ColorToken.canvas.color
            .frame(height: titleBarHeight)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
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

    // MARK: - Preview

    /// First, above every setting, because it is what every setting below is
    /// about. Built from `StatusItemGlyph` and `EventAttachmentImage` rather
    /// than from an imitation of them — see `SettingsPreviewView`.
    private var previewSection: some View {
        Section {
            SettingsPreviewView(preview: model.preview)
        } header: {
            sectionHeader(
                String(localized: "Preview", comment: "Settings section heading"),
                // The Notifications row lands here rather than on `Events`: the
                // preview is what the matrix under it is about, and a
                // navigation that skipped past it would hide the block whose
                // whole purpose is to be seen while the matrix is changed.
                anchor: .notifications)
        } footer: {
            footnote(
                String(
                    localized:
                        "How the menu bar and a banner look with your current settings.",
                    comment: "Settings preview explanation"))
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
            sectionHeader(unanchored: String(localized: "Events", comment: "Settings section"))
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

    /// A section heading and the scroll anchor the sidebar aims at.
    ///
    /// > **The anchor is on the heading, not on the `Section`.** A `Section` in a
    /// > grouped `Form` is a layout container rather than a view in the scroll's
    /// > own content, and an `.id` on one is not reliably what
    /// > `ScrollViewReader` finds. The heading is an ordinary `Text` inside the
    /// > scroll, it is the thing that should end up at the top edge, and it
    /// > cannot be laid out anywhere but where the section starts.
    ///
    /// The anchor is **not optional**, and `sectionHeader(unanchored:)` is a
    /// separate call rather than a default argument, so that a section added
    /// without one has to say so in as many words. `ScrollViewProxy.scrollTo`
    /// on an id nothing registered is a silent no-op: a sidebar row that
    /// scrolls nowhere would look like nothing at all had gone wrong.
    func sectionHeader(_ text: String, anchor: SettingsSection) -> some View {
        headingLabel(text).id(anchor)
    }

    /// A heading the sidebar does not point at. `Events` is the only one — it
    /// sits under the `Notifications` row together with the preview above it,
    /// and the row lands on the preview.
    func sectionHeader(unanchored text: String) -> some View {
        headingLabel(text)
    }

    private func headingLabel(_ text: String) -> some View {
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
