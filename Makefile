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

# Depends on build: a bundle left over from an earlier commit would otherwise be
# certified as if it were the current one, which is the failure this target
# exists to catch.
.PHONY: verify-bundle
verify-bundle: build ## Assert the built app bundle has the layout later steps depend on
	@$(STRICT) \
	settings=$$(xcodebuild -showBuildSettings $(XCODEBUILD_FLAGS) 2>&1) || { \
	  printf '%s\n' "$$settings" >&2; \
	  echo "error: xcodebuild -showBuildSettings failed — cannot locate the bundle" >&2; \
	  exit 1; \
	}; \
	products=$$(printf '%s\n' "$$settings" \
	  | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{ if (!seen++) print $$2 }'); \
	if [ -z "$$products" ]; then \
	  echo "error: BUILT_PRODUCTS_DIR is absent from the build settings" >&2; exit 1; \
	fi; \
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
