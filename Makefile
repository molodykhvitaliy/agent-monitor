# AgentBar — developer entry points.
# The Xcode project is generated; never edit a .xcodeproj by hand.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# macOS ships GNU Make 3.81, which predates `.SHELLFLAGS` (3.82) and silently
# ignores it. Every recipe that pipes or runs more than one command therefore
# sets `set -euo pipefail` itself. This is not belt and braces: without an
# explicit pipefail, `xcodebuild | xcbeautify` reports the formatter's exit
# status, so `make build` returns 0 on a failed build — the whole point of the
# target, inverted.
STRICT := set -euo pipefail;

PROJECT := AgentBar.xcodeproj
SCHEME  := AgentBar
XCODEBUILD_FLAGS := -project $(PROJECT) -scheme $(SCHEME) \
                    -configuration Debug -destination 'platform=macOS'
# Directories holding first-party Swift. Kept in one place so the linters and
# the formatter cannot drift apart on what they cover.
SWIFT_PATHS := Sources Tests Apps
# The suites `make timing-proofs` runs alone. Matched against test and suite
# names, so it catches the urgent-queue proof inside the notification
# lifecycle suite without dragging the rest of that suite in.
TIMING_PROOF_FILTER := Latency|HelperTimingProof

.PHONY: help
help: ## Show available targets
	@$(STRICT) \
	grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: bootstrap
bootstrap: ## Install tooling and generate the Xcode project
	@$(STRICT) \
	for tool in xcodegen swiftlint xcbeautify; do \
	  command -v "$$tool" >/dev/null || brew install "$$tool"; \
	done
	@$(MAKE) generate

.PHONY: generate
generate: ## Regenerate the Xcode project from project.yml
	@xcodegen generate

.PHONY: build
build: generate ## Build the app
	@$(STRICT) \
	if command -v xcbeautify >/dev/null; then \
	  xcodebuild build $(XCODEBUILD_FLAGS) | xcbeautify; \
	else \
	  xcodebuild build $(XCODEBUILD_FLAGS); \
	fi

# Resolving BUILT_PRODUCTS_DIR is the same problem in two targets, and two
# copies that must agree is the situation `SWIFT_PATHS` exists to avoid. Leaves
# `$$products` set for the recipe that expands it.
#
# Two constraints on any future caller, because breaking either fails quietly
# rather than loudly: expand it **after `$(STRICT)`** — it relies on `-e` for
# nothing itself but everything downstream does — and keep it on the **same
# backslash-continued logical line** as what follows. On its own recipe line it
# would be a separate shell, leaving the next line with no `set -u` and an empty
# `$$products`, which yields wrong paths instead of an error.
#
# `-showBuildSettings` is read whole rather than piped into a reader that closes
# early: xcodebuild takes EPIPE on the next line and aborts with 134.
define RESOLVE_PRODUCTS
settings=$$(xcodebuild -showBuildSettings $(XCODEBUILD_FLAGS) 2>&1) || { \
  printf '%s\n' "$$settings" >&2; \
  echo "error: xcodebuild -showBuildSettings failed — cannot locate the bundle" >&2; \
  exit 1; \
}; \
products=$$(printf '%s\n' "$$settings" \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{ if (!seen++) print $$2 }'); \
if [ -z "$$products" ]; then \
  echo "error: BUILT_PRODUCTS_DIR is absent from the build settings" >&2; exit 1; \
fi;
endef

# Depends on build: a bundle left over from an earlier commit would otherwise be
# certified as if it were the current one, which is the failure this target
# exists to catch.
.PHONY: verify-bundle
verify-bundle: build ## Assert the built app bundle has the layout later steps depend on
	@$(STRICT) $(RESOLVE_PRODUCTS) \
	app="$$products/AgentBar.app"; \
	if [ ! -d "$$app" ]; then \
	  echo "error: no built bundle at $$app" >&2; exit 1; \
	fi; \
	if [ ! -x "$$app/Contents/MacOS/agentbar-helper" ]; then \
	  echo "error: agentbar-helper is not at Contents/MacOS/agentbar-helper" >&2; \
	  find "$$app" -type f >&2; exit 1; \
	fi; \
	if ! /usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$$app/Contents/Info.plist" \
	     | grep -qx true; then \
	  echo "error: LSUIElement is not true — the app would take a Dock icon" >&2; exit 1; \
	fi; \
	for sound in Question Waiting Finished Failed; do \
	  if [ ! -f "$$app/Contents/Resources/AgentBar $$sound.aiff" ]; then \
	    echo "error: 'AgentBar $$sound.aiff' is not at the top of Contents/Resources" >&2; \
	    echo "  UNNotificationSound looks only in the bundle root and ~/Library/Sounds," >&2; \
	    echo "  so a sound anywhere else plays as the default with no diagnostic." >&2; \
	    exit 1; \
	  fi; \
	done; \
	if ! /usr/libexec/PlistBuddy -c 'Print :CFBundleIconName' "$$app/Contents/Info.plist" \
	     >/dev/null 2>&1; then \
	  echo "error: CFBundleIconName is absent — the app would show a generic icon" >&2; \
	  exit 1; \
	fi; \
	if [ ! -f "$$app/Contents/Resources/Assets.car" ]; then \
	  echo "error: no Assets.car — the layered app icon was not compiled" >&2; \
	  echo "  AgentBar.icon has to reach actool; check the resources phase in project.yml." >&2; \
	  exit 1; \
	fi; \
	layers=$$(xcrun assetutil --info "$$app/Contents/Resources/Assets.car" 2>/dev/null); \
	for layer in network apex; do \
	  if ! printf '%s\n' "$$layers" | grep -q "AgentBar_Assets..$$layer"; then \
	    echo "error: the '$$layer' icon layer is not in Assets.car" >&2; \
	    echo "  A layered icon can compile to a tile with no mark on it — see" >&2; \
	    echo "  docs/dev/platform-integration.md 8.1 — and only the layers say so." >&2; \
	    exit 1; \
	  fi; \
	done; \
	echo "bundle ok: helper at Contents/MacOS/agentbar-helper, LSUIElement = true, 4 sounds, layered icon"

.PHONY: test
test: ## Run SPM module tests (no Xcode required)
	@swift test --parallel

# The measurements in the suite that only mean something when nothing else is
# running. Under `make test` all three are either skipped or assert a median,
# because swift-testing shares one cooperative pool across every suite and a tail
# measured there belongs to the runner's scheduler rather than to this code — see
# Tests/AgentBarIngestTests/LatencyTests.swift for the numbers that settled it.
# Here the process runs them serially and alone, so the numbers belong to the
# code and the strict assertions apply.
#
# Depends on `verify-bundle` for the reason that target depends on `build`: these
# are numbers that get attributed to the current commit and transcribed into
# docs/dev/platform-integration.md, and timing a bundle left over from an earlier
# commit would attribute them to the wrong code. CI's step order would happen to
# give the same guarantee; a dependency is a guarantee that survives reordering.
#
# Three ways this target could pass while measuring nothing, all closed. The
# helper proof is skipped when the binary is missing; `swift test --filter`
# **exits 0 when it matches nothing** — "Test run with 0 tests in 0 suites
# passed" — so a renamed suite would leave it green for ever; and the ingest
# tests print their numbers in both modes, so a line proves only that they ran
# and not that AGENTBAR_LATENCY_PROOF reached them. Hence the markers include
# `(isolated: tail asserted)`, which is printed only when the tail was asserted.
.PHONY: timing-proofs
timing-proofs: verify-bundle ## Run the timing proofs alone, where a tail means something
	@$(STRICT) $(RESOLVE_PRODUCTS) \
	helper="$$products/AgentBar.app/Contents/MacOS/agentbar-helper"; \
	if [ ! -x "$$helper" ]; then \
	  echo "error: no built helper at $$helper" >&2; \
	  echo "  verify-bundle is a prerequisite and asserts this same path, so" >&2; \
	  echo "  reaching this means the dependency was bypassed (make -o/-t, an" >&2; \
	  echo "  edited prerequisite, a race). Kept because the next line exports" >&2; \
	  echo "  it: without the binary the suite trait-disables itself, swift" >&2; \
	  echo "  test still exits 0, and the proof would go unmeasured again." >&2; \
	  exit 1; \
	fi; \
	log=$$(mktemp); \
	trap 'rm -f "$$log"' EXIT; \
	AGENTBAR_LATENCY_PROOF=1 \
	AGENTBAR_NOTIFICATION_LATENCY_PROOF=1 \
	AGENTBAR_HELPER_BINARY="$$helper" \
	  swift test --no-parallel --filter '$(TIMING_PROOF_FILTER)' 2>&1 | tee "$$log"; \
	for marker in \
	  'ingest latency [keep-alive] (isolated: tail asserted)' \
	  'ingest latency [connect + post] (isolated: tail asserted)' \
	  'urgent notification queue latency' \
	  'agentbar-helper: p50'; \
	do \
	  if ! grep -qF "$$marker" "$$log"; then \
	    echo "error: nothing printed '$$marker' — that proof did not run," >&2; \
	    echo "  or ran without asserting its strict bound. 'swift test --filter'" >&2; \
	    echo "  exits 0 when it matches nothing; check TIMING_PROOF_FILTER and" >&2; \
	    echo "  that the AGENTBAR_* variables above reached the test process." >&2; \
	    exit 1; \
	  fi; \
	done; \
	echo "timing proofs ok: all four measurements were taken in isolation"

.PHONY: lint
lint: ## Lint and check formatting of Swift sources
	@$(STRICT) \
	if ! command -v swiftlint >/dev/null; then \
	  echo "error: swiftlint not installed — run 'make bootstrap'" >&2; exit 1; \
	fi; \
	swiftlint --quiet --strict; \
	swift format lint --recursive --strict $(SWIFT_PATHS)

.PHONY: format
format: ## Apply swift-format in place
	@swift format format --recursive --in-place $(SWIFT_PATHS)

.PHONY: tos-check
tos-check: ## Scan for Terms of Service boundary violations
	@./scripts/tos-scan.sh

.PHONY: perf-probe
perf-probe: ## Measure a running AgentBar under synthetic load (app must be running)
	@./scripts/perf-probe.py

.PHONY: schema-sync
schema-sync: ## Regenerate and diff the Codex App Server protocol schema
	@./scripts/schema-sync.sh

# Two different kinds of drift, caught in two different places. `schema-sync`
# compares the checked-in schema against the installed `codex` and needs that
# binary, so it runs locally only; this compares the generated Swift against the
# checked-in schema and needs neither Codex nor a network, so CI runs it on
# every change.
.PHONY: generate-models
generate-models: ## Regenerate the Codex App Server Swift models from the schema
	@$(STRICT) \
	python3 scripts/generate-appserver-models.py; \
	swift format format --recursive --in-place Sources/CodexAppServer/Generated

.PHONY: check-generated
check-generated: generate-models ## Assert the generated models match the checked-in schema
	@$(STRICT) \
	if ! git ls-files --error-unmatch Sources/CodexAppServer/Generated >/dev/null 2>&1; then \
	  echo "error: the generated models are not tracked — this check would pass by looking at nothing" >&2; \
	  exit 1; \
	fi; \
	if ! git diff --quiet HEAD -- Sources/CodexAppServer/Generated; then \
	  echo "error: the generated App Server models are out of date" >&2; \
	  git --no-pager diff --stat HEAD -- Sources/CodexAppServer/Generated >&2; \
	  echo "  Run 'make generate-models' and commit the result." >&2; \
	  exit 1; \
	fi; \
	echo "generated models ok: they match schemas/appserver"

.PHONY: check
check: lint test tos-check check-generated ## Everything that must pass before a commit

.PHONY: clean
clean: ## Remove build artifacts and the generated project
	@rm -rf .build build dist $(PROJECT)
