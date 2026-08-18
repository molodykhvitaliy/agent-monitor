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
	echo "bundle ok: helper at Contents/MacOS/agentbar-helper, LSUIElement = true"

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

.PHONY: check
check: lint test tos-check ## Everything that must pass before a commit

.PHONY: clean
clean: ## Remove build artifacts and the generated project
	@rm -rf .build build dist $(PROJECT)
