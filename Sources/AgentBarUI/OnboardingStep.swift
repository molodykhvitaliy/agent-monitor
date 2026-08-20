import AgentBarCore
import Foundation

/// The five steps of the first run, and everything they say.
///
/// > **Why there is a first-run flow at all, given the `Get Started` card.**
/// > They answer different questions. The card explains *why nothing is
/// > appearing right now* and is permanent, reachable from the footer at any
/// > time. This flow teaches *where the app lives* — which is the one thing a
/// > Dock-less, window-less menu-bar app most needs to teach and the one thing a
/// > card inside a panel the user has not learned to open cannot say.
///
/// The copy is here rather than in the view for the ordinary reason — a
/// localiser reads one file — and for one specific one: steps 2 and 3 write to
/// files the user owns, and what those steps promise about what is read and
/// where it lives is a claim the project has to be able to check in one place.
nonisolated public enum OnboardingStep: Int, CaseIterable, Sendable, Hashable, Identifiable {
    case welcome
    case claudeCode
    case codex
    case notifications
    case done

    public var id: Int { rawValue }

    /// 1-based, for `Step 3 of 5`.
    public var number: Int { rawValue + 1 }

    /// The provider this step installs, or `nil` for the three that install
    /// nothing. Used to reach the existing `IntegrationStatus` rather than to
    /// decide anything: every install fact comes from the report.
    public var provider: Provider? {
        switch self {
        case .claudeCode: .claudeCode
        case .codex: .codex
        case .welcome, .notifications, .done: nil
        }
    }

    /// Whether this step can be skipped. The first has its own wording for it
    /// and the last has nothing left to skip.
    public var isSkippable: Bool {
        switch self {
        case .claudeCode, .codex, .notifications: true
        case .welcome, .done: false
        }
    }

    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    /// The name in the progress label.
    public var name: String {
        switch self {
        case .welcome: String(localized: "Welcome", comment: "Onboarding step name")
        case .claudeCode: String(localized: "Claude Code", comment: "Onboarding step name")
        case .codex: String(localized: "Codex", comment: "Onboarding step name")
        case .notifications: String(localized: "Notifications", comment: "Onboarding step name")
        case .done: String(localized: "Done", comment: "Onboarding step name")
        }
    }

    public var title: String {
        switch self {
        case .welcome:
            String(localized: "Welcome to AgentBar", comment: "Onboarding step title")
        case .claudeCode:
            String(localized: "Connect Claude Code", comment: "Onboarding step title")
        case .codex:
            String(localized: "Connect Codex", comment: "Onboarding step title")
        case .notifications:
            String(localized: "Allow notifications", comment: "Onboarding step title")
        case .done:
            String(localized: "You're set", comment: "Onboarding step title")
        }
    }

    /// The one line under the title. Steps 2 and 3 use it to say the step is
    /// reversible **before** the user presses anything, which is where that
    /// belongs — not in a footnote and not behind a link.
    public var subtitle: String? {
        switch self {
        case .claudeCode:
            String(
                localized: "This step is reversible in one click",
                comment: "Onboarding step subtitle")
        case .codex:
            String(
                localized: "Two steps: install, then trust",
                comment: "Onboarding step subtitle")
        case .notifications:
            String(
                localized: "Otherwise an agent waits in silence",
                comment: "Onboarding step subtitle")
        case .welcome, .done:
            nil
        }
    }

    public var explanation: String {
        switch self {
        case .welcome:
            String(
                localized: """
                    Live status for Claude Code and Codex in your menu bar. No Dock icon, no \
                    window to keep open.
                    """,
                comment: "Onboarding step body")
        case .claudeCode:
            String(
                localized: """
                    AgentBar adds a small hook to the agent's configuration. Without it, Claude \
                    Code can't report a question or an error.
                    """,
                comment: "Onboarding step body")
        case .codex:
            String(
                localized: """
                    Codex won't run a hook until you've explicitly trusted it. That's its own \
                    safety rule — we just walk you through it.
                    """,
                comment: "Onboarding step body")
        case .notifications:
            String(
                localized: "Here's exactly what a banner will look like — no surprises:",
                comment: "Onboarding step body")
        case .done:
            String(
                localized: "The icon up there is live now — it's the app's main screen.",
                comment: "Onboarding step body")
        }
    }

    /// The two facts an install step owes the user, in the step itself.
    ///
    /// Rule 4 of the copy rules, and the one that is easiest to quietly drop:
    /// *name what is read and where it lives*. A step that writes into a file
    /// somebody owns says which file.
    public var facts: [String] {
        switch self {
        case .claudeCode:
            [
                String(
                    localized: "Reads status events only — never your code or your conversation",
                    comment: "Onboarding honesty fact"),
                String(
                    localized: "Lives in ~/.claude/settings.json",
                    comment: "Onboarding honesty fact"),
            ]
        case .codex:
            [
                String(
                    localized: "Reads status events only — never your code or your conversation",
                    comment: "Onboarding honesty fact"),
                String(
                    localized: "Lives in ~/.codex/hooks.json",
                    comment: "Onboarding honesty fact"),
            ]
        case .welcome, .notifications, .done:
            []
        }
    }

    /// The three capability lines on the welcome step. One line each, and no
    /// fourth: the step's job is teaching a location, not selling a feature set.
    public static let welcomeBullets: [String] = [
        String(
            localized: "The icon changes shape when an agent needs you",
            comment: "Onboarding capability line"),
        String(
            localized: "Notifications arrive with the question itself",
            comment: "Onboarding capability line"),
        String(
            localized: "Every session and quota in one list",
            comment: "Onboarding capability line"),
    ]

    /// `Step 3 of 5 · Codex`.
    public var progressLabel: String {
        String(
            localized: "Step \(number) of \(OnboardingStep.allCases.count) · \(name)",
            comment: "Onboarding progress label: index, total, step name")
    }
}
