#!/usr/bin/env bash
# Fail the build if the codebase drifts across the ToS boundary.
# See docs/dev/tos-boundary.md. Annotate reviewed exceptions with
# "tos-allow: <reason>" on the offending line.
#
# Deliberately not `set -e`: violations are accumulated across all categories so
# one run reports everything. Errors are still fatal — see run_check().
set -uo pipefail

cd "$(dirname "$0")/.." || { echo "tos-scan: cannot reach repository root" >&2; exit 2; }

RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; RST=$'\033[0m'
violations=0

# Source we author. Package manifests are included deliberately: ADR-0002 relies
# on no remote HTTP client entering the dependency graph.
targets=(Sources Tests Apps scripts .github project.yml Package.swift Package.resolved Makefile)
existing=()
for t in "${targets[@]}"; do [ -e "$t" ] && existing+=("$t"); done
if [ ${#existing[@]} -eq 0 ]; then
  echo "${RED}tos-scan: none of the expected scan targets exist — refusing to report clean${RST}" >&2
  exit 2
fi

run_check() {
  local label="$1" pattern="$2" hits status
  hits=$(grep -rniE --binary-files=without-match \
           --exclude-dir=.build --exclude-dir=build --exclude-dir=DerivedData \
           --exclude=tos-scan.sh \
           -- "$pattern" "${existing[@]}" 2>&1)
  status=$?
  # grep: 0 = matched, 1 = no match, >=2 = real error (bad regex, unreadable path).
  # Treating >=2 as "clean" would silently disable a category — the exact false
  # negative docs/dev/tos-boundary.md forbids.
  if [ "$status" -ge 2 ]; then
    echo "${RED}✗ ${label}: grep failed (status ${status})${RST}" >&2
    echo "$hits" | sed 's/^/    /' >&2
    violations=$((violations + 1))
    return
  fi
  hits=$(printf '%s\n' "$hits" | grep -v 'tos-allow:' | grep -v '^$')
  if [ -n "$hits" ]; then
    echo "${RED}✗ ${label}${RST}"
    echo "$hits" | sed 's/^/    /'
    violations=$((violations + 1))
  fi
}

run_check "Provider hostname in source" \
  '((api|console|statsig|[a-z0-9-]+)\.)?(anthropic|openai)\.com|claude\.ai|chatgpt\.com|oaiusercontent\.com'

run_check "Undocumented quota endpoint" \
  '(/api/oauth/usage|/api/codex/usage|/api/organizations/.*/usage)'

run_check "Credential file access" \
  '(\.credentials\.json|\.codex/auth\.json|SecItemCopyMatching|kSecClass)'

run_check "Provider credential handling" \
  '(oauth[_-]?token|refresh[_-]?token|access[_-]?token|sk-ant-|sk-proj-|x-api-key)'

run_check "Hook trust bypass" \
  'dangerously-bypass-hook-trust'

# Every exception must be visible and justified, or the allowlist rots silently.
annotations=$(grep -rn --binary-files=without-match \
                --exclude-dir=.build --exclude-dir=build --exclude-dir=DerivedData \
                --exclude=tos-scan.sh \
                -- 'tos-allow:' "${existing[@]}" 2>/dev/null || true)
if [ -n "$annotations" ]; then
  echo "${YEL}Active tos-allow exceptions:${RST}"
  echo "$annotations" | sed 's/^/    /'
  while IFS= read -r line; do
    reason=${line#*tos-allow:}
    if [ -z "${reason// /}" ]; then
      echo "${RED}✗ tos-allow annotation without a reason:${RST} $line"
      violations=$((violations + 1))
    fi
  done <<< "$annotations"
fi

if [ "$violations" -gt 0 ]; then
  echo
  echo "${RED}tos-scan failed with ${violations} category/categories.${RST}"
  echo "Read docs/dev/tos-boundary.md. If a hit is a reviewed false positive,"
  echo "annotate that line with a 'tos-allow: <reason>' comment."
  exit 1
fi

echo "${GRN}✓ tos-scan: no ToS boundary violations${RST}"
