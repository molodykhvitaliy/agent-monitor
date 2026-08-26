import AgentBarCore
import Foundation
import Testing

@testable import AgentBarNotifications

/// The verb table from `docs/dev/design-spec.md` § Notifications, asserted case
/// by case.
///
/// This is where a mistake either wakes someone for nothing or fails to wake
/// them at all, so every row of the table gets a test — including the two that
/// must fire nothing, which are the ones a reader would otherwise assume are
/// covered by the others.
@Suite("Notification policy")
struct PolicyTests {

    @Test("A finished turn is Finished, with no body")
    func finished() throws {
        let draft = try #require(
            NotificationPolicy.draft(for: Fixture.change(from: .working, to: .idle)))
        #expect(draft.event == .finished)
        #expect(draft.body == nil)
    }

    /// The store adopted a session it had not seen — AgentBar launching beside
    /// an agent already running. It produces `nil → idle`, which would otherwise
    /// announce a turn that never happened here.
    @Test("A session the store adopted fires nothing")
    func adoptionIsSilent() {
        #expect(NotificationPolicy.draft(for: Fixture.change(from: nil, to: .idle)) == nil)
        #expect(
            NotificationPolicy.draft(for: Fixture.change(from: nil, to: .failed(reason: "x")))
                == nil)
    }

    /// `sessionEnded`, or the watchdog evicting it. Neither is news.
    @Test("A session leaving the store fires nothing")
    func departureIsSilent() {
        #expect(NotificationPolicy.draft(for: Fixture.change(from: .working, to: nil)) == nil)
    }

    @Test("Working and unknown fire nothing")
    func silentDestinations() {
        #expect(NotificationPolicy.draft(for: Fixture.change(from: .idle, to: .working)) == nil)
        #expect(NotificationPolicy.draft(for: Fixture.change(from: .working, to: .unknown)) == nil)
    }

    /// ADR-0005: the verb is chosen by the presence of the question line, not by
    /// the event, because both waiting paths decode to the same `EventKind`.
    @Test("A waiting session with a question line is a Question")
    func questionNeedsTheLine() throws {
        let asked = try #require(
            NotificationPolicy.draft(
                for: Fixture.change(to: .waitingInput(question: "Which branch should I use?"))))
        #expect(asked.event == .question)
        #expect(asked.body == "Which branch should I use?")

        let bare = try #require(
            NotificationPolicy.draft(for: Fixture.change(to: .waitingInput(question: nil))))
        #expect(bare.event == .waiting)
        #expect(bare.body == nil)
    }

    /// The verb and the body are one decision asked twice, so they cannot
    /// disagree. The adapter refuses only an *empty* question, and a line of
    /// nothing but spaces survives that and then clamps away to nothing — which
    /// would title a banner `Question` and give it no question.
    @Test("A question line that clamps away to nothing is a bare Waiting")
    func blankQuestionIsNotAQuestion() throws {
        for blank in ["", "   ", "\n\t "] {
            let draft = try #require(
                NotificationPolicy.draft(for: Fixture.change(to: .waitingInput(question: blank))))
            #expect(draft.event == .waiting, "\(blank.debugDescription) should not be a Question")
            #expect(draft.body == nil)
        }
    }

    @Test("A permission wait is a distinct Approval with its safe summary")
    func permissionIsWaiting() throws {
        let request = PermissionRequestRef(id: PermissionRequestID("p1"), summary: "Run Bash")
        let draft = try #require(
            NotificationPolicy.draft(for: Fixture.change(to: .waitingPermission(request))))
        #expect(draft.event == .approval)
        #expect(draft.body == "Run Bash")
        #expect(draft.fingerprint == "p1")
    }

    @Test("A failure carries its reason")
    func failure() throws {
        let draft = try #require(
            NotificationPolicy.draft(for: Fixture.change(to: .failed(reason: "API error 529"))))
        #expect(draft.event == .failed)
        #expect(draft.body == "API error 529")
    }

    @Test("Provider and project ride along, so nothing has to be looked up later")
    func carriesContext() throws {
        let draft = try #require(
            NotificationPolicy.draft(
                for: Fixture.change(provider: .codex, project: "/Users/dev/agentbar-web")))
        #expect(draft.provider == .codex)
        #expect(draft.project.name == "agentbar-web")
    }
}

/// The body clamp. `failureReason` passes an unrecognised provider error through
/// with no length bound, and the transport's own 120 characters is a cap, not a
/// readable line.
@Suite("Body clamp")
struct BodyClampTests {

    @Test("A short line is left exactly as it is")
    func shortLine() {
        #expect(NotificationPolicy.clamped("API error 529") == "API error 529")
    }

    @Test("A line at the limit is not cut")
    func exactlyAtTheLimit() {
        let text = String(repeating: "a", count: NotificationPolicy.bodyLimit)
        #expect(NotificationPolicy.clamped(text) == text)
    }

    @Test("A long line is cut on a word boundary and says so")
    func wordBoundary() throws {
        let text =
            "The model returned an overloaded error and the request was not retried automatically"
        let clamped = try #require(NotificationPolicy.clamped(text))
        #expect(clamped.hasSuffix("…"))
        #expect(clamped.count <= NotificationPolicy.bodyLimit + 1)
        // Cut between words, never mid-word.
        #expect(text.hasPrefix(clamped.dropLast()))
        #expect(!clamped.dropLast().hasSuffix(" "))
    }

    /// A 70-character stack frame is still the most useful thing AgentBar can
    /// say about that failure, so it is cut rather than dropped.
    @Test("A single word longer than the limit is cut where it falls")
    func unbrokenWord() throws {
        let text = String(repeating: "x", count: 200)
        let clamped = try #require(NotificationPolicy.clamped(text))
        #expect(clamped.count == NotificationPolicy.bodyLimit + 1)
    }

    /// A banner is one paragraph however many newlines the provider put in.
    @Test("Whitespace collapses, including newlines and tabs")
    func collapsesWhitespace() {
        #expect(NotificationPolicy.clamped("one\n\ntwo\tthree   four") == "one two three four")
    }

    /// An empty body and no body are the same thing, and the second is honest.
    @Test("A line that is only whitespace becomes no line at all")
    func emptyBecomesNil() {
        #expect(NotificationPolicy.clamped("") == nil)
        #expect(NotificationPolicy.clamped("   \n\t ") == nil)
    }

    @Test("A clamped reason reaches the draft")
    func clampsThroughTheDraft() throws {
        let reason = String(repeating: "error ", count: 40)
        let draft = try #require(
            NotificationPolicy.draft(for: Fixture.change(to: .failed(reason: reason))))
        let body = try #require(draft.body)
        #expect(body.count <= NotificationPolicy.bodyLimit + 1)
    }
}

/// Titles. `{What} · {project}`, and the fallback that names the provider when
/// the badge could not be attached.
@Suite("Notification titles")
struct TitleTests {

    @Test("The verb comes first, so a truncated banner still delivers meaning")
    func verbFirst() {
        for event in NotificationEvent.allCases {
            #expect(Fixture.draft(event: event).title.hasPrefix(event.verb))
        }
    }

    @Test("The project is the bare folder name, never a path")
    func bareProjectName() {
        #expect(Fixture.draft().title == "Finished · agentbar")
    }

    @Test("Without a badge the provider goes into the title rather than being lost")
    func fallbackNamesProvider() {
        #expect(
            Fixture.draft(provider: .codex, event: .question).titleNamingProvider
                == "Question · Codex · agentbar")
    }

    /// One category per event, so the reserved Approve and Deny can be attached
    /// to one without the others being restructured.
    @Test("Every event has its own category identifier")
    func categoriesAreDistinct() {
        let identifiers = NotificationEvent.allCases.map(\.categoryIdentifier)
        #expect(Set(identifiers).count == NotificationEvent.allCases.count)
    }

    /// Four of the five are "an agent stopped and needs you". Marking the
    /// fifth time-sensitive too would spend the privilege on the one event that
    /// does not need it.
    @Test("Only finishing is not time-sensitive")
    func timeSensitivity() {
        #expect(NotificationEvent.question.isTimeSensitive)
        #expect(NotificationEvent.waiting.isTimeSensitive)
        #expect(NotificationEvent.approval.isTimeSensitive)
        #expect(NotificationEvent.failed.isTimeSensitive)
        #expect(!NotificationEvent.finished.isTimeSensitive)
    }
}
