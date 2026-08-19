// CodexAppServer
//
// Codex's subscription limits, read from `codex app-server` over stdio.
//
// The module boundary is three rules, and each is enforced by a test rather
// than by this comment:
//
//   1. It speaks only to a **local child process**. No socket, no host, no
//      credential — the request that leaves the machine is made by the user's
//      own Codex binary under the user's own session, which is the whole reason
//      this is inside ADR-0002's boundary rather than an exception to it.
//   2. It is the **only** module allowed to spawn a subprocess, which is why
//      `ModuleBoundaryTests` restricts `Process` to it.
//   3. Nothing above it learns that Codex exists. `QuotaWindow` carries numbers
//      and durations; the app target turns them into the panel's `UsageWindow`.
//
// The protocol models are **generated** from the schema the installed binary
// emits (`make schema-sync`, then `make generate-models`), because transcribing
// that contract by hand is how four field names entered the original spec draft
// wrong.
