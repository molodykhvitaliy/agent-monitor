# AgentBar

Native macOS menu-bar app for monitoring [Claude Code](https://code.claude.com)
and [OpenAI Codex](https://learn.chatgpt.com) coding sessions.

> **Status: in development.** The build foundation is in place — a clean
> checkout produces a launchable menu-bar app — but no monitoring exists yet.

## What it does

Agents work autonomously for minutes and then stop, needing a human. AgentBar
makes those pauses visible:

- **Notifications** when an agent finishes, asks a question or goes idle —
  carrying which agent, what it needs, and which project, with a configurable
  sound per provider and event type.
- **Menu-bar status** — every session grouped by project, with its state, current
  tool, duration and subagent count.
- **Codex subscription limits**, rendered from whatever usage windows the API
  reports.
- **Caffeine** — keeps the Mac awake while an agent is working.

## How it works

AgentBar uses the **documented lifecycle hooks** of both tools. Claude Code posts
events to a loopback endpoint directly; Codex invokes a small compiled helper that
relays them.

It is a strictly additive layer. If AgentBar is not running, has crashed, or is
uninstalled, **both tools behave exactly as if it never existed.**

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
make check       # lint, test, ToS scan — run before every commit
```

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
