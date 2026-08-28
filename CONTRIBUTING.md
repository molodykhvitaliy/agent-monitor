# Contributing to AgentBar

Thanks for looking. This is a small, opinionated project, and most of its
opinions are written down rather than enforced by taste — so the fastest way to
have a change accepted is to read what already exists about the area you are
touching.

## Getting a build

You need macOS 26 or later, Xcode (not just the command-line tools) and
[Homebrew](https://brew.sh). No Apple Developer account — the build signs ad-hoc
on purpose, so a clean checkout works for anyone.

```bash
make bootstrap    # xcodegen, swiftlint, xcbeautify, then generates the project
make build        # Debug build
make test         # swift test — no Xcode needed, and the fast loop
make check        # lint + test + ToS scan + generated models
```

`make check` is what CI runs and what must pass before a commit. `make install`
does a Release build and places it in `/Applications`; read the README's install
note before launching a build from anywhere else.

**Never edit `AgentBar.xcodeproj`.** It is generated from `project.yml` and is not
committed. Change the manifest and run `make generate`.

## Three rules that outrank features

A change that breaks any of these is a defect no matter what it enables.

1. **Safe superset.** AgentBar never patches, proxies, wraps or impersonates
   Claude Code or Codex, and uses documented extension points only. If AgentBar
   is absent, crashed or uninstalled, both tools must behave exactly as if it
   never existed.
2. **ToS boundary.** AgentBar makes no network request to Anthropic or OpenAI,
   ever, and holds no credentials. Read
   [docs/dev/tos-boundary.md](docs/dev/tos-boundary.md) before touching
   networking, credentials or quota. `make tos-check` runs in CI.
3. **Never auto-approve.** No timeout, crash, parse failure or dropped connection
   may resolve into granting a permission. There are no exceptions and the rule
   applies pre-emptively to work not yet done.

## How the code is organised

Logic lives in SPM modules under `Sources/` so tests run through `swift test`
without an Xcode build; `Apps/` holds only the two bundles and their assembly.
The core is provider-neutral, and **nothing above the adapter layer knows Claude
Code or Codex exist** — raw provider JSON must not leak past an adapter. Module
boundaries the compiler cannot express are enforced by `Tests/ArchitectureTests`.

[docs/dev/architecture.md](docs/dev/architecture.md) is the map.

## Conventions worth knowing before your first patch

- **Everything is in English** — source, comments, docs, commit messages, PRs and
  the interface.
- **Strong types at every boundary.** No stringly-typed provider values above the
  adapter layer.
- **Adapters degrade, never crash.** Unknown enum cases, absent fields and schema
  drift must all be survivable, and each adapter is tested against recorded
  payloads.
- **Explicit error handling.** No empty `catch`, no silent failure.
- **Comments explain intent and constraint, not mechanics.** A comment that
  restates the code is noise; one that records why a bound is 300 ms is the
  reason the next person does not undo it.
- The Codex App Server models are **generated** from the checked-in schema. Run
  `make generate-models`; `make check` fails if they disagree.

## Platform facts

Details of how Claude Code and Codex behave are verified against primary sources
and recorded in
[docs/dev/platform-integration.md](docs/dev/platform-integration.md) with a
verification date. Several confidently remembered "facts" turned out to be wrong
during this project's own development. If you are changing an adapter, an
installer or quota code, check the document — and if it is stale, say so in the
pull request rather than working around it.

## Architectural decisions

Decisions with real trade-offs live in [docs/adr/](docs/adr/) as ADRs. Accepted
ADRs are historical records: they are not rewritten when a decision changes, they
are superseded by a new one. If your change reverses something an ADR settled,
the ADR is part of the change.

## Pull requests

- One coherent change. Unrelated refactoring makes a diff hard to review and easy
  to reject.
- `make check` green, and say what else you ran.
- Say what you verified, and be exact about what you did **not**. "I did not test
  this against a real Codex session" is useful; silence in its place is not.
- New behaviour comes with a test. Where a guard matters, a test that fails when
  the guard is removed is worth more than one that passes with it.

## Reporting problems

Bugs and features go through the issue templates. For anything security-shaped,
read [SECURITY.md](SECURITY.md) first — please do not open a public issue for it.

Participation here is covered by the [Code of Conduct](CODE_OF_CONDUCT.md), which
also says plainly that this project has one maintainer rather than a moderation
team, and where to go when that is not the right address.
