# Terms of Service Boundary

**This document defines hard project limits, not recommendations.**

AgentBar is distributed to other people. A mistake here does not earn a warning —
it gets the accounts of people who trusted us banned. When in doubt, do not ship
it.

Verification date: 2026-08-28.

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

Coverage is itself checked. Every top-level path in the checkout must be either
scanned or listed as a named exclusion with a reason; an unclassified **tracked**
path fails the run, and an unclassified untracked one is reported as a note, so a
scratch file in the working tree is not mistaken for a new source directory. If
the listing cannot be produced at all — outside a git checkout, or `git ls-files`
returning nothing — the run fails rather than reporting clean.

The exclusions are `docs/`, `.claude/`, `README.md`, `CLAUDE.md`, `AGENTS.md`,
`LICENSE`, the lint and ignore configuration, and `schemas/`. Documentation and
the project skills are excluded because prose about the boundary has to quote the
hostnames the boundary forbids — this document included. `schemas/` is excluded
because it is generated verbatim from the installed `codex` binary and
legitimately describes types such as `ChatgptAuthTokensRefreshResponse`; Swift
generated from that schema lives under `Sources` and is scanned.

The classification is by top-level path, so content added inside an excluded
directory inherits its exclusion. `.claude/` is the one exclusion that could
plausibly gain executable surface — hooks, `settings.json` command entries — so
the scan additionally fails if it contains anything other than skill
documentation.

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

**2026-08-19** — re-verified because step 11 changed how often Codex limits are
read. `code.claude.com/docs/en/legal-and-compliance` and the Usage Policy
(effective 2025-09-15) are unchanged in every respect this project depends on:
OAuth remains "intended exclusively for purchasers … and native Anthropic
applications", third-party developers are still told to use API keys and may not
"route requests through Free, Pro, or Max plan credentials", and the Usage Policy
still says nothing about polling frequency because it does not need to — nothing
here talks to Anthropic at all.

One sentence is worth quoting for the cadence question, even though it is about
Anthropic and the cadence is Codex's:

> Advertised usage limits for Pro and Max plans assume ordinary, individual
> usage of Claude Code and the Agent SDK.

*Ordinary, individual* is the standard the reading cadence is held to. It is why
the tightest gap belongs to a panel somebody has open, why that gap is a minute
rather than a second, and why it is **bounded** — an open panel stops asking
after five minutes, because a window left up is not a person watching it.

**2026-08-28** — re-verified before the first public release, which is the case
§6 names explicitly. All three sources re-read in full.

The Usage Policy is unchanged, still effective 2025-09-15. The Consumer Terms are
effective 2025-10-08 and say nothing that reaches this project: their automation
clause governs *"access the Services through automated or non-human means"* and
AgentBar accesses the Services not at all, and their credential clause forbids
sharing an account login, which AgentBar never sees.

`code.claude.com/docs/en/legal-and-compliance` is unchanged in every sentence
this project already depended on — OAuth "intended exclusively for purchasers …
and native Anthropic applications", third-party developers told to use API keys
and forbidden to "route requests through Free, Pro, or Max plan credentials".

**Two passages are new since 2026-08-19, and both matter here.**

The first extends the credential rule:

> Moreover, developers may not collect, store, or intermediate Claude.ai
> credentials or session tokens — sign-in to a Claude account must complete
> through Anthropic's own flow.

AgentBar is unaffected: it holds no credential, reads none, and has no sign-in of
any kind. It is quoted because it is the sentence a future feature would break
first — anything that proposed to *read* `~/.claude/.credentials.json`, even to
display a plan name, is now doubly prohibited rather than merely inadvisable. §3
already forbids it; this is the upstream text that agrees.

The second is about names, and is newly load-bearing because the repository is
becoming public:

> You can accurately say, in plain text, that your product has Claude Code
> preinstalled or that it runs Claude Code. But you can't use the Claude Code or
> Anthropic names or logos as part of your own product, feature, or company name,
> in your own logo, or in a way that suggests Anthropic built, endorses, or is
> partnered with your product.

AgentBar complies, and did before the paragraph existed:

- the product name contains no provider name;
- the README says only what AgentBar observes, in plain text, and now carries an
  explicit statement that the project is not affiliated with or endorsed by
  Anthropic or OpenAI;
- the provider badges are **original generic marks** — a four-point sparkle and a
  concave star — chosen for exactly this reason and recorded as a trademark
  decision in `design-system.md` long before this reading;
- the app icon carries neither provider's figure.

The same restraint is owed to OpenAI, and the README's statement names both.

Nothing about the distribution change — source-first, unsigned, public
repository — touches the boundary. AgentBar's network surface after it is
loopback, exactly as before; ADR-0015 adds no request to anybody.
