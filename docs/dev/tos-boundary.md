# Terms of Service Boundary

**This document defines hard project limits, not recommendations.**

AgentBar is distributed to other people. A mistake here does not earn a warning —
it gets the accounts of people who trusted us banned. When in doubt, do not ship
it.

Verification date: 2026-08-18.

---

## 1. The single design invariant

> **AgentBar makes no network request to Anthropic or OpenAI. Ever.**

AgentBar is a *receiver*. Claude Code and Codex call into it through their own
documented extension points, and it reads files those tools write on the local
disk. It never authenticates as anyone, never carries a user credential, and
never originates a request to a model provider.

Every ToS question below is answered by this invariant. Any proposal that breaks
it is out of scope regardless of how useful it seems.

The only exception is the Codex App Server, and it is not an exception to the
invariant: `codex app-server` is a documented local integration surface, the
request is made by the user's own Codex binary using the user's own session, and
AgentBar only speaks JSON-RPC to a local process over stdio.

---

## 2. Anthropic — verified position

From <https://code.claude.com/docs/en/legal-and-compliance>, "Authentication and
credential use":

> OAuth authentication is intended exclusively for purchasers of Claude Free,
> Pro, Max, Team, and Enterprise subscription plans and is designed to support
> ordinary use of Claude Code and other native Anthropic applications.

> Developers building products or services that interact with Claude's
> capabilities, including those using the Agent SDK, should use API key
> authentication through Claude Console or a supported cloud provider.
> **Anthropic does not permit third-party developers to offer Claude.ai login or
> to route requests through Free, Pro, or Max plan credentials on behalf of
> their users.**

> Anthropic reserves the right to take measures to enforce these restrictions and
> may do so without prior notice.

Enforcement is real and recent: Anthropic clarified the restriction on
2026-02-19, and from 2026-04-04 Claude subscriptions stopped covering usage
through third-party tools. Bans followed.

**AgentBar is unaffected because it interacts with Claude's capabilities not at
all.** It observes a harness the user already runs under their own credentials.

---

## 3. Prohibited — unconditional

1. Using Claude Free/Pro/Max OAuth tokens for any network request from AgentBar.
2. Calling undocumented Anthropic endpoints, including `/api/oauth/usage`.
3. Calling undocumented Codex/OpenAI endpoints, including `/api/codex/usage`.
4. Reading, copying, decoding or forwarding credentials from
   `~/.claude/.credentials.json`, `~/.codex/auth.json`, or the macOS Keychain.
5. Impersonating an official client — spoofing user agents, client IDs, or
   harness identity.
6. Scraping `claude.ai` or `chatgpt.com` cookies or sessions.
7. Circumventing, masking or resetting rate limits.
8. Bypassing Codex hook trust, or instructing users to pass
   `--dangerously-bypass-hook-trust`.

## 4. Permitted

1. Receiving events through documented hook mechanisms of both platforms.
2. Reading the user's own local files that the tools themselves write.
3. Speaking JSON-RPC to `codex app-server`, a documented integration surface.
4. Consuming Claude Code OpenTelemetry the user explicitly enabled.
5. Ordinary local macOS APIs: notifications, power assertions, login items.

---

## 5. Enforcement in the codebase

Policy that is only written down decays. Three mechanisms keep this honest:

### 5.1 Automated scan — `scripts/tos-scan.sh`

Runs in CI on every pull request and locally via `make tos-check`. It fails the
build on:

- any `anthropic.com`, `openai.com`, `claude.ai`, `chatgpt.com` or
  `oaiusercontent.com` hostname, including subdomains;
- any reference to a known credential file or the Keychain item APIs;
- any provider-credential-shaped identifier — `oauth_token`, `refresh_token`,
  `access_token`, `x-api-key`, `sk-ant-`, `sk-proj-`;
- any use of `--dangerously-bypass-hook-trust`.

It scans `Sources`, `Tests`, `Apps`, `scripts`, `.github`, `Makefile` and the
package manifests — the manifests deliberately, because §5.2 depends on no remote
HTTP client entering the dependency graph.

The scan is deliberately blunt. A false positive is cheap — annotate it with a
reviewed `// tos-allow: <reason>` comment. A false negative is not, so a grep
that errors is treated as a failure rather than as "no matches", and an
annotation without a stated reason fails the scan. Active exceptions are printed
on every run so the allowlist cannot grow unnoticed.

Two things the scan does **not** do: it cannot see a hostname assembled at
runtime from fragments, and it does not reason about proximity. It is a
tripwire, not a proof.

### 5.2 Loopback-only networking

The app performs outbound network I/O to exactly one class of destination:
loopback. There is no HTTP client for remote hosts in the dependency graph.

This is an architectural property, upheld by review rather than by a runtime
check: adding a remote client means adding a dependency or a new module, both of
which are visible in a diff, and the scan covers the package manifests so a new
dependency cannot arrive unexamined.

### 5.3 The `tos-guard` skill

`.claude/skills/tos-guard/` — invoked before any work that touches networking,
credentials, quota, or a provider adapter. It re-reads this document, re-checks
the upstream legal pages when they may have changed, and runs the scan.

---

## 6. Re-verification

Provider terms change. Re-verify at the start of any step that touches quota or
networking, and at minimum every release:

- <https://code.claude.com/docs/en/legal-and-compliance>
- <https://www.anthropic.com/legal/consumer-terms>
- <https://www.anthropic.com/legal/aup>
- OpenAI / Codex terms for the App Server surface

Record the verification date here and in `platform-integration.md`.
