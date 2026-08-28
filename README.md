# AgentBar

Native macOS menu-bar app for monitoring [Claude Code](https://code.claude.com)
and [OpenAI Codex](https://learn.chatgpt.com) coding sessions.

> **Open source, built from source.** There is no Apple Developer Program
> membership behind this project, so there is no signed, notarized download — and
> rather than pretend otherwise, the recommended way in is to build it yourself,
> which takes two commands and no account of any kind. A tagged release also
> publishes an unsigned build for people who would rather not
> ([why](docs/adr/ADR-0015-distribution-is-source-first-until-a-developer-id-exists.md)).

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

## Install

You need macOS 26 or later, **Xcode** (not just the command-line tools — the
build compiles a layered app icon with `actool`), and [Homebrew](https://brew.sh),
which `make bootstrap` uses to install the three tools it needs.

```bash
git clone https://github.com/molodykhvitaliy/agent-monitor.git
cd agent-monitor
make bootstrap    # installs xcodegen, swiftlint, xcbeautify; generates the project
make install      # Release build, then places it in /Applications
```

Then, **in this order**:

1. **Launch it from `/Applications`.** Not from `dist/`, and not from Xcode's
   build directory.
2. **Allow notifications** when macOS asks.
3. **Finish onboarding** — it installs the Claude Code and Codex hooks, and Codex
   will ask you to approve its hook in `/hooks`.

> **Launch it from `/Applications` and nowhere else, the first time.** Asking for
> notification permission from a bundle inside Xcode's `DerivedData` fails, and
> macOS records that refusal against the app's identifier **permanently** —
> reinstalling does not undo it, and the only way back is a switch in System
> Settings. `make install` exists to make the right order the easy one. The
> details are in
> [docs/dev/platform-integration.md](docs/dev/platform-integration.md) §6.3.

## Updating

```bash
git pull && make install
```

Quit AgentBar from its menu-bar item first — `make install` refuses to replace a
bundle it is running out of. Codex will **not** ask you to approve its hook
again: the hook names a stable path AgentBar owns rather than one inside the app
bundle.

## Downloading instead

Each tagged release carries `AgentBar-<version>.zip` and its SHA-256. That build
is **ad-hoc signed and not notarized**, because notarization requires the
membership this project does not have. macOS quarantines anything a browser
downloads, so Gatekeeper will refuse it until you say otherwise:

```bash
shasum -a 256 -c AgentBar-*.zip.sha256   # catches a truncated or corrupted download
unzip AgentBar-*.zip
# Updating? Quit AgentBar from its menu-bar item, then remove the old bundle —
# mv refuses to merge over one that is already there.
rm -rf /Applications/AgentBar.app
mv AgentBar.app /Applications/
xattr -d -r com.apple.quarantine /Applications/AgentBar.app
open /Applications/AgentBar.app
```

If `xattr` reports `option -r not recognized`, a `pip`-installed `xattr` is
shadowing the system one — use `/usr/bin/xattr`.

**The checksum is not a signature.** It is published by the same job, on the same
release page, as the file it describes, and nothing signs either — so it tells
you the download arrived intact, and nothing at all about whether the release
itself is what the author intended. Only notarization would tell you that, and
there is none.

Clearing quarantine is you deciding to trust a binary a stranger built. Building
from source means you do not have to: it is the same application, from source you
can read, and it never acquires the attribute in the first place.

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

## Development

```bash
make check       # lint, test, ToS scan, generated models — before every commit
make build       # Debug build
make release     # Release build, packaged into dist/
```

The interface is English-only and there is no string catalogue: every
`String(localized:)` falls back to its key, which is the English text. Adding a
catalogue is a deliberate later step, not an oversight — see
[docs/dev/build.md](docs/dev/build.md).

The Xcode project is generated from `project.yml` and is not committed.

| Document | Contents |
|---|---|
| [CONTRIBUTING.md](CONTRIBUTING.md) | how to build, check and propose a change |
| [SECURITY.md](SECURITY.md) | reporting a vulnerability, and what is in scope |
| [CLAUDE.md](CLAUDE.md) | project instructions (also `AGENTS.md`) |
| [docs/dev/architecture.md](docs/dev/architecture.md) | module boundaries, domain model |
| [docs/dev/build.md](docs/dev/build.md) | build system, toolchain, bundle layout, distribution |
| [docs/dev/platform-integration.md](docs/dev/platform-integration.md) | verified platform facts |
| [docs/dev/tos-boundary.md](docs/dev/tos-boundary.md) | hard project limits |
| [docs/adr/](docs/adr/) | architecture decision records |

## Affiliation

AgentBar is an independent project. It is **not affiliated with, endorsed by, or
sponsored by Anthropic or OpenAI.** Claude, Claude Code, OpenAI and Codex are
their respective owners' names, used here only to say accurately which tools
AgentBar observes. The provider marks drawn in the interface are original generic
shapes for exactly this reason — see
[docs/dev/design-system.md](docs/dev/design-system.md).

## License

[Apache License 2.0](LICENSE). © 2026 Vitaliy Molodykh.
