#!/usr/bin/env bash
#
# Notarization is not implemented, and cannot be: it requires an Apple Developer
# Program membership, which this project does not have. AgentBar is distributed
# as source with an ad-hoc signed download — see
# docs/adr/ADR-0015-distribution-is-source-first-until-a-developer-id-exists.md.
#
# .github/workflows/release.yml calls this only when Apple Developer secrets are
# present, so on the current path it never runs. Failing loudly is deliberate: if
# a certificate appears, the release must stop here rather than publish something
# signed but unnotarized, which Gatekeeper treats no better than an unsigned
# build while looking to a reader as though it had been through the process.
set -euo pipefail

cat >&2 <<'EOF'
error: scripts/notarize.sh is not implemented.

Signing secrets are configured, so this release wanted a notarized build — but
notarization (xcrun notarytool submit --wait, then xcrun stapler staple) has
never been implemented or run here. Implement it before publishing a signed
build. See ADR-0015 for why it is deferred, and docs/dev/build.md for what the
signed path would have to prove.
EOF
exit 1
