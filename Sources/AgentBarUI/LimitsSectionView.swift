import SwiftUI

/// Subscription limits: whatever windows the provider reported, then the
/// permanent Claude Code caveat.
///
/// The caveat row never disappears, so the section is never absent — which is
/// why *All quiet* still has one.
public struct LimitsSectionView: View {
    private let windows: [UsageWindow]
    private let now: Date

    @Environment(\.accessibilityPreferences) private var accessibility
    @State private var showsExplanation = false

    public init(windows: [UsageWindow], now: Date = Date()) {
        self.windows = windows
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Limits", comment: "Section header").uppercased())
                .font(DesignTokens.Text.sectionLabel)
                .tracking(DesignTokens.Text.sectionLabelTracking)
                .foregroundStyle(accessibility.secondaryInk.color)
                .padding(.bottom, DesignTokens.Limits.labelMargin)

            // A repeating component: one row per window, never a fixed layout.
            // No windows at all is not an error and gets no error styling — the
            // provider's half of the section is simply absent.
            // Keyed on position, not on the window's name — see `UsageWindow`.
            ForEach(Array(windows.enumerated()), id: \.offset) { index, window in
                UsageWindowRow(window: window, now: now)
                    .padding(.top, index == 0 ? 0 : DesignTokens.Limits.bucketSpacing)
            }
            if !windows.isEmpty {
                Spacer().frame(height: DesignTokens.Limits.bucketSpacing)
            }

            claudeCodeCaveat
        }
        .padding(.horizontal, DesignTokens.Limits.sidePadding)
        .padding(.bottom, DesignTokens.Limits.bottomPadding)
    }

    /// The lowest-emphasis element in the panel, and permanent correct
    /// behaviour rather than a fault: there is no supported way to read Claude
    /// Code's remaining usage, and AgentBar never contacts Anthropic to find out
    /// (ADR-0002). No bar, no zero, no error colour, no retry, and no log line.
    ///
    /// Present tense throughout — nothing here may read as a transient outage —
    /// and `Unknown` is not reused, because it is reserved for session state.
    private var claudeCodeCaveat: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
            HStack(spacing: DesignTokens.Limits.infoGlyphGap) {
                Button {
                    showsExplanation.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: DesignTokens.Limits.infoGlyphSize))
                        .foregroundStyle(ColorToken.ink400.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(
                        localized: "About Claude Code limits",
                        comment: "Accessibility label for the limits explanation"))

                Text(
                    String(
                        localized: "Claude Code doesn't report remaining quota",
                        comment: "Permanent note in the Limits section")
                )
                .font(DesignTokens.Text.caption)
                .foregroundStyle(ColorToken.ink400.color)
                Spacer(minLength: 0)
            }
            if showsExplanation {
                Text(
                    String(
                        localized: """
                            Claude Code provides no supported way to read remaining usage, \
                            and AgentBar never contacts Anthropic to find out.
                            """,
                        comment: "Explanation revealed by the limits info glyph")
                )
                .font(DesignTokens.Text.caption)
                .foregroundStyle(ColorToken.ink400.color)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .opacity(DesignTokens.Limits.caveatOpacity)
    }
}

/// One usage window. Every field degrades by omission, never by a placeholder.
struct UsageWindowRow: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Limits.barSpacing) {
            HStack(spacing: DesignTokens.Space.small) {
                Text(window.displayName)
                    .font(DesignTokens.Text.caption.weight(.medium))
                    .foregroundStyle(ColorToken.ink900.color)
                Spacer(minLength: DesignTokens.Space.tiny)
                if let meta = window.meta(now: now) {
                    Text(meta)
                        .font(DesignTokens.Text.caption.monospacedDigit())
                        .foregroundStyle(ColorToken.ink400.color)
                }
            }
            // No percentage means no bar at all. A bar drawn at zero would claim
            // something the provider did not say.
            if let fraction = window.fractionUsed {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(ColorToken.meterTrack.color)
                        Capsule()
                            .fill(ColorToken.meterFill.color)
                            .frame(width: proxy.size.width * max(0, min(1, fraction)))
                    }
                }
                .frame(height: DesignTokens.Limits.barHeight)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
