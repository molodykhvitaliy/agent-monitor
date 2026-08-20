import AgentBarCore
import SwiftUI

/// The five steps' own content.
///
/// Separate from `OnboardingView`, which owns the shell — the material, the
/// transition between steps, the progress rail and the buttons. These are what
/// goes inside it, and each one is only about its own step.

/// Welcome. Teaches the location, and says three things about the product in one
/// line each.
struct WelcomeStepView: View {
    @Environment(\.accessibilityPreferences) private var accessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PointerToTheMenuBar()
                .padding(.bottom, DesignTokens.Space.large)

            Text(OnboardingStep.welcome.title)
                .font(DesignTokens.Text.panelTitle)
                .foregroundStyle(ColorToken.ink900.color)
            Text(OnboardingStep.welcome.explanation)
                .font(DesignTokens.Text.body)
                .foregroundStyle(accessibility.secondaryInk.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DesignTokens.Space.tiny)

            VStack(alignment: .leading, spacing: DesignTokens.Space.small) {
                ForEach(
                    Array(OnboardingStep.welcomeBullets.enumerated()), id: \.element
                ) { index, line in
                    HStack(alignment: .top, spacing: DesignTokens.Space.small) {
                        AgentGlyphView(state: bulletState(index), size: 14)
                        Text(line)
                            .font(DesignTokens.Text.caption)
                            .foregroundStyle(ColorToken.ink900.color)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    // Staggered at 0 / 70 / 140 ms when the step arrives, and
                    // not at all under Reduce Motion — the delay comes from the
                    // preferences so no view has to remember the rule.
                    //
                    // A **transition**, not an `onAppear` that raises an
                    // opacity. No animation in this app is load-bearing, and a
                    // line that starts invisible and waits for a lifecycle
                    // callback is a line that is missing whenever the callback
                    // does not come — offscreen rendering, a snapshot, a
                    // hosting view that is never added to a window.
                    .transition(
                        .opacity.combined(with: .offset(y: 8))
                            .animation(
                                accessibility.stepAnimation
                                    .delay(accessibility.stagger(index))))
                }
            }
            .padding(.top, DesignTokens.Space.large)
            Spacer(minLength: 0)
        }
    }

    /// Each line's mark is the state that line is about, which is cheaper to
    /// read than three identical dots and teaches the vocabulary in passing.
    private func bulletState(_ index: Int) -> SessionStateKind {
        switch index {
        case 0: .waiting
        case 1: .failed
        default: .working
        }
    }
}

/// `AgentBar lives here, in the menu bar`, with a hairline running up towards
/// the item the panel is hanging from.
///
/// The one piece of the flow whose whole job is a direction.
struct PointerToTheMenuBar: View {
    @Environment(\.accessibilityPreferences) private var accessibility
    @State private var breathing = false

    static let markSize: CGFloat = 34

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.tiny) {
            // A hairline rising out of the top of the mark and off the panel's
            // edge, towards the status item this whole surface is hanging from.
            // The one element here whose entire job is a direction.
            Rectangle()
                .fill(ColorToken.stateWorking.color.opacity(0.45))
                .frame(width: 1, height: 16)
                .padding(.leading, Self.markSize / 2)

            HStack(spacing: DesignTokens.Space.small) {
                ZStack {
                    Circle()
                        .fill(ColorToken.stateWorking.color.opacity(0.14))
                        .frame(width: Self.markSize, height: Self.markSize)
                        .scaleEffect(breathing ? 1 : 0.86)
                        .opacity(breathing ? 1 : 0.55)
                    AgentGlyphView(state: .working, size: 22)
                }
                .animation(
                    accessibility.runsCyclicalMotion
                        ? DesignTokens.Motion.animation(
                            DesignTokens.Motion.breathe, DesignTokens.Motion.cycle
                        ).repeatForever(autoreverses: true)
                        : nil,
                    value: breathing
                )
                .onAppear { breathing = accessibility.runsCyclicalMotion }

                Text(
                    "AgentBar lives here, in the menu bar",
                    comment: "Onboarding pointer label towards the status item"
                )
                .font(DesignTokens.Text.caption.weight(.semibold))
                .foregroundStyle(ColorToken.stateWorking.color)
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Step 4

/// The permission step. Shows a real banner before asking for anything.
struct NotificationStepView: View {
    @Bindable var model: OnboardingModel

    @Environment(\.accessibilityPreferences) private var accessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(OnboardingStep.notifications.title)
                .font(DesignTokens.Text.panelTitle)
                .foregroundStyle(ColorToken.ink900.color)
            if let subtitle = OnboardingStep.notifications.subtitle {
                Text(subtitle)
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(accessibility.secondaryInk.color)
            }
            Text(OnboardingStep.notifications.explanation)
                .font(DesignTokens.Text.body)
                .foregroundStyle(accessibility.secondaryInk.color)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DesignTokens.Space.medium)

            // Not an illustration of a banner: the real attachment art and the
            // real three-slot composition. The step promises "no surprises" and
            // a drawing would make that untrue.
            BannerPreview(
                verb: .question,
                provider: .claudeCode,
                project: "agentbar-web",
                detail: String(
                    localized: "Overwrite migration_003.sql?",
                    comment: "Example question line in the onboarding banner preview")
            )
            .padding(.top, DesignTokens.Space.medium)

            Text(
                "Only questions, errors and finished turns. You'll tune the rest later.",
                comment: "Caption under the onboarding banner preview"
            )
            .font(DesignTokens.Text.caption)
            .foregroundStyle(ColorToken.ink400.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, DesignTokens.Space.small)

            permissionRow
                .padding(.top, DesignTokens.Space.medium)
        }
    }

    /// The three faces of `NotificationPermission`, and the rule that governs
    /// the third: **a refusal is never re-asked.** macOS shows its prompt once
    /// per app and silently ignores a second request, so a button that re-asked
    /// would visibly do nothing.
    @ViewBuilder private var permissionRow: some View {
        switch model.permission {
        case .notAsked:
            OnboardingButton(
                title: String(
                    localized: "Allow notifications", comment: "Onboarding primary button"),
                isProminent: true,
                fillsWidth: true
            ) { Task { await model.requestPermission() } }
        case .granted, .quiet:
            HStack(spacing: DesignTokens.Space.small) {
                StateShapeView(
                    kind: .working, size: StateShapeView.footerSize(for: .working),
                    color: ColorToken.connected.color)
                Text("Allowed", comment: "Onboarding notification permission, granted")
                    .font(DesignTokens.Text.rowTitle)
                    .foregroundStyle(ColorToken.connected.color)
                Spacer(minLength: 0)
            }
        case .refused:
            VStack(alignment: .leading, spacing: DesignTokens.Space.small) {
                HStack(spacing: DesignTokens.Space.small) {
                    StateShapeView(
                        kind: .failed, size: StateShapeView.footerSize(for: .failed),
                        color: ColorToken.stateFailed.color)
                    Text(
                        "Denied in System Settings",
                        comment: "Onboarding notification permission, refused"
                    )
                    .font(DesignTokens.Text.rowTitle)
                    .foregroundStyle(ColorToken.stateFailed.color)
                    Spacer(minLength: 0)
                }
                OnboardingButton(
                    title: String(
                        localized: "Open System Settings", comment: "Onboarding button"),
                    isProminent: false
                ) { model.openSystemSettings() }
            }
        }
    }
}

// MARK: - Step 5

/// The summary. Honest about what was skipped, and quiet about it.
struct DoneStepView: View {
    @Bindable var model: OnboardingModel
    let onOpenSettings: () -> Void

    @Environment(\.accessibilityPreferences) private var accessibility

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DesignTokens.Space.medium) {
                // The one piece of theatre, and it is inside the card rather
                // than in the menu bar: a status item pulsing "waiting" while
                // nothing is waiting would be the app's first act being a lie.
                AgentGlyphView(state: .waiting, size: 34, animated: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(OnboardingStep.done.title)
                        .font(DesignTokens.Text.panelTitle)
                        .foregroundStyle(ColorToken.ink900.color)
                    Text(OnboardingStep.done.explanation)
                        .font(DesignTokens.Text.caption)
                        .foregroundStyle(accessibility.secondaryInk.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: DesignTokens.Space.small) {
                ForEach(model.summary) { line in
                    HStack(spacing: DesignTokens.Space.small) {
                        StateShapeView(
                            kind: line.isDone ? .working : .idle,
                            size: StateShapeView.footerSize(for: line.isDone ? .working : .idle),
                            color: line.isDone
                                ? ColorToken.connected.color : ColorToken.ink400.color)
                        Text(line.text)
                            .font(DesignTokens.Text.caption)
                            // A skipped line is quiet, never a fault. No red, no
                            // warning glyph, no "incomplete": the state is
                            // recoverable and the app says so by tone.
                            .foregroundStyle(
                                line.isDone
                                    ? ColorToken.ink900.color : accessibility.secondaryInk.color)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.top, DesignTokens.Space.large)

            Button {
                model.finish()
                onOpenSettings()
            } label: {
                Text("Details in Settings", comment: "Onboarding footer link")
                    .font(DesignTokens.Text.caption)
                    .foregroundStyle(ColorToken.stateWorking.color)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, DesignTokens.Space.medium)
        }
    }
}
