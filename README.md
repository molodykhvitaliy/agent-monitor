# AgentBar

Native macOS menu-bar app for monitoring [Claude Code](https://code.claude.com)
and [OpenAI Codex](https://learn.chatgpt.com) coding sessions.

> **Status: feature-complete, not yet distributed.** Every feature below is
> built and tested. What is missing is signing and notarization, so there is no
> download yet — build it from source with `make build`.

## What it does

Agents work autonomously for minutes and then stop, needing a human. AgentBar
makes those pauses visible:

- **Notifications** when an agent asks a question, waits on an approval, goes
  quiet, finishes or fails — carrying which agent, what it needs, and which
  project, with a configurable sound per provider and event type.
- **Menu-bar status** — every session grouped by project, with its state, current
  tool, duration and subagent count.
- **Codex subscription limits**, rendered from whatever usage windows the API
  reports.
- **Caffeine** — keeps the Mac awake while an agent is working.
- **Diagnostics** — a self-test and the endpoint's own counters, so a user who
  sees nothing happening can find out why without opening Console.

## How it works

AgentBar uses the **documented lifecycle hooks** of both tools. Claude Code posts
events to a loopback endpoint directly; Codex invokes a small compiled helper that
relays them.

It is a strictly additive layer. If AgentBar is not running, has crashed, or is
uninstalled, **both tools behave exactly as if it never existed.**

## Removing it

Settings › **Remove AgentBar** takes the hooks back out of
`~/.claude/settings.json` and `~/.codex/hooks.json`, deletes the Codex helper,
unregisters the login item and removes what AgentBar keeps in Application
Support — backing up each configuration file beside itself first, touching
nothing anyone else put there, and reporting every step separately. Anything it
cannot remove is named with the exact file and what to do about it.

Do this **before** moving the app to the Trash. A deleted app leaves its hooks
behind, and both tools would go on calling an endpoint that no longer answers.

## Terms of Service

**AgentBar makes no network request to Anthropic or OpenAI. Ever.**

It holds no credentials and originates no provider requests. It receives events
from harnesses the user already runs under their own credentials, and reads local
files those harnesses write.

One consequence is visible in the interface: Codex exposes a documented local
interface for subscription limits, and Claude Code does not. AgentBar shows Codex
limits and states plainly that Claude Code's remaining quota is unavailable. It
does not estimate.

This boundary is enforced in CI, not just documented — see
[docs/dev/tos-boundary.md](docs/dev/tos-boundary.md).

## Requirements

macOS 26 or later.

## Development

```bash
make bootstrap   # install tooling, generate the Xcode project
make build       # build the app
make check       # lint, test, ToS scan, generated models — before every commit
```

The interface is English-only and there is no string catalogue: every
`String(localized:)` falls back to its key, which is the English text. Adding a
catalogue is a deliberate later step, not an oversight — see
[docs/dev/build.md](docs/dev/build.md).

The Xcode project is generated from `project.yml` and is not committed.

| Document | Contents |
|---|---|
| [CLAUDE.md](CLAUDE.md) | project instructions (also `AGENTS.md`) |
| [docs/dev/architecture.md](docs/dev/architecture.md) | module boundaries, domain model |
| [docs/dev/build.md](docs/dev/build.md) | build system, toolchain, bundle layout |
| [docs/dev/platform-integration.md](docs/dev/platform-integration.md) | verified platform facts |
| [docs/dev/tos-boundary.md](docs/dev/tos-boundary.md) | hard project limits |
| [docs/adr/](docs/adr/) | architecture decision records |

## License

See [LICENSE](LICENSE).
