# AgentBar — developer entry points.
# The Xcode project is generated; never edit a .xcodeproj by hand.

SHELL := /bin/bash
# -e so a failing tool fails the target, -o pipefail so a failing build is not
# masked by a successful formatter downstream of the pipe. Without these,
# `make check` silently passes on real failures.
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

PROJECT := AgentBar.xcodeproj
SCHEME  := AgentBar

.PHONY: help
help: ## Show available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: bootstrap
bootstrap: ## Install tooling and generate the Xcode project
	@for tool in xcodegen swiftlint xcbeautify; do \
	  command -v "$$tool" >/dev/null || brew install "$$tool"; \
	done
	@$(MAKE) generate

.PHONY: generate
generate: ## Regenerate the Xcode project from project.yml
	@if [ -f project.yml ]; then \
	  xcodegen generate; \
	else \
	  echo "note: no project.yml yet — skipping project generation"; \
	fi

.PHONY: build
build: generate ## Build the app
	@if [ ! -f project.yml ]; then \
	  echo "note: no project.yml yet — nothing to build"; \
	else \
	  xcodebuild build -project $(PROJECT) -scheme $(SCHEME) \
	    -configuration Debug -destination 'platform=macOS' | xcbeautify; \
	fi

.PHONY: test
test: ## Run SPM module tests (no Xcode required)
	@if [ -f Package.swift ]; then \
	  swift test --parallel; \
	else \
	  echo "note: no Package.swift yet — skipping tests"; \
	fi

.PHONY: lint
lint: ## Lint Swift sources
	@if ! command -v swiftlint >/dev/null; then \
	  echo "error: swiftlint not installed — run 'make bootstrap'" >&2; exit 1; \
	elif [ -d Sources ]; then \
	  swiftlint --quiet --strict; \
	else \
	  echo "note: no Sources/ yet — skipping lint"; \
	fi

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
