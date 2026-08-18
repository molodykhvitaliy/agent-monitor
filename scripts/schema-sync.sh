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

if diff -ruq "$CHECKED_IN" "$FRESH" >/dev/null; then
  echo "✓ App Server schema unchanged"
  exit 0
fi

echo "App Server schema drifted:"
diff -ru "$CHECKED_IN" "$FRESH" || true
echo
echo "Review the diff, regenerate models, update docs/dev/platform-integration.md,"
echo "then copy the fresh schema in with:  cp -R \"$FRESH\"/. $CHECKED_IN/"
exit 1
