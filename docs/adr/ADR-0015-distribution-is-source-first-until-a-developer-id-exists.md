---
id: ADR-0015
title: Distribution is source-first until a Developer ID exists
status: accepted
date: 2026-08-28
supersedes: null
superseded_by: null
tags: [distribution, signing, notarization, gatekeeper, release, open-source]
---

## Context

Every earlier step assumed the release would be signed with a Developer ID,
notarized, stapled, wrapped in a DMG and updated through Sparkle. That
assumption is written into `project.yml`, the entitlements file, `build.md`,
`release.yml` and the step 12 specification, all of which promise "step 12"
delivers it.

**The Apple Developer Program membership was not obtained and will not be soon.**
Nothing about that is a build problem to work around: a Developer ID certificate
is issued by Apple to a paying member, notarization is a service only members can
submit to, and Gatekeeper trusts no locally generated certificate. Without the
membership, none of the planned mechanism is available — not partially, not in a
degraded form.

What *is* available is the whole application, its source, and a build that runs.
The project is Apache-2.0 licensed and its build is `make bootstrap && make
install` from a clean checkout with no account of any kind. So the distribution
question is not "how do we approximate a signed release" but "which channel is
honest about what this is".

Two platform facts constrain the answer, both verified on macOS 27 rather than
recalled:

- **Quarantine is applied by whatever downloads a file, not by the build.** A
  locally built bundle carries no `com.apple.quarantine` attribute and Gatekeeper
  never assesses it. A downloaded one carries it on every file inside the bundle,
  and an unnotarized app is refused until it is removed.
- **Apple's own `syspolicy_check distribution` describes an ad-hoc signed build
  as one that "may run locally"** while being "not suitable for distribution".
  That is precisely the shape of what this project can offer.

A third fact makes the choice of install path load-bearing rather than cosmetic:
requesting notification authorisation from a bundle inside `DerivedData` fails
and macOS records the refusal against the bundle identifier **permanently**
(`platform-integration.md` §6.3). An instruction that ends at `make build` would
break the application's headline feature on a new user's machine, irreversibly.

## Decision drivers

- The three non-negotiables are unaffected by distribution and must stay that
  way: no provider network request, no auto-approval, and both harnesses behave
  identically when AgentBar is absent.
- A user must be able to check what they are running. An unsigned binary from a
  stranger is worth less than a build the recipient produced from readable
  source.
- Whatever is documented must be reproducible by someone who is not the author,
  on a machine with no Apple account.
- The step that acquires a certificate later must be a change of secrets, not a
  redesign of the pipeline.
- Nothing may claim a property it does not have. "Signed" and "verified" are
  words with meanings here.

## Considered options

1. **Wait for the membership.** Ship nothing until the account exists.
2. **Sign with a self-generated certificate.** Gatekeeper trusts no local
   certificate authority; the result is an unsigned app that looks signed to a
   `codesign -dv` reader. Strictly worse than being plain about it.
3. **Source-first, with an ad-hoc signed download as a convenience.** Building
   from source is the recommended channel and is documented first; a tagged
   release also publishes an ad-hoc signed `.zip` and its SHA-256, with the
   quarantine removal stated plainly.
4. **Source-only.** No artifact at all; the only way in is a local build.

## Decision

**Option 3.**

AgentBar is distributed as an open-source project built from source. `make
install` performs a Release build and places the bundle in `/Applications`,
because the order build → install → launch is a correctness requirement and not
advice. A `v*` tag additionally publishes `AgentBar-<version>.zip` with a
checksum, built by the same script a contributor runs locally, together with the
exact command that clears quarantine.

Nothing in the pipeline pretends. The release notes say the build is ad-hoc
signed and unnotarized. `scripts/notarize.sh` fails rather than no-ops if it is
ever reached, so a signed-but-unnotarized artifact cannot be published by
accident. The Developer ID branch in `scripts/build-release.sh` is written and
marked as never having been executed.

Signing, notarization, stapling, the `time-sensitive` entitlement, Sparkle and
Homebrew move to a deferred step 13, blocked on the membership.

## Consequences

- **A download is quarantined and must be cleared by hand**
  (`xattr -d -r com.apple.quarantine /Applications/AgentBar.app`). A local build
  is not affected at all, which is the honest reason to prefer it.
- **There is no automatic update.** Sparkle over an unsigned artifact is an
  update channel with no authenticity guarantee; `git pull && make install` is
  the update path. This costs the "updates arrive on their own" goal outright.
- **`com.apple.developer.usernotifications.time-sensitive` stays absent.** It
  needs a provisioning profile, which needs the membership. Notifications still
  request `.timeSensitive` and are silently downgraded to `.active`, so nothing
  is lost but the privilege.
- **`ENABLE_HARDENED_RUNTIME` stays off.** It is a notarization prerequisite and
  buys nothing without it, while adding runtime restrictions the build has never
  been tested under.
- **An ad-hoc signature is not a stable identity.** Every rebuild changes the
  code directory hash. Notification authorisation is keyed to the bundle
  identifier and survives, which is what makes frequent local rebuilds workable —
  but it is also why the install location must be stable rather than a build
  directory that moves.
- **Codex hook trust is unaffected by rebuilds.** The hook definition names
  `~/Library/Application Support/AgentBar/bin/agentbar-helper`
  ([ADR-0014](ADR-0014-codex-helper-has-a-stable-agentbar-owned-path.md)), not a
  path inside the bundle, so an update does not send the user back to `/hooks`.
  Without that decision this one would be much more expensive.
- **The Mac App Store remains a non-goal**, now for two reasons rather than one:
  the sandbox forbids writing `~/.claude` and `~/.codex`, and membership is
  required there too.
- Going public makes the repository's own contents part of the distribution.
  `.scratch/` stays untracked, and a committed file may not send a reader *there*
  for an instruction — which is what both release scripts used to do, and the
  first thing this step fixed. Naming a local-only path as the provenance of a
  decision is fine and several ADRs do it; telling someone to go and read one is
  not.

## References

- [docs/dev/build.md](../dev/build.md) — the Distribution section and what each
  command produces
- [ADR-0014](ADR-0014-codex-helper-has-a-stable-agentbar-owned-path.md) — why a
  rebuild does not re-trigger the Codex trust prompt
- [ADR-0003](ADR-0003-spm-modules-with-xcodegen.md) — the generated project and
  the clean-checkout requirement ad-hoc signing protects
- [docs/dev/platform-integration.md](../dev/platform-integration.md) §6.3 — the
  first-launch authorisation trap that makes `make install` a script
- [docs/dev/tos-boundary.md](../dev/tos-boundary.md) — re-verified for this
  release
