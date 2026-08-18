# AgentBar

Native macOS menu-bar app that monitors Claude Code and Codex coding sessions:
live status per project, configurable notifications, Codex quota, and keeping the
Mac awake while an agent works.

**This file is also `AGENTS.md` via symlink.** Edit `CLAUDE.md`; `AGENTS.md`
points at it so Claude Code and Codex read identical instructions.

The user's global engineering policy in `~/.claude/CLAUDE.md` applies. This file
overrides it where they conflict.

---

## Language

**All project output is in English** — source, comments, documentation, ADRs,
commit messages, pull requests and the app UI. This is a deliberate override of
the global Russian-commits default, confirmed 2026-08-18.

---

## Non-negotiables

Three rules outrank every feature. Violating any of them is a defect regardless
of what it enables.

### 1. Safe superset

AgentBar never patches, proxies, wraps or impersonates Claude Code or Codex. It
uses documented extension points only. **If AgentBar is not running, crashed, or
uninstalled, both tools must behave exactly as if it never existed.** Every
failure path resolves to "no opinion", never to a hang and never to an
unattended action.

### 2. ToS boundary

**AgentBar makes no network request to Anthropic or OpenAI. Ever.**

Read [docs/dev/tos-boundary.md](docs/dev/tos-boundary.md) before touching
networking, credentials or quota, and invoke the `tos-guard` skill. `make
tos-check` runs in CI and must pass.

### 3. Never auto-approve

No timeout, crash, parse failure or dropped connection may ever resolve into
granting a permission. This rule has no exceptions, and it applies pre-emptively
to the Approve/Deny work still in the backlog.

---

## Architecture

```
Claude Code ──[http hook]────────┐
                                 ├──► loopback ingest ──► SessionStore ──► UI
Codex ──[command hook]──► helper ─┘                          │
                                                             ├──► NotificationRouter
codex app-server ──[JSON-RPC/stdio]──► QuotaService ─────────┤
                                                             └──► CaffeineController
```

The core is provider-neutral. Adapters translate platform events into the domain
model, and **nothing above the adapter layer knows Claude Code or Codex exist**.
Raw provider JSON must not leak past an adapter.

See [docs/dev/architecture.md](docs/dev/architecture.md) for module boundaries and
[docs/dev/platform-integration.md](docs/dev/platform-integration.md) for verified
platform facts.

## Layout

```
Sources/
  AgentBarCore/          domain model, session state machine, store — no I/O
  AgentBarIngest/        loopback endpoint, auth, event decoding
  ClaudeCodeAdapter/     Claude Code hook payloads + settings.json installer
  CodexAdapter/          Codex hook payloads + hooks.json installer
  CodexAppServer/        JSON-RPC client, generated protocol models
  AgentBarNotifications/ notification routing and the sound matrix
  AgentBarPower/         IOPMAssertion lifecycle
  AgentBarUI/            SwiftUI views and view models
Apps/
  AgentBar/              app target — assembly, entitlements, Info.plist
  agentbar-helper/       compiled Codex hook bridge, must stay sub-10ms
Tests/
  ArchitectureTests/     module-boundary guards the compiler cannot express
schemas/appserver/       checked-in App Server schema, synced via make schema-sync
docs/dev/                long-lived engineering knowledge
docs/adr/                architecture decision records
scripts/                 tos-scan, schema sync, release helpers
```

Logic lives in SPM modules so tests run through `swift test` without an Xcode
build. CI spends macOS minutes carefully — they bill at 10× on a private
repository — by running policy checks on a Linux runner first and skipping the
macOS job entirely when only documentation changed.

## Build

The Xcode project is **generated** from `project.yml` and is not committed.

```bash
make bootstrap    # install xcodegen, generate the project
make build        # build the app
make test         # SPM tests, no Xcode needed
make lint         # swiftlint --strict, then swift-format lint --strict
make format       # apply swift-format in place
make tos-check    # ToS boundary scan
make check        # lint + test + tos-check — run before every commit
```

Never edit a generated `.xcodeproj`. Change `project.yml` and regenerate.

Module layout, toolchain settings, bundle layout and CI pinning are documented in
[docs/dev/build.md](docs/dev/build.md).

## Platform targets

macOS 26+, Swift 6 strict concurrency, SwiftUI with AppKit where SwiftUI is
insufficient. `LSUIElement = YES` — no Dock icon.

## Conventions

- Strong types at every boundary. No stringly-typed provider values above the
  adapter layer.
- Adapters decode defensively: unknown enum cases, absent fields and schema drift
  **degrade**, never crash. Every adapter is tested against recorded real
  payloads.
- Explicit error handling. No empty `catch`, no silent failure.
- Explicit `timeout` on every hook handler we install — never inherit the 600s
  default.
- Comments explain intent and constraint, not mechanics.
- No secrets in the repo. Signing material lives in CI secrets only.

## Installer rules

The installer edits files the user owns. It must:

- **merge, never overwrite** — foreign keys and foreign hook entries are untouched;
- back up to `*.bak.<timestamp>` before writing;
- be idempotent, marking its own entries so re-running changes nothing;
- uninstall cleanly, removing only its own entries;
- **never write `~/.codex/config.toml`** — `hooks.json` only. The `notify` slot in
  particular is already occupied on the developer's machine.

The user has existing `claude-notifier-*.js` and `caffeine.sh` hooks. The decision
is **peaceful coexistence**: detect and report the overlap, change nothing.

## Working process

`.scratch/` is local-only and never committed. The initiative plan lives in
`.scratch/plan/agentbar/MASTER-PLAN.md`; execute one step at a time with the
`step-execution` skill and keep `.scratch/handoff/agentbar/CURRENT.md` fresh.

Before touching a provider adapter, installer or quota code, invoke the
`platform-docs` skill. Remembered platform details are unreliable — the original
spec draft carried several confirmed errors.

Every session that changes code ends with an independent review by the `reviewer`
subagent.
