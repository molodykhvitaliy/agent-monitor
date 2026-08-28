#!/usr/bin/env bash
#
# Installs a locally built AgentBar into /Applications.
#
# This exists because "build it yourself" has one irreversible trap in it.
# Requesting notification authorisation from a bundle inside DerivedData fails
# with UNErrorDomain Code=1, and macOS records that refusal against the bundle
# identifier **permanently** — re-signing, reinstalling and restarting usernoted
# all leave it denied, and the only way back is a switch in System Settings
# (docs/dev/platform-integration.md 6.3). So the app has to be in a stable
# location before it is ever launched, and the order matters enough to be a
# script rather than a sentence in a README.
#
# Environment:
#   APP_DESTINATION   where to install (default /Applications). Overridable so
#                     the guards below can be exercised without touching the copy
#                     currently monitoring your sessions.
set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="com.molodykhvitalii.AgentBar"
# The trailing slash is stripped deliberately. Shell tab-completion supplies one
# for a directory, and without this the path comparison below is built from
# `…/Applications//AgentBar.app` — which the filesystem resolves happily but
# which never matches the single-slash path `ps` reports, turning the guard that
# protects a running application into a no-op.
destination="${APP_DESTINATION:-/Applications}"
destination="${destination%/}"
target="$destination/AgentBar.app"
source_app="dist/AgentBar.app"

# Root would leave root-owned build products, a root-owned dist/ and a root-owned
# bundle behind, after which every later unprivileged run fails at `rm -rf dist`.
# The "not writable" message below is what provokes the reflex, so refuse first.
if [ "$(id -u)" -eq 0 ]; then
  echo "error: do not run this with sudo" >&2
  echo "  It would leave root-owned build products that later runs cannot remove." >&2
  echo "  If $destination is not writable, install elsewhere:" >&2
  echo "    APP_DESTINATION=\"\$HOME/Applications\" make install" >&2
  exit 1
fi

# Refuse to replace a bundle that is running out of the place we are about to
# overwrite. Matching on the executable path rather than on the process name
# alone keeps an installed copy from blocking an install to somewhere else.
#
# `ps -o comm=` reports the full executable path on macOS — verified, and the
# guard depends on it: if that ever changes, the match silently fails and the
# destructive path is allowed rather than blocked. `-ww` because BSD `ps`
# otherwise truncates its output to the terminal width.
running_pid() {
  local pid command_path
  for pid in $(pgrep -x AgentBar || true); do
    command_path=$(ps -ww -p "$pid" -o comm= 2>/dev/null || true)
    case "$command_path" in
      "$target"/*) printf '%s' "$pid"; return 0 ;;
    esac
  done
  return 0
}

refuse_if_running() {
  local pid
  pid=$(running_pid)
  if [ -n "$pid" ]; then
    echo "error: AgentBar is running from $target (pid $pid)" >&2
    echo "  Quit it from the menu-bar item first — replacing a running bundle" >&2
    echo "  leaves the live process reading files that are no longer there." >&2
    exit 1
  fi
}

refuse_if_running

# Checked before the build, not after it: a user who cannot write the
# destination should be told now rather than after a full Release compile.
if [ ! -d "$destination" ]; then
  echo "error: $destination does not exist" >&2
  exit 1
fi
if [ ! -w "$destination" ]; then
  echo "error: $destination is not writable by $(id -un)" >&2
  echo "  Install elsewhere with APP_DESTINATION=\"\$HOME/Applications\" make install." >&2
  exit 1
fi

# Never delete a path on the strength of its name. If something is already at the
# target, it has to identify itself as AgentBar before it is removed — the whole
# cost of getting this wrong is somebody else's application.
if [ -e "$target" ]; then
  existing=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
    "$target/Contents/Info.plist" 2>/dev/null || true)
  if [ "$existing" != "$BUNDLE_ID" ]; then
    echo "error: $target exists and is not AgentBar" >&2
    echo "  Its bundle identifier is '${existing:-unreadable}', not $BUNDLE_ID." >&2
    echo "  Refusing to remove it. Move it aside by hand if it really is stale." >&2
    echo "  An unreadable identifier can also mean a previous install was" >&2
    echo "  interrupted part-way; check the bundle before removing it yourself." >&2
    exit 1
  fi
fi

echo "==> Building the bundle to install"
./scripts/build-release.sh

if [ ! -d "$source_app" ]; then
  echo "error: $source_app was not produced" >&2
  exit 1
fi

# The build takes minutes, and anything can start AgentBar inside that window —
# a login item, or the user launching it while waiting. The guard is worth
# nothing if it is only checked before the wait.
refuse_if_running

# Staged beside the target and swapped, rather than removed and then copied. A
# ditto that fails halfway — disk full, an interrupt, an ACL on one file — must
# not be able to leave the machine with no application at all.
staging="$target.new"
rm -rf "$staging"
ditto "$source_app" "$staging"

if [ -e "$target" ]; then
  echo "==> Replacing the existing $target"
  rm -rf "$target"
fi
echo "==> Installing to $target"
mv "$staging" "$target"

cat <<EOF

Installed: $target

Next, in this order:

  1. Launch it from $destination — not from dist/ and not from DerivedData.
     Where the app is when it first asks for notifications is permanent.
  2. Allow notifications when macOS asks. If it never asks, the identifier was
     denied earlier: System Settings > Notifications > AgentBar.
  3. Finish onboarding — it installs the Claude Code and Codex hooks.

Updating later is the same command: git pull, then make install. Codex will not
re-ask for hook trust, because the hook names a stable path AgentBar owns rather
than a path inside the bundle.
EOF
