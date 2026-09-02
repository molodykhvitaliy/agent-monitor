---
name: platform-docs
description: Verify Claude Code and Codex integration facts against current primary sources before writing or changing any provider adapter, installer, hook payload decoder, or quota code. Use when touching Sources/ClaudeCodeAdapter, Sources/CodexAdapter, Sources/CodexAppServer, Apps/agentbar-helper, schemas/appserver, or when a platform behaviour claim needs confirmation. Do not use for provider-neutral domain or UI work.
---

# Platform Docs Verification

Both platforms changed substantially through 2026 and most third-party guides are
wrong. The original spec draft contained at least three factual errors that this
procedure caught. Treat every remembered detail as suspect.

## Source precedence

```
1. Official platform documentation (current version)
2. Machine-readable schema shipped with the installed binary
3. Observed local behaviour, reproduced and recorded
4. Changelogs
5. GitHub issues — only evidence of bugs and gaps
6. Third-party articles — never authoritative
```

A stale GitHub issue does not override documented behaviour.

## Canonical URLs

**Claude Code**
- Hooks reference — <https://code.claude.com/docs/en/hooks>
- Docs index — <https://code.claude.com/docs/llms.txt>
- Monitoring / OpenTelemetry — <https://code.claude.com/docs/en/monitoring-usage>
- Legal and compliance — <https://code.claude.com/docs/en/legal-and-compliance>

**Codex** — note the host moved; `developers.openai.com/codex/*` 308-redirects here
- Hooks — <https://learn.chatgpt.com/docs/hooks>
- App Server — <https://learn.chatgpt.com/docs/app-server>
- Config reference — <https://learn.chatgpt.com/docs/config-reference>

## Procedure

1. **Read the local reference first.** [docs/dev/platform-integration.md](../../../docs/dev/platform-integration.md)
   records what was verified and on which date, against which tool versions.

2. **Check whether it is still current.**

   ```bash
   claude --version && codex --version
   ```

   If either differs from the version recorded in the reference, re-verify the
   sections you depend on. Do not proceed on an unverified assumption.

3. **Prefer the shipped schema over prose.** For anything App Server related the
   binary carries the authoritative contract:

   ```bash
   codex app-server generate-json-schema --out .scratch/notes/appserver-schema
   diff -ru schemas/appserver .scratch/notes/appserver-schema
   ```

   A non-empty diff means the protocol moved. Update generated models and the
   reference before writing code against it.

4. **Fetch the documentation page** for the specific behaviour, and quote exact
   field names into your notes. Paraphrase is how errors enter.

5. **Reproduce locally when the behaviour is observable.** Record the command,
   the output and the date. Redact account identifiers before saving.

6. **Update [docs/dev/platform-integration.md](../../../docs/dev/platform-integration.md)**
   with anything newly verified or newly contradicted, and bump its verification
   date and tool versions. If a documented behaviour contradicts the reference,
   documentation wins and the reference is corrected in the same change.

7. **If the change touches quota, credentials or networking**, run the
   `tos-guard` skill as well.

## Known corrections already applied

Do not reintroduce these — they were wrong in the original spec draft:

- Claude Code `PermissionRequest` currently returns a nested `decision` object
  with `behavior: allow|deny`; allow may carry `updatedInput` and
  `updatedPermissions`, while deny may carry `message` and `interrupt`. This
  supersedes the string format recorded during the 2026-08-28 verification.
  Codex also uses a nested decision object, but its optional fields must be
  verified separately.
- Claude Code `PermissionRequest` **cannot block**; exit code 2 is ignored.
- There is no top-level `worktree` field in the Claude Code hook payload.
- Codex `SessionEnd` hooks are capped at 1s (3s max), not 600s.
- Codex documentation lives on `learn.chatgpt.com`, not `developers.openai.com`.
- App Server `credits` is an object, not a scalar; `individualLimit` and
  `spendControlReached` exist and were missing from the draft.
