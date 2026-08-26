import Foundation

/// What became of one thing AgentBar tried to undo.
///
/// Four outcomes, because the surface has to be able to render every one of
/// them: something was removed, there was nothing of AgentBar's to remove, the
/// removal did not happen, or AgentBar found something of its own that it is not
/// allowed to touch. The last two both carry an instruction the user can follow
/// by hand.
///
/// > **`failed` carries a remedy, and that is not decoration.** The rule this
/// > whole flow is built on is that AgentBar never guesses on the way out. If a
/// > hook is not where it was written, AgentBar does not go looking for
/// > something that resembles it and delete that — it reports the exact file it
/// > could not change and the exact thing the user should look for in it. A
/// > `failed` with no instruction would leave a user knowing only that something
/// > is still installed somewhere.
nonisolated public enum RemovalOutcome: Sendable, Hashable {
    /// Something was actually removed. The detail is a finished sentence — a
    /// backup path, a count — or `nil` when there is nothing to add.
    case removed(detail: String? = nil)
    /// Nothing of AgentBar's was there to remove. Not a failure, and it must
    /// never be painted as one: it is the outcome of removing twice, and of
    /// removing an integration that was never connected.
    case nothingToRemove
    /// The removal did not happen. `reason` says what went wrong in the words of
    /// whatever refused; `remedy` says what the user can do by hand.
    case failed(reason: String, remedy: String)
    /// AgentBar found something of its own and deliberately did not touch it,
    /// because touching it is outside what the installer is allowed to do.
    ///
    /// Distinct from `failed` on purpose: nothing went wrong, and counting it
    /// as a fault would make a clean removal report an unclean one for ever.
    /// It still carries a remedy, because the user is entitled to know what is
    /// left and how to be rid of it. `~/.codex/config.toml` is the case this
    /// exists for — Codex's record of the trust decision lives there, and
    /// AgentBar never writes that file.
    case leftAlone(reason: String, remedy: String)

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

/// One line of the removal report.
///
/// `location` is the path this step is about, spelled the way the user would
/// type it. It is on the step rather than folded into a sentence so the failure
/// line and the success line name the same file in the same place, and so a
/// remedy can be read without the sentence around it.
nonisolated public struct RemovalStep: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    public let location: String
    public let outcome: RemovalOutcome

    public init(id: String, title: String, location: String, outcome: RemovalOutcome) {
        self.id = id
        self.title = title
        self.location = location
        self.outcome = outcome
    }
}

/// Everything one removal did, in the order it did it.
///
/// > **Every step runs, whatever the step before it did.** A failure is
/// > recorded and the sequence carries on, because the alternative — stopping at
/// > the first refusal — leaves the user with a partly removed app and no list
/// > of what is still there. The one ordering that is load-bearing is stated
/// > where it is implemented: a provider's hooks come out before the file they
/// > name, so a hook that could not be removed still points at an executable
/// > that exists.
nonisolated public struct RemovalReport: Sendable, Hashable {
    public let steps: [RemovalStep]

    public init(steps: [RemovalStep]) {
        self.steps = steps
    }

    public var failures: [RemovalStep] { steps.filter(\.outcome.isFailure) }

    public var hasFailures: Bool { !failures.isEmpty }

    /// The one line above the list.
    ///
    /// Steps that removed nothing because removing it is not AgentBar's to do.
    /// Never counted as failures.
    public var leftAlone: [RemovalStep] {
        steps.filter {
            if case .leftAlone = $0.outcome { return true }
            return false
        }
    }

    /// Counts what is left rather than what succeeded: a user reading this has
    /// one question, which is whether they still have to do something.
    public var summary: String {
        let failed = failures.count
        guard failed > 0 else {
            return String(
                localized: """
                    AgentBar's hooks and files are gone. Both tools now behave exactly as if \
                    it had never been installed.
                    """,
                comment: "Removal finished with nothing left behind")
        }
        return String(
            localized: """
                \(failed) of \(steps.count) could not be removed. Each one below says where \
                it is and what to do about it.
                """,
            comment: "Removal finished with some steps needing the user")
    }
}
