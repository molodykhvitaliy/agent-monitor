# Security Policy

## Reporting a vulnerability

**Please do not open a public issue.** Use GitHub's private reporting —
*Security* › *Report a vulnerability* on this repository — which reaches the
maintainer without disclosing anything.

If that page is not available, open a public issue that says only *"I have a
security report, please enable private reporting"* — no details, no reproduction
— and wait. An empty placeholder costs nothing; a public issue with a working
exploit in it cannot be taken back.

Useful in a report: what an attacker has to already have (local account? another
process? the ability to write a file?), what they gain, and the smallest sequence
that shows it. A proof of concept is welcome and not required.

There is no bounty. This is one person's project given away for free, and the
response you get will be a fix and credit if you want it.

## Supported versions

The most recent release, and `main`. Nothing older is patched — there is no
long-term support branch and pretending otherwise would be worse than saying so.

## What AgentBar actually touches

Reports about any of this are in scope, and the list is here so you do not have
to read the source to find out where to look.

- **It edits two files the user owns**: `~/.claude/settings.json` and
  `~/.codex/hooks.json`. Both edits are merges that preserve foreign entries,
  both take a timestamped backup beside the file first, and both are reversible
  from Settings › Remove AgentBar. It never writes `~/.codex/config.toml`.
- **It listens on loopback**, `127.0.0.1:47821` by default, for hook deliveries.
  The listener binds `127.0.0.1` exactly — never a name, never a wildcard — and is
  authenticated with a bearer token
  that AgentBar generates and writes into the hook definition it installs
  ([ADR-0004](docs/adr/ADR-0004-hook-token-in-settings-file.md) records that
  decision and its limits, which are real: the token is a literal in a file the
  user's other tools can read).
- **It spawns one child process**, `codex app-server`, to read subscription
  limits, and kills it on every path
  ([ADR-0009](docs/adr/ADR-0009-codex-limits-come-from-a-child-that-is-always-killed.md)).
- **It ships a small helper binary** that Codex executes as a hook. It is
  deployed to `~/Library/Application Support/AgentBar/bin/agentbar-helper` and
  relays one JSON object to the loopback endpoint. Before connecting, it checks
  the address it was given is inside `127.0.0.0/8` — on the network-order first
  octet — even though AgentBar wrote that address itself.
- **It is distributed unsigned.** The download is ad-hoc signed and not notarized
  ([ADR-0015](docs/adr/ADR-0015-distribution-is-source-first-until-a-developer-id-exists.md)),
  so the integrity of the release channel itself is in scope: a problem with how
  artifacts are built, published or checksummed is a report worth making.

## Explicitly not vulnerabilities

- **That the download is unsigned and requires clearing quarantine.** It is a
  documented, deliberate consequence of having no Apple Developer Program
  membership. Building from source is the answer, and it is in the README.
- **That AgentBar is unsandboxed.** The App Sandbox forbids writing the two
  configuration files the entire application exists to install hooks into.
- **That the hook token sits in a plaintext file the user owns.** The alternatives
  are considered and rejected in ADR-0004; a better option is a design
  conversation, not a vulnerability report.

## Three claims worth attacking

If you want the shortest route to something that would genuinely matter:

1. **AgentBar makes no network request to Anthropic or OpenAI, ever.** Any path
   that originates one, or that reads or forwards a provider credential, is a
   critical finding.
2. **No path resolves to granting a permission.** No timeout, crash, parse
   failure or dropped connection may auto-approve anything.
3. **Removal is complete and touches nothing foreign.** A removal that deletes
   something AgentBar did not create, or that leaves a hook behind while
   reporting success, is a real bug in the surface whose whole job is honesty.
