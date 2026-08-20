import AgentBarCore
import SwiftUI

/// The first-run flow, drawn in the anchored panel.
///
/// > **The whole design rests on one decision: this hangs from the status
/// > item.** AgentBar has no Dock icon and no window, so the single most
/// > important thing a first launch has to teach is *where the app is*. A
/// > centred window that explains features teaches the wrong thing — the user
/// > reads about notifications, closes it, and then cannot find the app. Hanging
/// > the flow off the status item, with the item lit, puts the eye in the menu
/// > bar within the first second and the location is learned before any copy is
/// > read.
///
/// It is presented through `PanelController`, which already anchors, positions,
/// dismisses and draws the material. A second window class would have had to
/// reproduce all of that and would have landed somewhere other than where the
/// real panel lands, which is the entire pedagogical point.
public struct OnboardingView: View {
    @Bindable private var model: OnboardingModel
    private let onOpenSettings: () -> Void

    @Environment(\.accessibilityPreferences) private var accessibility

    /// Wider than the panel's 380: the steps carry more copy, and unlike the
    /// panel this surface is transient.
    public static let width: CGFloat = 420

    public init(model: OnboardingModel, onOpenSettings: @escaping () -> Void) {
        self.model = model
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            step
                // Keyed on the step so SwiftUI treats a change as a replacement
                // and runs the transition, rather than reconciling two steps
                // into one and animating the text.
                .id(model.step)
                .transition(stepTransition)
            ProgressRail(step: model.step)
                .padding(.top, DesignTokens.Space.xLarge)
            controls
                .padding(.top, DesignTokens.Space.medium)
        }
        .padding(.top, 26)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .frame(width: Self.width)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Radius.panel, style: .continuous)
                .strokeBorder(ColorToken.hairline.color, lineWidth: accessibility.hairlineWidth)
        }
        .animation(accessibility.stepAnimation, value: model.step)
        .task { await model.refresh() }
    }

    /// The same rule the panel follows: Reduce Transparency replaces the
    /// material with a flat `surface` fill at the same radius.
    @ViewBuilder private var background: some View {
        if accessibility.reduceTransparency {
            ColorToken.surface.color
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    /// A rise from +10 pt, or a plain cross-fade when movement is not wanted.
    private var stepTransition: AnyTransition {
        accessibility.reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .offset(y: 10).combined(with: .opacity),
                removal: .opacity)
    }

    // MARK: - Steps

    @ViewBuilder private var step: some View {
        switch model.step {
        case .welcome: WelcomeStepView()
        case .claudeCode, .codex: InstallStepView(model: model, step: model.step)
        case .notifications: NotificationStepView(model: model)
        case .done: DoneStepView(model: model, onOpenSettings: onOpenSettings)
        }
    }

    // MARK: - Controls

    /// Back, Skip, Next — and on the two ends, the wording the design asks for
    /// instead.
    @ViewBuilder private var controls: some View {
        switch model.step {
        case .welcome:
            VStack(spacing: DesignTokens.Space.small) {
                OnboardingButton(
                    title: String(localized: "Get started", comment: "Onboarding primary button"),
                    isProminent: true,
                    fillsWidth: true
                ) { Task { await model.next() } }
                Button {
                    Task { await model.skip() }
                } label: {
                    Text(
                        "Skip — I'll set this up later",
                        comment: "Onboarding button that ends the flow"
                    )
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(accessibility.secondaryInk.color)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        case .done:
            OnboardingButton(
                title: String(localized: "Open panel", comment: "Onboarding primary button"),
                isProminent: true,
                fillsWidth: true
            ) { model.finish() }
        case .claudeCode, .codex, .notifications:
            HStack(spacing: DesignTokens.Space.small) {
                if model.canGoBack {
                    OnboardingButton(
                        title: String(localized: "Back", comment: "Onboarding button"),
                        isProminent: false
                    ) { Task { await model.back() } }
                }
                Spacer(minLength: DesignTokens.Space.small)
                Button {
                    Task { await model.skip() }
                } label: {
                    Text("Skip", comment: "Onboarding button")
                        .font(DesignTokens.Text.caption)
                        .foregroundStyle(accessibility.secondaryInk.color)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                OnboardingButton(
                    title: String(localized: "Next", comment: "Onboarding button"),
                    isProminent: true
                ) { Task { await model.next() } }
            }
        }
    }
}

// MARK: - Chrome

/// Five segments and a label.
///
/// Segments rather than dots: dots do not communicate remaining length at a
/// glance, and five steps is enough that a user wants to know how much is left.
struct ProgressRail: View {
    let step: OnboardingStep

    @Environment(\.accessibilityPreferences) private var accessibility

    var body: some View {
        VStack(spacing: DesignTokens.Space.small) {
            HStack(spacing: 5) {
                ForEach(OnboardingStep.allCases) { candidate in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(
                            candidate.rawValue <= step.rawValue
                                ? ColorToken.stateWorking.color : ColorToken.fillQuiet.color
                        )
                        .frame(height: 3)
                }
            }
            .animation(accessibility.stepAnimation, value: step)
            Text(step.progressLabel)
                .font(DesignTokens.Text.caption)
                .foregroundStyle(accessibility.secondaryInk.color)
                .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.progressLabel)
    }
}

/// The flow's one button shape.
struct OnboardingButton: View {
    let title: String
    let isProminent: Bool
    /// The accent a prominent button takes. `Trust` is amber like every other
    /// Codex trust affordance in the app, and the card next door already makes
    /// that choice — this reads it rather than deciding again.
    var fill: ColorToken = .stateWorking
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(DesignTokens.Text.buttonLabel)
                .lineLimit(1)
                .foregroundStyle(
                    isProminent ? ColorToken.onAccent.color : ColorToken.ink900.color
                )
                .padding(.vertical, DesignTokens.Card.buttonVerticalPadding)
                .padding(.horizontal, DesignTokens.Card.buttonHorizontalPadding)
                .frame(maxWidth: fillsWidth ? .infinity : nil)
                .background(
                    isProminent ? fill.color : ColorToken.fillQuiet.color,
                    in: RoundedRectangle(cornerRadius: DesignTokens.Radius.button))
        }
        .buttonStyle(.plain)
    }
}
