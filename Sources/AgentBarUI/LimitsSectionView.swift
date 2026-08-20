import AgentBarCore
import SwiftUI

/// Subscription limits, **grouped under the service each one belongs to**:
/// whatever windows a provider reported, then the permanent Claude Code note.
///
/// > **Why the provider is named.** The section used to render a bare `Weekly`
/// > with a bar under it and nothing saying whose week it was. With two
/// > providers installed that is a question the panel refused to answer, and
/// > the answer matters most in the case the section exists for — a bar close
/// > to full tells you nothing if you do not know which subscription is nearly
/// > spent. Every group is headed by its provider's badge and name, and the
/// > Claude Code group says plainly that no limits are available there.
///
/// The Claude Code group never disappears, so the section is never absent —
/// which is why *All quiet* still has one.
public struct LimitsSectionView: View {
    private let windows: [UsageWindow]
    private let now: Date

    @Environment(\.accessibilityPreferences) private var accessibility
    @State private var showsExplanation = false

    /// Codex first, because it is the half with numbers in it; the Claude Code
    /// group is a note about the section rather than its headline, and a note
    /// belongs at the bottom. A presentation order, deliberately not
    /// `Provider.allCases` — that one is declaration order, which puts Claude
    /// Code first for reasons that have nothing to do with this section.
    static let providerOrder: [Provider] = [.codex, .claudeCode]

    public init(windows: [UsageWindow], now: Date = Date()) {
        self.windows = windows
        self.now = now
    }

    /// One entry per provider with something to show.
    ///
    /// A provider that reported no windows is **absent** rather than empty: no
    /// reading is not an error and gets no error styling, and a heading over
    /// nothing would be a fault report the section is not making. Claude Code
    /// is the exception in the other direction — it never reports windows and
    /// its note is permanent, so its heading is permanent too.
    ///
    /// A function on the type rather than a computed property in the body, so
    /// the rule can be tested without rendering anything.
    static func groups(from windows: [UsageWindow]) -> [LimitsGroup] {
        providerOrder.compactMap { provider in
            let reported = windows.filter { $0.provider == provider }
            guard !reported.isEmpty || provider == .claudeCode else { return nil }
            return LimitsGroup(provider: provider, windows: reported)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Limits", comment: "Section header").uppercased())
                .font(DesignTokens.Text.sectionLabel)
                .tracking(DesignTokens.Text.sectionLabelTracking)
                .foregroundStyle(accessibility.secondaryInk.color)
                .padding(.bottom, DesignTokens.Limits.labelMargin)

            // Keyed on position, not on the provider: the order is fixed and
            // the list is two long at most.
            ForEach(Array(Self.groups(from: windows).enumerated()), id: \.offset) { index, group in
                providerGroup(group.provider, windows: group.windows)
                    .padding(.top, index == 0 ? 0 : DesignTokens.Limits.providerSpacing)
            }
        }
        .padding(.horizontal, DesignTokens.Limits.sidePadding)
        .padding(.bottom, DesignTokens.Limits.bottomPadding)
    }

    /// One provider's heading and everything reported under it.
    private func providerGroup(
        _ provider: Provider, windows: [UsageWindow]
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignTokens.Limits.providerHeaderMargin) {
            HStack(spacing: DesignTokens.Limits.providerGap) {
                ProviderBadge(provider: provider, size: DesignTokens.Limits.providerBadgeSize)
                Text(provider.displayName)
                    .font(DesignTokens.Text.rowTitle)
                    .foregroundStyle(ColorToken.ink900.color)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: DesignTokens.Limits.bucketSpacing) {
                // A repeating component: one row per window, never a fixed
                // layout. Keyed on position, not on the window's name — see
                // `UsageWindow`.
                ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                    UsageWindowRow(window: window, now: now)
                }
                if provider == .claudeCode {
                    claudeCodeCaveat
                }
            }
            // Lines up with the heading's text rather than with its badge.
            .padding(.leading, DesignTokens.Limits.providerIndent)
        }
        // The whole Claude Code group is the quietest thing in the panel, not
        // only its sentence: naming the provider is what the group is for, but
        // a full-emphasis heading over a permanent "nothing here" would give
        // the half with no numbers more weight than the half with them.
        //
        // Except under Increase Contrast, where it is drawn at full strength.
        // The spec's 70 % is a de-emphasis, and this element is permanent —
        // dimming it unconditionally would mean a user who asked the system for
        // more contrast permanently gets less of it on the one row that never
        // goes away. The design system's rule is that secondary is promoted,
        // not that it is promoted everywhere except here.
        .opacity(
            provider == .claudeCode && !accessibility.increaseContrast
                ? DesignTokens.Limits.caveatOpacity : 1)
    }

    /// The lowest-emphasis element in the panel, and permanent correct
    /// behaviour rather than a fault: there is no supported way to read Claude
    /// Code's remaining usage, and AgentBar never contacts Anthropic to find out
    /// (ADR-0002). No bar, no zero, no error colour, no retry, and no log line.
    ///
    /// Present tense throughout — nothing here may read as a transient outage —
    /// and `Unknown` is not reused, because it is reserved for session state.
    /// **"Not supported", never "not supported yet".** The provider's name is
    /// carried by the heading above rather than repeated in the sentence.
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
                        localized: "Not supported — remaining quota isn't reported",
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
    }
}

/// One provider's share of the Limits section.
struct LimitsGroup: Equatable {
    let provider: Provider
    let windows: [UsageWindow]
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
