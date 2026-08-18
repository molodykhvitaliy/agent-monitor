---
id: ADR-0002
title: No provider network requests — the ToS boundary
status: accepted
date: 2026-08-18
supersedes: null
superseded_by: null
tags: [legal, security, quota, architecture]
---

## Context

AgentBar displays subscription limits and is distributed to other people.
Anthropic clarified on 2026-02-19 that using Free/Pro/Max OAuth tokens in any
other product violates the Consumer Terms, and from 2026-04-04 subscriptions
stopped covering third-party tools. Enforcement included account bans.

A wrong decision here does not cost the project a warning. It costs users who
trusted us their accounts.

## Decision drivers

- Absolute ToS compliance, verifiable by a reader of the source.
- Useful quota display where it is legally available.
- Honest UI where it is not.
- Policy that cannot silently decay as the code grows.

## Considered options

1. Reuse harness OAuth tokens to query quota endpoints.
2. Call undocumented endpoints (`/api/oauth/usage`, `/api/codex/usage`).
3. Documented surfaces only, and state plainly what is unavailable.

## Decision

**Option 3, expressed as a single invariant:**

> AgentBar makes no network request to Anthropic or OpenAI. Ever.

Codex quota comes from `codex app-server` — a documented local integration
surface reached over stdio, where the request is made by the user's own binary
under the user's own session. Claude Code quota is presented as unavailable, with
an explanation. No estimate, no pseudo progress bar.

The invariant is enforced mechanically, not by good intentions: a blunt
`scripts/tos-scan.sh` runs in CI, the dependency graph contains no remote HTTP
client, and a `tos-guard` skill gates relevant changes.

## Consequences

**Positive.** The project is trivially defensible: it holds no credential and
originates no provider request. Users cannot be banned for running it. The
asymmetry between providers is visible and explained rather than papered over.

**Negative.** Claude Code users get no remaining-quota figure, which is the single
most-requested feature we will decline. The Codex path depends on an
`[experimental]` command, so it needs a version-aware adapter and graceful
degradation.

**Accepted trade-off.** An honest gap beats a plausible number obtained
illegitimately.

## References

- [docs/dev/tos-boundary.md](../dev/tos-boundary.md)
- <https://code.claude.com/docs/en/legal-and-compliance>
