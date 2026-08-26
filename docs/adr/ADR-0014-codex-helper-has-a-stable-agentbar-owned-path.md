---
id: ADR-0014
title: The Codex helper has a stable AgentBar-owned path
status: accepted
date: 2026-08-26
supersedes: null
superseded_by: null
tags: [codex, helper, installer, trust, safe-superset]
---

## Context

Codex command-hook trust covers the exact hook definition, including the helper's
absolute path. AgentBar originally wrote the path of the helper inside whichever
`AgentBar.app` was running. Local Debug, `dist` and installed copies therefore
produced different commands. Switching copies made all eight definitions drift,
left the existing trust hashes describing old commands, and repeatedly surfaced
`Needs Repair` even when no source or settings had changed.

The helper must still ship inside the signed bundle. Executing only that copy,
however, couples a user-owned trusted definition to the movable location of the
application. ADR-0008 remains the trust policy: AgentBar observes trust and never
asserts or bypasses it. This decision narrows how AgentBar avoids invalidating
that trust during ordinary app movement.

## Decision drivers

- Debug, distribution and installed copies must write the same hook command.
- Updating AgentBar must update the helper bytes without partially overwriting an
  executable that Codex may be launching concurrently.
- A copy or validation failure must leave both the previous helper and the user's
  `hooks.json` untouched.
- Installation must remain merge-only, backed up, idempotent and reversible.
- Nothing about deployment may create a decision path for `PermissionRequest`.

## Considered options

1. Continue naming the bundle helper and treat every app move as repair drift.
2. Require installation at one fixed `/Applications` path.
3. Write a shell command that discovers the current app or helper dynamically.
4. Deploy the signed bundle helper to one stable AgentBar-owned Application
   Support path and keep the hook command fixed.

## Decision

**Option 4.** The bundle helper is a deployment source. AgentBar copies it to:

```text
~/Library/Application Support/AgentBar/bin/agentbar-helper
```

The copy is staged beside the destination, receives the source executable mode,
is validated as an executable regular file, and is atomically renamed into place.
An unchanged file is not rewritten. Hook status and installation always compare
against this deployed URL, never the running app's bundle URL.

Deployment succeeds before any hooks are changed. Failure returns a specific
integration error and performs no configuration write. Uninstall removes
AgentBar-owned hooks first, then removes the helper only when the complete path
tail is `AgentBar/bin/agentbar-helper`.

The first release carrying this decision requires one explicit Repair for hooks
that still name DerivedData or an app bundle, followed by the normal `/hooks`
review. Later changes of app location or build configuration refresh only the
file at the stable path and do not change the trusted command.

## Consequences

- Ordinary app moves no longer cause `Needs Repair` or a fresh trust review.
- The helper may be refreshed while an older process still uses the previous
  inode; the next launch opens the replacement at the same command path.
- Application Support now contains an executable owned by AgentBar. Bundle
  verification still checks the signed source, while deployment tests check mode,
  replacement, failure preservation and removal scope.
- If AgentBar is missing or deployment fails, existing Codex hooks either invoke
  the last valid helper or fail as ordinary observation hooks. They still emit no
  decision and cannot approve anything.

## References

- [Codex hooks documentation](https://learn.chatgpt.com/docs/hooks)
- [docs/dev/platform-integration.md](../dev/platform-integration.md) §2.5
- [ADR-0008](ADR-0008-codex-hook-trust-is-observed-never-asserted.md)
