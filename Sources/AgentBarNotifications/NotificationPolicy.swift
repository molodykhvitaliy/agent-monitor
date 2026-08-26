import AgentBarCore
import Foundation

/// Which state moves become notifications, and what they say.
///
/// A pure function of one `StateChange`, deliberately: it is the whole of the
/// design's verb table, it is where a mistake would either wake someone for
/// nothing or fail to wake them at all, and neither risk should need a
/// notification centre to test.
///
/// The table, from `docs/dev/design-spec.md` § Notifications:
///
/// | Verb | Fires when | Body |
/// |---|---|---|
/// | `Question` | `to.kind == .waiting` **and** a question line is present | the question line |
/// | `Waiting` | `to.kind == .waiting` and no line | none |
/// | `Approval` | `to` is `.waitingPermission` | permission summary |
/// | `Finished` | `from != nil` **and** `to == .idle` | none |
/// | `Failed` | `to` is `.failed` | the reason |
///
/// Two reachable shapes fire nothing, and naming them is the point of writing
/// the predicates as conditions on `from` and `to` rather than as a feeling
/// about the event.
public enum NotificationPolicy {
    private struct Classification {
        let event: NotificationEvent
        let body: String?
        let fingerprint: String?
    }

    /// How much of a body survives. The row truncates; a notification body would
    /// not, and `failureReason` passes an unrecognised provider error through
    /// with no length bound of its own — `NativeEventDecoder`'s 120 characters
    /// is a transport cap, not a readable line.
    public static let bodyLimit = 60

    /// The draft this change deserves, or `nil` when it deserves none.
    public static func draft(for change: StateChange) -> NotificationDraft? {
        // The store adopted a session it had not seen — AgentBar launching
        // beside an agent already running, or a bare session announcement. It
        // produces `nil → idle`, which would otherwise fire `Finished` for a
        // turn that never happened here.
        guard change.from != nil else { return nil }
        // The session left the store, by `sessionEnded` or by the watchdog
        // evicting it. Neither is news: nothing needs the user.
        guard let destination = change.to else { return nil }
        guard let classified = classify(destination) else { return nil }

        return NotificationDraft(
            sessionId: change.sessionId,
            provider: change.provider,
            project: change.project,
            event: classified.event,
            body: classified.body,
            fingerprint: classified.fingerprint,
            at: change.at)
    }

    /// The verb a destination state selects, and the body that goes with it.
    ///
    /// **One function, not two.** The verb and the body are the same decision
    /// asked twice: `Question` is defined as "a waiting event that has a line",
    /// so choosing the verb from the presence of the *field* and the body from
    /// the presence of a *usable line* would let them disagree. They can: the
    /// adapter refuses only an empty question, and a line of nothing but spaces
    /// survives that check and then clamps away to nothing — which would title a
    /// banner `Question` and give it no question.
    ///
    /// `unknown` selects nothing. It is the absence of information, and waking
    /// someone to tell them AgentBar has stopped knowing is not worth an
    /// interruption; the row and the status glyph carry it. `working` selects
    /// nothing either — an agent that started working is the least surprising
    /// thing that can happen.
    private static func classify(_ state: SessionState) -> Classification? {
        switch state {
        case .idle:
            Classification(event: .finished, body: nil, fingerprint: nil)
        case .failed(let reason):
            Classification(event: .failed, body: clamped(reason), fingerprint: nil)
        // The verb is chosen by the presence of the question line, not by the
        // event: both waiting paths decode to the same `EventKind.waitingInput`
        // and `StateChange` carries no discriminator (ADR-0005).
        case .waitingInput(let question):
            question.flatMap { clamped($0) }.map {
                Classification(event: .question, body: $0, fingerprint: nil)
            } ?? Classification(event: .waiting, body: nil, fingerprint: nil)
        case .waitingPermission(let request):
            Classification(
                event: .approval,
                body: request.summary.flatMap { clamped($0) },
                fingerprint: request.id.value)
        case .working, .unknown:
            nil
        }
    }

    /// The first `bodyLimit` characters on a word boundary, with an ellipsis
    /// where the cut fell.
    ///
    /// Provider error strings pass through verbatim — never localised, never
    /// prettified — but they are not promised to be short, or to be one line.
    /// Runs of whitespace collapse first: a banner is one paragraph however many
    /// newlines the provider put in its message.
    ///
    /// Returns `nil` for a line that is empty once collapsed, because an empty
    /// body and no body are the same thing and the second is the honest form.
    /// The canvas's `3 files changed` has no source in the domain and never will
    /// without new payload plumbing; macOS renders a title-only notification
    /// cleanly, so an absent body costs nothing — an invented one would cost the
    /// product its honesty.
    public static func clamped(_ text: String, limit: Int = bodyLimit) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }

        let head = collapsed.prefix(limit)
        // The last space *inside* the kept text is the word boundary. A single
        // word longer than the limit has none, and is cut where it falls rather
        // than dropped entirely — a 70-character stack frame is still the most
        // useful thing AgentBar can say about that failure.
        let boundary = head.lastIndex(of: " ")
        let kept = boundary.map { head[head.startIndex..<$0] } ?? head
        return kept.trimmingCharacters(in: .whitespaces) + "…"
    }
}
