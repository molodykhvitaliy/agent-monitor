// AgentBarNotifications
//
// Turns the state moves the ingest boundary observes into notifications, and
// owns the per-provider, per-event sound matrix that gives each one its voice.
//
// The module consumes `StateChange` and nothing else: it does not know that
// hooks exist, that Claude Code exists, or how an event reached the store. Its
// only intra-package edge is AgentBarCore, and `ModuleBoundaryTests` fails the
// build if that changes.
//
// Three rules shape everything here:
//
//   * **Never auto-approve.** No path — a dropped delivery, a dismissed banner,
//     a failed render, a category registered for buttons that do not exist yet —
//     may resolve into granting a permission. The reserved Approve/Deny actions
//     inherit this pre-emptively.
//   * **Never invent content.** Every notification body has a named source in
//     `docs/dev/design-spec.md` § Notifications: a failure reason, a question
//     line, or nothing at all. A title-only banner is correct; a fabricated one
//     is not.
//   * **Never fail silently.** `UNNotificationSound(named:)` falls back to the
//     default when it cannot find a file, and says nothing. Every selection is
//     therefore validated against the filesystem before it is offered and again
//     before it is sent, and an unusable one is reported to the user.
