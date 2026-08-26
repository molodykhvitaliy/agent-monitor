import AgentBarCore
import SwiftUI

/// A live picture of what the settings below would produce.
///
/// The window used to open on a section, and the user toggled something and had
/// to imagine the result. This is the answer, and its one rule is the reason it
/// is worth having at all: **it is built from the code that ships.** The glyph
/// is `StatusItemGlyph`'s own image and the square is `EventAttachmentImage`'s
/// own art, so the preview cannot drift from the thing it previews. A preview
/// that can disagree with reality is worse than no preview.
///
/// It is a mirror, not a control: nothing here is pressable, nothing hovers, and
/// under Reduce Motion nothing moves.
struct SettingsPreviewView: View {
    let preview: NotificationPreview?

    @Environment(\.accessibilityPreferences) private var accessibility

    /// The strip standing in for the menu bar. The real one is 24 pt tall and
    /// this is drawn at that size rather than scaled, so the glyph is rendered
    /// at the size it will actually be seen at.
    static let stripHeight: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.medium) {
            strip
            if let preview {
                BannerPreview(
                    verb: preview.verb,
                    provider: preview.provider,
                    project: Self.exampleProject,
                    detail: detail(for: preview.verb),
                    soundName: preview.soundName)
            } else {
                nothingToShow
            }
        }
        .padding(DesignTokens.Space.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(desktop)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.card, style: .continuous)
                .strokeBorder(ColorToken.hairline.color, lineWidth: accessibility.hairlineWidth)
        }
        // A mirror, and only that. A preview a user can press is a second,
        // undocumented control surface.
        .allowsHitTesting(false)
        .accessibilityElement(children: .contain)
    }

    /// The menu bar, with the glyph the current settings would put in it.
    private var strip: some View {
        HStack(spacing: DesignTokens.Space.medium) {
            Spacer(minLength: 0)
            // The real template image, tinted the way AppKit tints it. Reusing
            // `StatusItemGlyph` rather than drawing the figure again is what
            // makes this incapable of showing a glyph the menu bar would not.
            Image(nsImage: StatusItemGlyph.image(for: glyphState))
                .renderingMode(.template)
                .foregroundStyle(ColorToken.onAccent.color)
            Text(Self.exampleClock)
                .font(DesignTokens.Text.caption.monospacedDigit())
                .foregroundStyle(ColorToken.onAccent.color)
        }
        .padding(.horizontal, DesignTokens.Space.small)
        .frame(height: Self.stripHeight)
        .frame(maxWidth: .infinity)
        .background(ColorToken.ink900.color.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    /// The state the previewed event would leave the menu bar in.
    ///
    /// `NotificationVerb.shape` and not the attachment's figure: this is the
    /// **session state** the event announces, which is exactly what the status
    /// item shows.
    private var glyphState: SessionStateKind { preview?.verb.shape ?? .idle }

    private var nothingToShow: some View {
        Text(
            "No events are switched on, so no banner will arrive.",
            comment: "Settings preview when every notification is disabled"
        )
        .font(DesignTokens.Text.caption)
        .foregroundStyle(accessibility.secondaryInk.color)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A desktop, suggested rather than drawn. Quiet enough that the strip and
    /// the banner are what the eye lands on.
    private var desktop: some View {
        LinearGradient(
            colors: [
                ColorToken.stateWorking.color.opacity(0.18),
                ColorToken.stateUnknown.color.opacity(0.14),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .background(ColorToken.canvas.color)
    }

    /// The two events that carry a line get one. It says what it is: a made-up
    /// question in a preview is still a made-up question, and the caption under
    /// the block already frames the whole thing as an example.
    private func detail(for verb: NotificationVerb) -> String? {
        switch verb {
        case .question:
            String(
                localized: "Overwrite migration_003.sql?",
                comment: "Example question line in the settings preview")
        case .failed:
            String(
                localized: "ModuleNotFoundError: pandas",
                comment: "Example failure line in the settings preview")
        case .approval:
            String(
                localized: "Run a command outside the sandbox?",
                comment: "Example approval line in the settings preview")
        case .waiting, .finished:
            nil
        }
    }

    /// Not a real project and not a real clock. Both are obviously examples, and
    /// naming a project the user actually has would suggest the preview is about
    /// something that happened.
    private static let exampleProject = "agentbar-web"
    private static let exampleClock = "9:41"
}
