#!/usr/bin/env bash
#
# Builds the distributable AgentBar bundle and packages it.
#
# AgentBar has no Apple Developer Program membership, so what this produces is an
# **ad-hoc signed, unnotarized** application: the same thing `make build` makes,
# built Release and packaged. That is a deliberate distribution decision, not a
# missing feature — see
# docs/adr/ADR-0015-distribution-is-source-first-until-a-developer-id-exists.md.
#
# Run by `make release` and by .github/workflows/release.yml, deliberately the
# same code: an artifact a contributor can reproduce locally is the only thing
# that makes an unsigned download checkable at all.
#
# Environment, all optional:
#   SIGNING_ENABLED    "true" re-signs with a Developer ID (step 13; never yet run)
#   SIGNING_IDENTITY   the identity to pass to codesign when it is
#   GITHUB_REF_NAME    a v-prefixed tag, asserted against MARKETING_VERSION
set -euo pipefail

cd "$(dirname "$0")/.."

DIST_DIR="dist"

# The settings are read before anything is built, so that a tag disagreeing with
# the version fails in seconds rather than after a five-minute Release build.
# `-showBuildSettings` needs the project generated, not compiled.
make generate

# `-showBuildSettings` is captured whole and split in the shell. Piping xcodebuild
# into a reader that closes early — `head -1`, `awk … exit` — makes it die on
# EPIPE with exit 134; it is a race, usually won locally and lost on a runner.
#
# stderr is captured to a separate file rather than merged into the same text.
# `read_setting` takes the first match, so a diagnostic line that merely contained
# ` MARKETING_VERSION = ` would decide what the release is named and what the tag
# is checked against. It is still printed on failure, which is the only reason to
# have kept it at all.
settings_errors=$(mktemp)
trap 'rm -f "$settings_errors"' EXIT
settings=$(xcodebuild -showBuildSettings \
  -project AgentBar.xcodeproj -scheme AgentBar \
  -configuration Release -destination 'platform=macOS' 2>"$settings_errors") || {
  cat "$settings_errors" >&2
  echo "error: xcodebuild -showBuildSettings failed — cannot locate the bundle" >&2
  exit 1
}

read_setting() {
  printf '%s\n' "$settings" | awk -F' = ' -v key=" $1 = " '
    index($0, key) { if (!seen++) print $2 }'
}

products=$(read_setting BUILT_PRODUCTS_DIR)
version=$(read_setting MARKETING_VERSION)
build_number=$(read_setting CURRENT_PROJECT_VERSION)

if [ -z "$products" ] || [ -z "$version" ]; then
  echo "error: BUILT_PRODUCTS_DIR or MARKETING_VERSION is absent from the build settings" >&2
  exit 1
fi

# A tag that disagrees with the version inside the bundle is the one release
# failure that is invisible afterwards: the download is named one thing and
# reports another from the About box and from every bug report.
if [ -n "${GITHUB_REF_NAME:-}" ] && [ "${GITHUB_REF_NAME#v}" != "$GITHUB_REF_NAME" ]; then
  tag_version="${GITHUB_REF_NAME#v}"
  if [ "$tag_version" != "$version" ]; then
    echo "error: tag '$GITHUB_REF_NAME' does not match MARKETING_VERSION '$version'" >&2
    echo "  Set MARKETING_VERSION in project.yml to $tag_version, or tag v$version." >&2
    exit 1
  fi
fi

echo "==> AgentBar $version (build $build_number)"

# Builds the app and certifies its layout in one step. `verify-bundle` is the
# check every earlier step leaned on and it had only ever run against Debug;
# passing CONFIGURATION here is what puts the shipped bundle under it too.
echo "==> Building Release and verifying the bundle layout"
make verify-bundle CONFIGURATION=Release

built_app="$products/AgentBar.app"
if [ ! -d "$built_app" ]; then
  echo "error: no Release bundle at $built_app" >&2
  exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
staged="$DIST_DIR/AgentBar.app"
ditto "$built_app" "$staged"

# Developer ID signing. This branch has NEVER been executed — there is no
# membership and therefore no certificate to test it with — so it is written to
# be obvious rather than clever, and step 13 is where it gets proved. It is kept
# here so that acquiring a certificate is a change of secrets rather than a
# rewrite of the pipeline. The nested helper is signed before its container:
# codesign seals inner code into the outer signature, so the order is not a
# preference.
if [ "${SIGNING_ENABLED:-false}" = "true" ]; then
  if [ -z "${SIGNING_IDENTITY:-}" ]; then
    echo "error: SIGNING_ENABLED is true but SIGNING_IDENTITY is empty" >&2
    exit 1
  fi
  echo "==> Signing with Developer ID (never yet exercised — see ADR-0015)"
  codesign --force --options runtime --timestamp \
    --sign "$SIGNING_IDENTITY" "$staged/Contents/MacOS/agentbar-helper"
  codesign --force --options runtime --timestamp \
    --entitlements Apps/AgentBar/AgentBar.entitlements \
    --sign "$SIGNING_IDENTITY" "$staged"
else
  echo "==> Unsigned build: keeping the ad-hoc signature xcodebuild applied"
fi

# Verifies whatever signature the bundle ended up with, ad-hoc included. An
# ad-hoc signature is not an identity, but a broken seal is still a broken app,
# and this is the only check that would catch a packaging step corrupting one.
echo "==> Verifying the signature"
codesign --verify --strict --deep --verbose=2 "$staged"

archive="$DIST_DIR/AgentBar-$version.zip"
echo "==> Packaging $archive"
# ditto, not zip: it preserves the symlinks, resource forks and extended
# attributes an app bundle's signature is computed over.
#
# `--sequesterRsrc` is not cosmetic, and it is easy to remove by mistake because
# the `__MACOSX` directory it produces looks like clutter. Measured on this
# artifact: without it, a recipient extracting with plain `unzip` gets "a sealed
# resource is missing or invalid". With it, they get a valid bundle. Recipients
# use unzip and Finder, not `ditto -x -k`, so the flag is what makes the
# documented instructions true.
ditto -c -k --sequesterRsrc --keepParent "$staged" "$archive"
( cd "$DIST_DIR" && shasum -a 256 "AgentBar-$version.zip" > "AgentBar-$version.zip.sha256" )

echo
echo "Built:"
ls -1 "$DIST_DIR"
echo
if [ "${SIGNING_ENABLED:-false}" != "true" ]; then
  cat <<'EOF'
This build is ad-hoc signed and not notarized. Apple's own syspolicy_check calls
such a build "not suitable for distribution", while noting that it "may run
locally" — which is exactly what it is for.

Copied here by hand, it runs as it is. Downloaded through a browser, it arrives
quarantined and Gatekeeper refuses it until the attribute is removed:

    xattr -d -r com.apple.quarantine /Applications/AgentBar.app

Building from source avoids the whole question: a locally built bundle is never
quarantined, because quarantine is applied by whatever downloads a file.
EOF
fi
