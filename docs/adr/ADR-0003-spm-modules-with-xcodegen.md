---
id: ADR-0003
title: SPM modules with an XcodeGen-generated app project
status: accepted
date: 2026-08-18
supersedes: null
superseded_by: null
tags: [build, ci, tooling]
---

## Context

A macOS menu-bar app needs an `.app` bundle with `Info.plist`, entitlements and
signing. The repository is private for now, where GitHub-hosted **macOS runners
bill at a 10× minute multiplier**, so CI cost is a real design input.

## Decision drivers

- Tests must be cheap to run in CI.
- No merge conflicts in generated project files.
- Xcode must stay usable for debugging and Instruments.
- Reproducible builds from a clean checkout.

## Considered options

1. Plain committed `.xcodeproj`.
2. SPM modules plus an XcodeGen-generated project.
3. Pure SPM with a hand-rolled bundle script.

## Decision

**Option 2.** All logic lives in SPM modules under `Sources/`. The app and
helper targets are described in `project.yml`; `.xcodeproj` is generated and
git-ignored.

## Consequences

**Positive.** `swift test` runs the domain, ingest, adapter and quota suites
without an Xcode build, so most of the test signal costs a fraction of a full
`xcodebuild`. `project.yml` is a small reviewable diff instead of thousands of
lines of generated XML, and `.pbxproj` merge conflicts disappear. Module
boundaries are enforced by the compiler rather than by convention.

**Negative.** XcodeGen is an extra bootstrap dependency, and the project must be
regenerated after changing `project.yml` — a step contributors forget. `make
bootstrap` mitigates this.

The cost saving is smaller than it first appears: the modules still target
macOS 26 and several import AppKit, UserNotifications or IOKit, so **every test
job currently runs on a macOS runner**. Savings come from gating that job behind
a 1× Linux policy check and skipping it for documentation-only changes, not from
moving tests to Linux. Running `AgentBarCore` on a Linux runner is possible in
principle — it is deliberately free of platform imports — but needs a Swift
toolchain matching the pinned version, and is left unresolved rather than
claimed.

**Rejected and why.** A committed `.xcodeproj` forces every test into a macOS
runner at 10× cost and produces routine merge conflicts. Pure SPM makes
entitlements, resources, signing and Xcode debugging painful for no gain the
generated project does not already provide.
