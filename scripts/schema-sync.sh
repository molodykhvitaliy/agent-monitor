#!/usr/bin/env bash
# Regenerate the Codex App Server protocol schema from the installed binary and
# diff it against the checked-in copy. The binary is authoritative — see
# docs/dev/platform-integration.md §3.1.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v codex >/dev/null 2>&1; then
  echo "codex CLI not found — cannot sync the App Server schema" >&2
  exit 1
fi

CHECKED_IN="schemas/appserver"
FRESH="$(mktemp -d)"
trap 'rm -rf "$FRESH"' EXIT

echo "Codex version: $(codex --version)"
codex app-server generate-json-schema --out "$FRESH" >/dev/null

if [ ! -d "$CHECKED_IN" ]; then
  echo "No checked-in schema yet — seeding $CHECKED_IN"
  mkdir -p "$CHECKED_IN"
  cp -R "$FRESH"/. "$CHECKED_IN"/
  echo "Seeded. Review and commit."
  exit 0
fi

# `-rq`, not `-ruq`: BSD diff rejects -u with -q as "conflicting output format
# options", which made this script report drift on every run whatever the schema
# said. The unified diff below is a separate invocation for exactly that reason.
if diff -rq "$CHECKED_IN" "$FRESH" >/dev/null; then
  echo "✓ App Server schema unchanged"
  exit 0
fi

echo "App Server schema drifted:"
diff -ru "$CHECKED_IN" "$FRESH" || true
echo
echo "Review the diff, run 'make generate-models', update docs/dev/platform-integration.md,"
# `rsync --delete`, not `cp -R`: a copy adds and overwrites but never removes, so
# a root the upstream schema drops would stay behind and this script would report
# drift on every run for ever after — the same permanent-drift failure the
# `diff -ruq` bug above caused, arriving through the other door.
echo "then replace the checked-in schema with:  rsync -a --delete \"$FRESH\"/ $CHECKED_IN/"
exit 1
