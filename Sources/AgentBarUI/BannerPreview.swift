import AgentBarCore
import SwiftUI

/// An approximation of a delivered banner, for the two surfaces that have to
/// show one before it exists: the onboarding's permission step and the settings
/// window's preview.
///
/// > **Approximate, and it should look it.** macOS draws the real banner and
/// > nothing about its material, fonts, radius, text colours or dwell time is
/// > exposed. Chasing pixel fidelity here would produce something that is wrong
/// > in a way a user could file a bug about. What this *is* accurate about is
/// > the four things that genuinely are AgentBar's decisions — the attachment
/// > art, the three text slots, the grouping, and the sound — because those are
/// > drawn by the same code that ships them.
struct BannerPreview: View {
    let verb: NotificationVerb
    let provider: Provider
    let project: String
    let detail: String?
    /// The sound the matrix currently names, or `nil` for silence. Shown as a
    /// quiet trailing line, because a banner's sound is a decision with no
    /// visual and would otherwise be the one setting a preview cannot show.
    var soundName: String?

    @Environment(\.accessibilityPreferences) private var accessibility

    static let artSize: CGFloat = 38
    static let iconSize: CGFloat = 26

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Row.badgeGap) {
            appMark
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DesignTokens.Text.rowTitle)
                    .foregroundStyle(ColorToken.ink900.color)
                    .lineLimit(1)
                Text(provider.displayName)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(accessibility.secondaryInk.color)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(DesignTokens.Text.caption)
                        .foregroundStyle(accessibility.secondaryInk.color)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let soundName {
                    Label(soundName, systemImage: "speaker.wave.2")
                        .font(DesignTokens.Text.caption)
                        .foregroundStyle(ColorToken.ink400.color)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: DesignTokens.Space.small)
            art
        }
        .padding(DesignTokens.Space.medium)
        .background(
            ColorToken.surface.color,
            in: RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(ColorToken.hairline.color, lineWidth: accessibility.hairlineWidth)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                localized: "Example notification: \(title), \(provider.displayName)",
                comment: "Accessibility label for the banner preview"))
    }

    /// `{Verb} · {project}` — the real composition, from the same rule the
    /// router uses. The separator comes from `DesignTokens` so it cannot drift
    /// into a hyphen here while staying a middle dot there.
    private var title: String { verb.title + DesignTokens.separator + project }

    /// The banner's leading slot is always the app's own icon and cannot be
    /// replaced — which is exactly why the attachment carries the event instead.
    /// Drawn as the mark rather than fetched from the bundle: this view is
    /// rendered in tests and in a render proof, neither of which has an icon.
    private var appMark: some View {
        RoundedRectangle(cornerRadius: DesignTokens.Row.badgeRadius, style: .continuous)
            .fill(ColorToken.ink900.color)
            .frame(width: Self.iconSize, height: Self.iconSize)
            .overlay {
                AgentGlyphView(
                    state: .working, size: Self.iconSize * 0.72,
                    tint: ColorToken.onAccent.color)
            }
            .accessibilityHidden(true)
    }

    /// The real attachment art, never an imitation of it. A preview that can
    /// disagree with what is delivered is worse than no preview.
    private var art: some View {
        EventAttachmentArt(verb: verb, size: Self.artSize)
            .clipShape(
                RoundedRectangle(cornerRadius: DesignTokens.Row.badgeRadius, style: .continuous)
            )
            .frame(width: Self.artSize, height: Self.artSize)
            .accessibilityHidden(true)
    }
}
