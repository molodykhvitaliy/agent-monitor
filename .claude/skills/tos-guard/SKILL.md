---
name: tos-guard
description: Enforce the project's Terms of Service boundary before shipping anything that touches networking, credentials, authentication, subscription quota, usage data, or a provider integration surface. Use when adding a network call, reading files under ~/.claude or ~/.codex, implementing quota display, or preparing a release. Do not use for provider-neutral domain, UI or build work.
---

# ToS Guard

AgentBar is given to other people. A mistake here does not cost us a warning —
it costs them their accounts. Anthropic began enforcing against third-party
subscription use in February 2026 and stopped covering third-party tools from
2026-04-04. Bans followed.

## The invariant

> **AgentBar makes no network request to Anthropic or OpenAI. Ever.**

AgentBar receives events from harnesses the user already runs under their own
credentials, and reads local files those harnesses write. It holds no credential
and originates no provider request. `codex app-server` is not an exception: it is
a documented local integration surface reached over stdio on the user's machine.

Read [docs/dev/tos-boundary.md](../../../docs/dev/tos-boundary.md) in full before
proceeding. It carries the exact quoted policy language and its verification date.

## Checklist

Answer every question. A single "yes" in the first block stops the work.

**Hard stops**

- [ ] Does this send a request to any Anthropic or OpenAI host?
- [ ] Does this read, decode, store or forward a credential — `auth.json`,
      `.credentials.json`, Keychain, environment token?
- [ ] Does this call an undocumented endpoint?
- [ ] Does this present AgentBar as an official client, or reuse a harness
      identity, user agent or client ID?
- [ ] Does this circumvent, mask or reset a rate limit?
- [ ] Does this bypass Codex hook trust, or tell the user to?

**Required properties**

- [ ] Every outbound socket is loopback.
- [ ] Every file read under `~/.claude` or `~/.codex` is the user's own data,
      read-only, and tolerant of an unparseable or absent file.
- [ ] Quota display shows only what a documented surface returned. Nothing is
      estimated, extrapolated or rendered as a progress bar we cannot back.
- [ ] Claude Code quota is presented honestly as unavailable.
- [ ] Absent data renders as "unavailable" — never as zero, never as a crash.

## Verify

```bash
make tos-check
```

The scan is intentionally blunt. Annotate a reviewed false positive inline with
`// tos-allow: <reason>` and say why in the pull request.

## Re-verify the sources

Provider terms move. Re-read these when touching quota or networking, and before
every release, then update the verification date in
[docs/dev/tos-boundary.md](../../../docs/dev/tos-boundary.md):

- <https://code.claude.com/docs/en/legal-and-compliance>
- <https://www.anthropic.com/legal/consumer-terms>
- <https://www.anthropic.com/legal/aup>

## When uncertain

Do not ship it. Write the question into the step file and raise it. There is no
feature in this project worth a friend's account.
