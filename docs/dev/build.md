# Build and Module Layout

How a clean checkout becomes a running app, and the decisions behind it. The
build system choice itself is [ADR-0003](../adr/ADR-0003-spm-modules-with-xcodegen.md);
this file records what that decision turned into and the facts it was verified
against.

**Verified:** 2026-08-18, against Swift 6.3.3 / Xcode 26.6 (17F113) / macOS 27.0.

---

## Entry points

```bash
make bootstrap      # brew install xcodegen swiftlint xcbeautify, then generate
make build          # xcodebuild the app bundle
make verify-bundle  # build, then assert the resulting bundle's layout
make test           # swift test — no Xcode needed
make lint           # swiftlint --strict, then swift-format lint --strict
make format         # swift-format in place
make check          # lint + test + tos-check — before every commit
```

`AgentBar.xcodeproj` is generated from `project.yml` and git-ignored. Editing it
is always a mistake; the change belongs in `project.yml`.

Tests run through `swift test` only. The generated scheme has no test action,
because the suites live in the Swift package rather than in an Xcode target, so
⌘U in Xcode does nothing — use the terminal or a package test target's inline
run button.

### Recipes set their own shell flags

macOS ships **GNU Make 3.81**, which predates `.SHELLFLAGS` (3.82) and ignores
it silently. Relying on it would mean `xcodebuild | xcbeautify` reports the
formatter's exit status, and `make build` returns 0 on a failed build — the one
check that the app compiles at all, inverted. Every recipe that pipes or runs
more than one command therefore begins with `$(STRICT)`, which is literally
`set -euo pipefail;`. Verified by breaking a source file and confirming
`make build` exits 65.

`make verify-bundle` exists for the same reason a test does: it asserts
`LSUIElement` is still true and the helper is still at
`Contents/MacOS/agentbar-helper`, resolving the products directory through
`xcodebuild -showBuildSettings` rather than guessing. It depends on `build`,
because certifying a bundle left over from an earlier commit is the failure it
exists to catch. CI runs it after `make build`, where the rebuild is a no-op.

## The module graph is the architecture

`Package.swift` holds every module. Dependencies point inward:

```
AgentBarCore  ← Ingest, ClaudeCodeAdapter, CodexAdapter, CodexAppServer,
                Notifications, Power, UI
```

AgentBarCore depends on nothing, and no module depends on a sibling. The app
target is the only place that links everything, because assembly is its job.

### Why a test, not just the manifest

A system framework needs no package dependency, so `import AppKit` inside
AgentBarCore compiles happily and the manifest never notices. `swift test`
therefore runs `Tests/ArchitectureTests`, which reads the source text and fails
on a platform import in AgentBarCore or on any intra-package edge the
allowed-dependency table does not list. Adding a module means adding it to that
table — an architectural decision the compiler cannot make silently.

AgentBarCore's check is an **allowlist** — `Foundation`, and nothing else. A
list of banned frameworks admits every framework nobody thought of, which is
exactly how a domain quietly acquires Dispatch, Combine or CryptoKit. Widening
the set is a deliberate edit to the test.

The scanner matches `import` as a token anywhere on a non-comment line rather
than only at its start, so nothing hides behind an attribute or a modifier —
`@_spi(A, B) import AppKit` and `internal import AppKit` are both caught. It errs
toward over-reporting: an `import` inside a string literal or a block comment
trips it. That is a loud, one-minute failure, where the opposite mistake is a
domain that quietly grew a dependency on AppKit.

The parser has its own tests. A boundary check is only as good as the parser
under it, and the interesting inputs either cannot be written as a compiling
fixture or would fail the suite for the wrong reason, so `ImportScannerTests`
drives it directly from a table.

## Toolchain

**Strict concurrency needs no opt-in.** `Package.swift` declares
`swiftLanguageModes: [.v6]`, and Xcode derives `SWIFT_STRICT_CONCURRENCY =
complete` from `SWIFT_VERSION = 6.0`. Both are stated explicitly anyway so the
guarantee is visible in a diff rather than inherited invisibly.

**`swift-tools-version: 6.2`, not 6.3.** Nothing in the package needs 6.3, and
the lower floor keeps it buildable on any Xcode 26 toolchain instead of only the
newest image.

**Default actor isolation.** AgentBarUI and the app target default to
`MainActor` — they are AppKit- and SwiftUI-facing throughout, so the alternative
is annotation noise. Every other module stays `nonisolated` by default,
including the helper, which must not pay for a main actor it never uses.

**Two linters, no overlap.** swift-format owns whitespace and line breaks;
SwiftLint owns correctness and clarity rules. Where they could disagree, the
SwiftLint rule is disabled in `.swiftlint.yml`, so `make lint` can never demand
two incompatible layouts. `.swift-format` is generated from the toolchain's own
`dump-configuration` with a small set of overrides, so a toolchain upgrade
cannot fail the build on a rule name that no longer exists.

`force_cast`, `force_try`, `force_unwrapping` and `implicitly_unwrapped_optional`
are errors rather than warnings, and `print()` is banned outside tests: silent
failure and invisible output are the two failure modes this project can least
afford.

## Bundle layout

```
AgentBar.app/Contents/
  Info.plist                LSUIElement = YES, LSMinimumSystemVersion = 26.0
  MacOS/AgentBar
  MacOS/agentbar-helper     the Codex hook bridge
```

Bundle identifier `com.molodykhvitalii.AgentBar`; the helper is
`com.molodykhvitalii.AgentBar.helper`.

**The helper ships inside the app from the first build on purpose.** Codex
records hook trust against the SHA of the hook definition, and that definition
contains the helper's path. A path that moves between releases re-triggers the
trust prompt and silently breaks event delivery until the user notices
([platform-integration.md §2.5](platform-integration.md)). Fixing the location
now costs nothing; changing it later costs every user a re-trust.

**Unsandboxed, deliberately.** `AgentBar.entitlements` sets
`com.apple.security.app-sandbox` to `false` rather than omitting it, because the
installer edits `~/.claude/settings.json` and `~/.codex/hooks.json` — which the
sandbox forbids, and which is why the Mac App Store is a stated non-goal.

Local and CI builds sign ad-hoc (`CODE_SIGN_IDENTITY = "-"`), so a clean
checkout builds with no Apple Developer account. Developer ID signing, the
hardened runtime and notarization arrive with step 12.

## Continuous integration

`macos-26` is pinned rather than `macos-latest`. Per the published
`actions/runner-images` manifest — read, not observed, since CI has not run yet
— it carries Xcode 26.0.1 through 26.6 with macOS SDKs 26.0–26.5, defaults to
26.6 (17F113) — the same build the platform facts were verified against — and
preinstalls xcbeautify 3.2.1, so CI installs only xcodegen and swiftlint.
`macos-latest` moved to macos-26 in June 2026 and will move again; pinning keeps
a future rotation from silently changing the SDK a release is built with.

Both workflows assert the **effective** Xcode version from `xcodebuild -version`
rather than the presence of a directory, so an `xcode-select` that quietly failed
still shows up. CI treats a mismatch as a warning written to the job summary, and
`release.yml` treats it as fatal: an image rotation should not block every pull
request, but it must never reach a distributable.

## Linux

Answering a question ADR-0003 left open: **AgentBarCore builds on Linux today**
(`swift build --target AgentBarCore` under `swift:6.3`,
`aarch64-unknown-linux-gnu`), but **the test suite cannot run there**, because
`swift test` builds every target and AgentBarUI imports AppKit.

Moving test signal to a 1× Linux runner would therefore need the package split,
which buys little: AgentBarCore has no dependencies, and the purity it would
prove is already enforced by `Tests/ArchitectureTests` at no CI cost. Worth
revisiting only if AgentBarCore ever acquires a dependency, where a real
compile against a non-Apple platform would catch what a source scan cannot.

## Codex App Server schema

`schemas/appserver/` is seeded by `make schema-sync` from the installed `codex`
binary and committed, so upstream drift shows up as a diff. It cannot run in CI
— GitHub runners have no `codex` binary — so drift is caught locally and
prompted weekly by `version-watch`.

The schema is a generated third-party artifact and is deliberately outside the
`tos-scan` target list: it legitimately contains type definitions such as
`ChatgptAuthTokensRefreshResponse.accessToken`. That exclusion is now named in
the script rather than implied by absence — `tos-scan.sh` fails on any top-level
path that is neither scanned nor explicitly excluded, so a future source
directory cannot go unexamined by accident.

Swift models generated from the schema in step 10 must cover only the account
and rate-limit surface AgentBar actually uses, or the scan will fire on the
generated code — correctly.
