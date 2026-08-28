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
make release        # Release build into dist/, packaged and checksummed
make install        # Release build, then place it in /Applications
make test           # swift test — no Xcode needed
make timing-proofs  # verify-bundle, then the stopwatch suites run alone
make lint           # swiftlint --strict, then swift-format lint --strict
make format         # swift-format in place
make check          # lint + test + tos-check + check-generated — before every commit
make schema-sync    # diff the checked-in App Server schema against the installed codex
make generate-models # regenerate the App Server Swift models from that schema
```

`AgentBar.xcodeproj` is generated from `project.yml` and git-ignored. Editing it
is always a mistake; the change belongs in `project.yml`.

Tests run through `swift test` only. The generated scheme has no test action,
because the suites live in the Swift package rather than in an Xcode target, so
⌘U in Xcode does nothing — use the terminal or a package test target's inline
run button.

Five suites are **off unless asked for**, because they do something to the machine
rather than only to memory, or because they need something the package alone
cannot give them. All are ordinary parts of the suite otherwise, and each is
worth running when the surface it covers changes:

```bash
AGENTBAR_RENDER=/tmp/agentbar swift test --filter AgentBarUITests    # writes PNGs
AGENTBAR_POWER_LIVE=1 swift test --filter AgentBarPowerTests         # real assertion
AGENTBAR_HELPER_BINARY=… swift test --filter HelperTimingProof       # the built helper
AGENTBAR_CODEX_LIVE=1 swift test --filter LiveReading                # the real account
AGENTBAR_NOTIFICATION_LATENCY_PROOF=1 swift test --filter urgentLatency  # the queue
```

Each is gated by a `.enabled(if:)` / `.disabled(if:)` **trait**, so an
unasked-for run reports *skipped* rather than passed. That distinction is not
cosmetic: the third and the fifth used an early `return` instead, which reports
*passed*, and both went unmeasured in CI for eleven steps because nobody had
reason to look.

One variable in the same family gates nothing. `AGENTBAR_LATENCY_PROOF=1` tells
`LatencyTests` to assert its tail rather than its median — that suite always
runs, and the variable chooses the statistic, not whether it executes. Why there
is a choice to make is
[a stopwatch cannot share a runner](#a-stopwatch-cannot-share-a-runner).

`make timing-proofs` sets that variable and the third and fifth above, and
supplies the built helper. It is how the timing measurements are meant to be
taken, and what CI runs.

The first renders every panel state and the settings window so a person can look
at them; it is what caught the provider badge drawing an ✕. The second takes a
real `IOPMAssertion`, reads `pmset`, and waits out a shortened watchdog and a
shortened lease — a suite that kept the developer's Mac awake on every run would
be its own bug.

The third measures `agentbar-helper` spawn-to-exit against a live endpoint, and
needs a **built** binary rather than only the package:

```bash
make build
products=$(xcodebuild -showBuildSettings -project AgentBar.xcodeproj -scheme AgentBar \
             -configuration Debug -destination 'platform=macOS' \
           | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{ if (!seen++) print $2 }')
AGENTBAR_HELPER_BINARY="$products/AgentBar.app/Contents/MacOS/agentbar-helper" \
  swift test --filter HelperTimingProof
```

`make timing-proofs` does all of that and runs the suite alone; the recipe
above is for when only this one is wanted. It compares against `/bin/cat` through
the same harness, so what it asserts is the helper's own share of the run rather
than what this machine charges to start any process at all — the number that
would otherwise fail on a busy laptop.

The fourth reads the developer's own Codex limits through the installed binary.
It is gated for a different reason from the others: it costs a network round
trip made by Codex against a real account, which is exactly the thing that must
never happen on a timer or on a runner. `ProcessTransportTests` covers the same
code against a shell script standing in for `codex`, and that one runs always.

The fifth measures how long an urgent notification waits in the router's queue.
It is gated only because hundreds of parallel tests can starve the cooperative
pool without changing the router's timer-free path — the same reason, and the
same remedy, as the ingest suite above.

### Two kinds of schema drift, caught in two places

`make schema-sync` regenerates the App Server protocol schema from the installed
`codex` and diffs it against `schemas/appserver`. It needs the binary, so it is
local-only and the weekly `version-watch` workflow is what prompts it.

`make check-generated` regenerates `Sources/CodexAppServer/Generated` from that
checked-in schema and asks git whether anything moved. It needs no Codex and no
network, so CI runs it on every change — a protocol update cannot land with
stale models behind it. It is part of `make check` for the same reason.

### Recipes set their own shell flags

macOS ships **GNU Make 3.81**, which predates `.SHELLFLAGS` (3.82) and ignores
it silently. Relying on it would mean `xcodebuild | xcbeautify` reports the
formatter's exit status, and `make build` returns 0 on a failed build — the one
check that the app compiles at all, inverted. Every recipe that pipes or runs
more than one command therefore begins with `$(STRICT)`, which is literally
`set -euo pipefail;`. Verified by breaking a source file and confirming
`make build` exits 65.

`make verify-bundle` exists for the same reason a test does: it asserts
`LSUIElement` is still true, that the helper is still at
`Contents/MacOS/agentbar-helper`, and that AgentBar's four notification sounds
are at the **top** of `Contents/Resources` — resolving the products directory
through `xcodebuild -showBuildSettings` rather than guessing. The sounds are
checked because `UNNotificationSound` looks only in the bundle root and in
`~/Library/Sounds`, so a resource phase that quietly stopped copying them would
ship a matrix whose every default silently plays the system sound, with no error
anywhere ([ADR-0006](../adr/ADR-0006-notification-sounds-are-files-agentbar-can-resolve.md)). It depends on `build`,
because certifying a bundle left over from an earlier commit is the failure it
exists to catch. CI runs it after `make build`, where the rebuild is a no-op.

## A stopwatch cannot share a runner

`make test` is `swift test --parallel`: swift-testing runs every suite
concurrently **in one process on one cooperative pool**. That is the right trade
for 831 correctness tests and the wrong one for a measurement. A GitHub
`macos-26` runner has three cores, and the suites competing for them include an
architecture scan that spends sixteen seconds of CPU and a pile of timer-driven
power and deadline tests.

The ingest latency suite showed exactly what that costs. Across twenty-two CI
runs its median held between 0.30 ms and 0.88 ms while its p99 walked from 8 ms
to 120 ms — in step with the number of tests co-scheduled beside it, not with any
change to `AgentBarIngest`. The tail eventually crossed the 100 ms ceiling and
failed a pull request that had not touched the module.

So the assertion follows the environment:

- under `make test` the ingest suite asserts a **median** and the other two are
  skipped. A handful of 120 ms stalls cannot move the median of 300 samples, and
  every regression the suite exists to catch — a per-request handshake, a lock
  held across a socket read, an accidental sleep — costs milliseconds on *every*
  request and moves it. `DeadlineTests.expiresPromptly` reached the same design
  independently.
- `make timing-proofs` runs those suites with `--no-parallel` and nothing else in
  the process, where the numbers belong to the code. Isolated on a developer Mac
  the ingest p99 is 0.4 ms against a 100 ms ceiling; the isolated number on a
  three-core runner is not yet known, and the first green run is worth reading.

Where a tail is asserted at all, it is asserted against something real. The
helper proof used to bound its `p95` at 100 ms, which was arithmetic rather than
a claim: `p95` over forty runs is the second-worst sample, so one stalled process
launch decided it, and over eight isolated runs on an idle Mac that number moved
between 8.8 ms and 75.8 ms. It now asserts the two things that mean something —
the helper's own share above a `/bin/cat` baseline measured on the same machine
(median, 5-7 ms against a 25 ms budget) and that no single run passes the one
second Codex gives a `SessionEnd` hook.

The target is also the only place two of the three measurements run at all.
`HelperTimingProof` needs a built helper and `RouterLifecycleTests`'s urgent-queue
proof needs an environment variable, and both used to skip with an early `return`
inside the test — which reports **passed**. That is how they sat green and
unmeasured through eleven steps of CI. Both are gated by a trait now, like every
other conditional suite here, so a skip reports *skipped*.

`timing-proofs` does not rely on that alone. It refuses to run without the built
helper, and it requires each proof's own printed line to be present — including
the `(isolated: tail asserted)` that the ingest suite prints only when the strict
statistic was in force. Three separate ways to a false green, all closed:
`swift test --filter` exits 0 when it matches nothing, a trait-skipped suite exits
0 too, and a test whose environment variable never arrived prints numbers that
look identical to asserted ones.

It depends on `verify-bundle` rather than on CI's step order, for the reason
`verify-bundle` depends on `build`: these numbers get attributed to a commit and
transcribed into [platform-integration.md](platform-integration.md) §2.6, and
timing a bundle left over from an earlier commit attributes them to the wrong
code.

**`make check` does not cover the tails.** It cannot: `timing-proofs` needs a
built app bundle and `check` is deliberately Xcode-free. The tails are a CI gate,
not a pre-commit one.

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

**What a clean machine needs.** macOS 26 or later, **Xcode** — not just the
command-line tools, because `actool` compiles the layered app icon and
`xcodebuild` builds a scheme — and Homebrew, which `make bootstrap` uses to
install xcodegen, swiftlint and xcbeautify. Nothing else, and no Apple Developer
account: that is what `CODE_SIGN_IDENTITY = "-"` is protecting.

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

**The helper ships inside the app as a signed deployment source.** At launch, and
again when the user presses `Connect` or `Repair`, AgentBar atomically copies it
to `~/Library/Application Support/AgentBar/bin/agentbar-helper`, preserving its
executable mode. Deliberately **not** on every status read: a report that writes
is a report that undoes an uninstall the moment the panel next opens. All hooks name that stable AgentBar-owned path because Codex
trust covers the complete hook definition, including the command. Debug,
distribution and installed copies can therefore refresh the executable without
rewriting the command or causing repeated trust drift
([ADR-0014](../adr/ADR-0014-codex-helper-has-a-stable-agentbar-owned-path.md)).

**Unsandboxed, deliberately.** `AgentBar.entitlements` sets
`com.apple.security.app-sandbox` to `false` rather than omitting it, because the
installer edits `~/.claude/settings.json` and `~/.codex/hooks.json` — which the
sandbox forbids, and which is why the Mac App Store is a stated non-goal.

Local and CI builds sign ad-hoc (`CODE_SIGN_IDENTITY = "-"`), so a clean
checkout builds with no Apple Developer account. That is the shipping
configuration, not a placeholder: there is no membership, so there is no
Developer ID signing, no hardened runtime and no notarization
([ADR-0015](../adr/ADR-0015-distribution-is-source-first-until-a-developer-id-exists.md)).
See *Distribution* below.

## Distribution

AgentBar is given away as **source**, with an unsigned build as a convenience.
There is no Apple Developer Program membership, so a Developer ID certificate,
notarization and everything downstream of them — Sparkle, a Homebrew Cask, a
Gatekeeper-clean download — are unavailable, not deferred by choice
([ADR-0015](../adr/ADR-0015-distribution-is-source-first-until-a-developer-id-exists.md)).

```bash
make release   # dist/AgentBar.app, AgentBar-<version>.zip, and its .sha256
make install   # the same build, placed in /Applications
```

Both call a script rather than doing the work in the recipe, because
`.github/workflows/release.yml` calls the same script: an artifact a contributor
can reproduce locally is the only thing that makes an unsigned download checkable
at all.

`scripts/build-release.sh` runs `make verify-bundle CONFIGURATION=Release` first.
That check had only ever certified Debug — the `CONFIGURATION` variable exists so
the bundle that actually ships goes through the layout assertions every earlier
step leaned on. It then packages with `ditto -c -k --sequesterRsrc --keepParent`,
never `zip -r`: an app bundle's signature is computed over symlinks, resource
forks and extended attributes that `zip` discards.

> **`--sequesterRsrc` is load-bearing, and for the opposite of the obvious
> reason.** It parks bundle metadata in a `__MACOSX` directory, which looks like
> clutter — so dropping it is tempting. Measured both ways on the real artifact:
>
> | Packaging | Extracted with plain `unzip` |
> |---|---|
> | `ditto -c -k --keepParent` | **`a sealed resource is missing or invalid`** |
> | `ditto -c -k --sequesterRsrc --keepParent` | valid |
>
> Recipients use `unzip` or Finder, not `ditto -x -k`. The flag is what makes the
> instruction in the README and the release notes actually work; without it, the
> first thing a downloader would meet is a bundle macOS calls damaged.

The Release product is a **universal binary** (`x86_64 arm64`, both the app and
the helper) — 18 MB installed, 6.5 MB compressed.

**The tag and the version must agree.** `build-release.sh` compares
`GITHUB_REF_NAME` against `MARKETING_VERSION` and refuses to package a
disagreement. A download named one version and reporting another from Diagnostics
is invisible once it is in someone's hands.

### What the signature is, and is not

Measured on the produced bundle, not recalled:

```
$ codesign -dv dist/AgentBar.app
Format=app bundle with Mach-O universal (x86_64 arm64)
Signature=adhoc
TeamIdentifier=not set

$ codesign --verify --strict --deep dist/AgentBar.app
dist/AgentBar.app: valid on disk
dist/AgentBar.app: satisfies its Designated Requirement

$ spctl --assess --type execute -vvv dist/AgentBar.app
dist/AgentBar.app: rejected                      # exit 3
```

The seal is intact; there is simply no identity behind it. `codesign --verify` is
still worth running — it is the only check that would catch a packaging step
corrupting the signature — but it says nothing about provenance.

Apple's own `syspolicy_check distribution` puts it exactly right:

> **Adhoc Signed App** — *Severity: Warning.* This app is adhoc signed. While it
> may run locally, adhoc signed apps are not suitable for distribution.
>
> **Notary Ticket Missing** — *Severity: Fatal.*

"May run locally" is the entire distribution strategy.

### Quarantine

`spctl` rejects the bundle whether or not it is quarantined — but Gatekeeper only
*enforces* on files carrying `com.apple.quarantine`, and that attribute is
applied by whatever downloads a file, never by the build. So:

- **A locally built bundle has no quarantine attribute** and is never assessed.
  Verified: `xattr dist/AgentBar.app` lists only `com.apple.provenance` and
  `com.apple.macl`.
- **A downloaded one carries it on every file inside the bundle.** Verified by
  quarantining `AgentBar-0.9.0.zip` and expanding it with `ditto -x -k`: the
  attribute lands on **16 paths** — the bundle root, `Contents`, both
  executables, `_CodeSignature`, every resource.

Which is why the documented removal is recursive:

```bash
xattr -d -r com.apple.quarantine /Applications/AgentBar.app
```

That clears all sixteen and the signature survives it —
`codesign --verify --strict --deep` still reports the bundle valid afterwards,
which is worth knowing because removing extended attributes from a signed bundle
sounds like it should not be safe.

> **`-r` is not universal.** `/usr/bin/xattr` on macOS 27 supports it. A
> `pip`-installed `xattr` earlier in `PATH` does not, and fails with `option -r
> not recognized` — which looks like the command being wrong rather than the
> binary being the wrong one. The README says so, because this happened on the
> development machine.

### Versioning

`MARKETING_VERSION` (`CFBundleShortVersionString`) and `CURRENT_PROJECT_VERSION`
(`CFBundleVersion`) both live in `project.yml` and are bumped by hand. A release
is a `v<MARKETING_VERSION>` tag; the guard above keeps the two from drifting.
`0.9.0` is the first public version — deliberately not `1.0.0`, because step 11's
own bar is seven consecutive days of ordinary use and that week has not been run.

### What a Developer ID would change

Step 13, blocked on the membership. The pipeline is already shaped for it:
`scripts/build-release.sh` has the signing branch, `release.yml` detects the
secrets and imports a keychain, and `scripts/notarize.sh` **fails rather than
no-ops** if it is ever reached — publishing something signed but unnotarized
would look to a reader as though it had been through a process it had not.

The branch has never executed. There is no certificate to test it with, and
saying so is more useful than the code looking finished.

## Two things a clean checkout cannot rebuild

**The four notification sounds.** The `.aiff` files are committed, so a build is
reproducible; what is not in the repository is what they were authored from.
`scripts/make-sounds.py` converts rather than synthesises, and it defaults to
`.scratch/audio-pack`, which is local-only and never committed
([ADR-0010](../adr/ADR-0010-notification-sounds-are-an-authored-pack.md)). To
change a sound, put the new source in that folder on the machine that has it and
re-run the script; the script is committed so the encoding stays in one place.
On any other machine, the committed `.aiff` files are the source.

**A string catalogue, because there is not one.** There are 93
`String(localized:comment:)` call sites and **no `.xcstrings`, no `.lproj` and no
`defaultLocalization`**. At runtime every call falls back to its key, which is
the English text, so the interface is correct — this is a recorded decision to
ship English-only rather than an oversight. Two consequences worth knowing before
anybody adds a catalogue: nothing is extractable today, so the 93 `comment:`
strings reach no tool; and a catalogue added to `AgentBarUI` will need
`bundle: .module` at every call site, because `String(localized:)` resolves
against `Bundle.main`.

## Continuous integration

CI spends macOS minutes carefully, and the reason it was written that way — a
private repository bills them at 10× — stops applying the day the repository goes
public. The frugality is kept anyway: the Linux guard job that runs the policy
checks first is faster feedback regardless of price, and a doc-only change that
skips a 25-minute macOS job is a better contributor experience than one that does
not.

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

> **`xcodebuild | head` aborts.** `xcodebuild` does not survive `EPIPE`: when a
> downstream reader closes the pipe early it throws
> `NSFileHandleOperationException` and dies with exit 134. `xcodebuild -version |
> head -1` therefore fails intermittently — it is a race, usually won on a
> developer's machine and lost on a runner, which is exactly how it reached CI.
> Capture the full output and split it in the shell. The same applies to
> `-showBuildSettings`: `make verify-bundle` reads the whole stream rather than
> `awk … exit`-ing out of it.

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
