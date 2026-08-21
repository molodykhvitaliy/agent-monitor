import SwiftUI

/// The sections of the settings window, in the order they appear.
///
/// One case per section rather than a free-form list, because the enum is what
/// joins the two halves of this window: the sidebar builds a row from each case
/// and the content pane anchors a section to it.
///
/// > **The join is enforced at one end and only argued at the other.** A new case
/// > must give a `title` and a `symbol` — the `switch`es see to that — and gets a
/// > sidebar row for free. Nothing makes it give the content pane an anchor.
/// > What stands in for that is `SettingsView.sectionHeader(_:anchor:)` taking a
/// > **non-optional** anchor, with a separately named `sectionHeader(unanchored:)`
/// > for the one heading that has none, so skipping it has to be written out
/// > rather than defaulted into. Worth knowing why it matters:
/// > `ScrollViewProxy.scrollTo` on an id nothing registered is a silent no-op, so
/// > the failure is a row that quietly does nothing.
///
/// The permission banner deliberately has **no** case. It is conditional, it is
/// not a place a user navigates to, and giving it a sidebar row would mean a row
/// that is usually absent — the one thing a fixed navigation list must not be.
public enum SettingsSection: String, CaseIterable, Identifiable, Sendable {
    case notifications
    case quietHours
    case focus
    case sounds
    case caffeine
    case general
    case about

    public var id: String { rawValue }

    /// The sidebar's label. Every case but one is also the content pane's own
    /// section header, taken from here so the two cannot drift apart; the
    /// exception is `notifications`, which names the pair of sections a user
    /// thinks of as one — the preview and the event matrix it mirrors.
    var title: String {
        switch self {
        case .notifications:
            String(localized: "Notifications", comment: "Settings section")
        case .quietHours:
            String(localized: "Quiet Hours", comment: "Settings section")
        case .focus:
            String(localized: "While You're Working", comment: "Settings section")
        case .sounds:
            String(localized: "Sounds", comment: "Settings section")
        case .caffeine:
            String(localized: "Caffeine", comment: "Settings section")
        case .general:
            String(localized: "General", comment: "Settings section")
        case .about:
            String(localized: "About", comment: "Settings section")
        }
    }

    /// SF Symbols rather than the mock's hand-drawn glyphs, and deliberately.
    /// The design brief for this window is that **native appearance outranks the
    /// mock**; a settings sidebar is the most conventional list in macOS, and
    /// symbols the user already recognises beat five bespoke figures that mean
    /// the same things.
    var symbol: String {
        switch self {
        case .notifications: "bell"
        case .quietHours: "moon"
        case .focus: "macwindow"
        case .sounds: "speaker.wave.2"
        case .caffeine: "cup.and.saucer"
        case .general: "gearshape"
        case .about: "info.circle"
        }
    }
}

/// The settings window's navigation: a narrow translucent column of sections.
///
/// > **Glass here and nowhere else in this window.** Long lists of settings text
/// > over a blurred backdrop are measurably harder to read, and the content pane
/// > has no reason to show what is behind the window. The sidebar is narrow,
/// > mostly empty, and is the one place a translucent edge actually looks like
/// > macOS — which is also where the traffic lights sit, since the window's
/// > title bar is transparent and the sidebar runs up underneath it.
///
/// Under Reduce Transparency it becomes a flat `surface` fill, the same rule
/// `AccessibilityPreferences.reduceTransparency` already drives for the panel.
struct SettingsSidebar: View {
    /// Which row is lit.
    let selection: SettingsSection
    /// Called on **every** press, including a press on the already-lit row — a
    /// binding would swallow that one, and it is the gesture a user reaches for
    /// after scrolling away by hand. See `NavigationRequest`.
    ///
    /// `@MainActor` rather than a plain function value, because the one caller
    /// passes `model.show` — a `@MainActor` method — directly. A plain type
    /// would still compile by erasing that, and `SettingsSections.hourPicker`
    /// next door documents a 6.3.3 IRGen crash on precisely an erased isolated
    /// method; stating the isolation here is what keeps this call site off that
    /// path rather than merely happening not to hit it.
    let select: @MainActor (SettingsSection) -> Void

    @Environment(\.accessibilityPreferences) private var accessibility
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: SettingsSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mark
            Rectangle()
                .fill(ColorToken.divider.color)
                .frame(height: accessibility.hairlineWidth)
                .padding(.horizontal, DesignTokens.SettingsSidebar.itemInset)
                .padding(.bottom, DesignTokens.Space.small)
            ForEach(SettingsSection.allCases) { section in
                row(for: section)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.SettingsSidebar.sidePadding)
        .padding(.bottom, DesignTokens.SettingsSidebar.sidePadding)
        // The traffic lights live on this surface rather than on a title bar of
        // their own. The room for them comes from the window's safe area, which
        // SwiftUI has already taken out of this view's height; this is only the
        // gap between them and the mark.
        .padding(.top, DesignTokens.SettingsSidebar.markTopPadding)
        .frame(width: DesignTokens.SettingsSidebar.width, alignment: .leading)
        .frame(maxHeight: .infinity)
        // The glass runs to the very top of the window, behind the buttons —
        // the content above respects the safe area, the surface under it does
        // not. Without this the traffic lights sit on a bare strip and the
        // sidebar starts an inch down the window.
        .background { background.ignoresSafeArea(edges: .top) }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(ColorToken.hairline.color)
                .frame(width: accessibility.hairlineWidth)
                .ignoresSafeArea(edges: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Settings sections", comment: "Sidebar, spoken"))
    }

    @ViewBuilder private var background: some View {
        if accessibility.reduceTransparency {
            ColorToken.surface.color
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    /// The app's own figure and its name, which is what the transparent title
    /// bar took away.
    private var mark: some View {
        HStack(spacing: DesignTokens.Space.small) {
            AgentGlyphView(state: .idle, size: DesignTokens.SettingsSidebar.markSize)
            Text(verbatim: "AgentBar")
                .font(DesignTokens.Text.rowTitle.weight(.semibold))
                .foregroundStyle(ColorToken.ink900.color)
        }
        .padding(.horizontal, DesignTokens.SettingsSidebar.itemInset)
        .padding(.bottom, DesignTokens.Space.medium)
        .accessibilityHidden(true)
    }

    private func row(for section: SettingsSection) -> some View {
        Button {
            select(section)
        } label: {
            HStack(spacing: DesignTokens.SettingsSidebar.symbolGap) {
                Image(systemName: section.symbol)
                    .font(.system(size: DesignTokens.SettingsSidebar.symbolPointSize))
                    .frame(
                        width: DesignTokens.SettingsSidebar.symbolBox,
                        height: DesignTokens.SettingsSidebar.symbolBox)
                Text(section.title)
                    .font(DesignTokens.Text.rowTitle)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ink(for: section))
            .padding(.vertical, DesignTokens.SettingsSidebar.itemVerticalPadding)
            .padding(.horizontal, DesignTokens.SettingsSidebar.itemInset)
        }
        .buttonStyle(SidebarRowButtonStyle(fill: fill(for: section)))
        .padding(.bottom, DesignTokens.SettingsSidebar.itemSpacing)
        .onHover { hovered = $0 ? section : (hovered == section ? nil : hovered) }
        .accessibilityAddTraits(selection == section ? [.isButton, .isSelected] : .isButton)
    }

    /// Selected rows take the accent; everything else stays text-coloured. The
    /// selection is never carried by colour alone — the fill behind it is the
    /// other half, and both change together.
    private func ink(for section: SettingsSection) -> Color {
        selection == section ? ColorToken.stateWorking.color : ColorToken.ink900.color
    }

    private func fill(for section: SettingsSection) -> Color {
        if selection == section {
            ColorToken.stateWorking.color.opacity(
                colorScheme == .dark
                    ? DesignTokens.SettingsSidebar.selectionFillDark
                    : DesignTokens.SettingsSidebar.selectionFillLight)
        } else if hovered == section {
            ColorToken.hoverOverlay.color
        } else {
            .clear
        }
    }
}

/// The pill behind a sidebar row, and the ring around a focused one.
///
/// A style rather than modifiers on the label, for the reason
/// `SessionRowButtonStyle` is one: `@Environment(\.isFocused)` reports the
/// button's focus only from inside a `ButtonStyle`. `.plain` draws no focus
/// indication of its own, and this is the one hand-rolled navigation list in a
/// window whose stated reason for using native controls is that they inherit
/// Full Keyboard Access — a list a keyboard user cannot see their place in would
/// take that reason away from the one control that needed it.
private struct SidebarRowButtonStyle: ButtonStyle {
    /// Selection and hover, already resolved to one colour by the caller: they
    /// are mutually exclusive here, and a style that recomputed them would be a
    /// second place deciding what a lit row looks like.
    let fill: Color

    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: DesignTokens.SettingsSidebar.itemRadius, style: .continuous)
        return
            configuration.label
            .background(fill, in: shape)
            .background(
                // A press reads as a press even on the row that is already lit,
                // which is a real gesture here: it scrolls back to the section.
                configuration.isPressed ? ColorToken.hoverOverlay.color : .clear, in: shape
            )
            .overlay {
                // The system accent, not `stateWorking`: a focus ring is macOS's
                // to colour, and ours happens to be a blue that would read as
                // part of the selection rather than as focus.
                shape.strokeBorder(
                    isFocused ? Color(nsColor: .controlAccentColor) : .clear,
                    lineWidth: DesignTokens.Row.focusRingWidth)
            }
            .contentShape(shape)
    }
}
