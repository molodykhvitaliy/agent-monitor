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

# Paths deliberately outside the scan, each for a stated reason.
not_scanned=(
  # Prose about the boundary necessarily quotes the hostnames the boundary
  # forbids, starting with tos-boundary.md itself.
  docs .claude README.md CLAUDE.md AGENTS.md LICENSE
  # Configuration, not code.
  .gitignore .swiftlint.yml .swift-format .editorconfig
  # Generated verbatim from the installed codex binary and not authored here. It
  # legitimately describes types such as ChatgptAuthTokensRefreshResponse.
  # Swift models generated from it live under Sources and are scanned there.
  schemas
)

# The target list is the one place this scan could still fail open: a new
# top-level directory that nobody added would simply never be looked at, and the
# run would report clean. Every top-level path must therefore be classified as
# either scanned or explicitly excluded — a one-line decision now, versus an
# unexamined hole discovered after a release.
#
# The classification is top-level only. A file added *inside* an excluded
# directory inherits that exclusion silently, which is why each exclusion above
# names a reason narrow enough to notice when it stops being true — and why
# .claude, the one excluded path that could plausibly gain executable content,
# gets its own check below.
if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  # core.quotePath=false: git otherwise escapes non-ASCII paths into "docs/\303\251.md",
  # whose first component would be reported as an unclassified phantom.
  tracked=$(git -c core.quotePath=false ls-files --cached)
  untracked=$(git -c core.quotePath=false ls-files --others --exclude-standard)

  # Process substitution swallows the producer's exit status, so the listing is
  # captured first and its emptiness treated as failure. A guard that reports
  # clean when it could not look is the hole this block exists to close.
  if [ -z "$tracked" ]; then
    echo "${RED}✗ Scan coverage: 'git ls-files' returned nothing — cannot verify coverage${RST}" >&2
    violations=$((violations + 1))
  else
    classify() {
      local listing="$1" label="$2" severity="$3" unclassified=()
      local entry known
      while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        for known in "${targets[@]}" "${not_scanned[@]}"; do
          [ "$entry" = "$known" ] && continue 2
        done
        unclassified+=("$entry")
      done <<< "$(printf '%s\n' "$listing" | awk -F/ 'NF{print $1}' | sort -u)"

      [ ${#unclassified[@]} -eq 0 ] && return 0
      if [ "$severity" = fatal ]; then
        echo "${RED}✗ Unclassified ${label} top-level paths — neither scanned nor excluded${RST}"
        printf '    %s\n' "${unclassified[@]}"
        echo "    Add each to 'targets' or to 'not_scanned' with a reason, in scripts/tos-scan.sh."
        violations=$((violations + 1))
      else
        # Untracked scratch files are the developer's business, not the
        # allowlist's. They are still worth naming, because an unscanned new
        # source directory looks exactly like this before it is committed.
        echo "${YEL}note: unclassified ${label} paths (not yet committed, so not scanned):${RST}"
        printf '    %s\n' "${unclassified[@]}"
      fi
    }
    classify "$tracked" tracked fatal
    [ -n "$untracked" ] && classify "$untracked" untracked advisory
  fi

  # .claude is excluded because it holds skill documentation, which has to quote
  # the hostnames the boundary forbids. That justification lasts exactly as long
  # as it stays documentation: hooks, settings.json command entries or scripts
  # there would be executable surface, and must be scanned.
  claude_unexpected=$(printf '%s\n%s\n' "$tracked" "$untracked" \
    | grep '^\.claude/' | grep -v '^\.claude/skills/.*\.md$' || true)
  if [ -n "$claude_unexpected" ]; then
    echo "${RED}✗ .claude/ holds more than skill documentation and is excluded from the scan${RST}"
    echo "$claude_unexpected" | sed 's/^/    /'
    echo "    Move it under a scanned path, or scan .claude and annotate the prose."
    violations=$((violations + 1))
  fi
else
  echo "${RED}✗ Scan coverage: not a git checkout — cannot verify that every path is scanned${RST}" >&2
  violations=$((violations + 1))
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
