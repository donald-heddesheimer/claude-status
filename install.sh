#!/usr/bin/env bash
# Install claude-status: build the pet, put it in /Applications, register the
# Claude Code plugin, and start it.
#
#   git clone https://github.com/donald-heddesheimer/claude-status
#   cd claude-status && ./install.sh
#
# Options:
#   --dev          Register the plugin from this clone instead of from GitHub.
#                  Hooks then run the scripts in this directory, so edits take
#                  effect immediately — and deleting the clone breaks them.
#   --no-plugin    Install the app only. Nothing will drive the pet until a
#                  plugin is installed on some machine.
#   --no-launch    Install without starting it.
#   --prefix DIR   Where the .app goes. Defaults to /Applications, falling back
#                  to ~/Applications when that is not writable.
#
# Building here rather than downloading a binary is deliberate. macOS quarantines
# anything downloaded and refuses to run it unless it is notarised by a paid
# Apple Developer account; software you compiled yourself is never quarantined.
# So for an unsigned project, building from source is the path that works without
# telling you to disable a security control.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="claude-status"
REPO="donald-heddesheimer/claude-status"
MARKETPLACE="claude-status"
PLUGIN="claude-status@claude-status"

PREFIX=""
DEV=false
WITH_PLUGIN=true
LAUNCH=true

while [ $# -gt 0 ]; do
  case "$1" in
    --dev)        DEV=true ;;
    --no-plugin)  WITH_PLUGIN=false ;;
    --no-launch)  LAUNCH=false ;;
    --prefix)     [ $# -ge 2 ] || { echo "--prefix needs a directory" >&2; exit 2; }
                  PREFIX="$2"; shift ;;
    # Reads the header block itself rather than a line range, which drifts the
    # moment anyone edits the comment.
    --help|-h)    awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' \
                    "${BASH_SOURCE[0]}"; exit 0 ;;
    *)            echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\033[1m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$1" >&2; }
info() { printf '    %s\n' "$1"; }

die() {
  printf '\033[31mInstall failed:\033[0m %s\n' "$1" >&2
  if [ $# -gt 1 ]; then
    printf '\n%s\n' "$2" >&2
  fi
  exit 1
}

# ------------------------------------------------------------------ preflight

step "Checking prerequisites"

[ "$(uname -s)" = "Darwin" ] || die "claude-status is a macOS app; this is $(uname -s)."

MACOS="$(sw_vers -productVersion)"
if [ "${MACOS%%.*}" -lt 13 ]; then
  die "macOS 13 or later is required (found $MACOS)." \
      "The pet uses SMAppService for launch-at-login, which does not exist before 13."
fi
info "macOS $MACOS"

# A missing toolchain is the single most likely failure, and the raw error
# ("xcrun: error: unable to find utility") tells you nothing about the fix.
if ! command -v swift >/dev/null 2>&1 || ! xcode-select -p >/dev/null 2>&1; then
  die "the Swift toolchain is not installed." \
      "Install Apple's command line tools, then run this again:

    xcode-select --install"
fi
info "$(swift --version 2>/dev/null | head -1)"

if [ "$WITH_PLUGIN" = true ] && ! command -v claude >/dev/null 2>&1; then
  warn "the 'claude' CLI is not on PATH — skipping plugin registration."
  warn "Install Claude Code, then register the plugin by hand (shown at the end)."
  WITH_PLUGIN=false
fi

# --------------------------------------------------------------------- build

step "Building the app"
info "no dependencies to fetch; this takes about ten seconds"

if ! "$HERE/scripts/build-app.sh" >/tmp/claude-status-build.$$ 2>&1; then
  tail -25 "/tmp/claude-status-build.$$" >&2
  # Two failures are common enough to name; both are one command to fix.
  if grep -qi 'license' "/tmp/claude-status-build.$$"; then
    die "the build failed because Xcode's licence has not been accepted." \
        "Run this, then try again:

    sudo xcodebuild -license accept"
  fi
  die "the build failed. The tail of the log is above; the full log is at /tmp/claude-status-build.$$"
fi
rm -f "/tmp/claude-status-build.$$"

BUILT="$HERE/build/$APP_NAME.app"
[ -d "$BUILT" ] || die "the build reported success but produced no app at $BUILT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' \
  "$BUILT/Contents/Info.plist" 2>/dev/null || echo "?")"
info "built $APP_NAME $VERSION"

# ------------------------------------------------------------------- install

if [ -z "$PREFIX" ]; then
  if [ -w /Applications ]; then
    PREFIX=/Applications
  else
    PREFIX="$HOME/Applications"
    warn "/Applications is not writable; installing to $PREFIX instead"
  fi
fi
mkdir -p "$PREFIX"
TARGET="$PREFIX/$APP_NAME.app"

step "Installing to $TARGET"

# Replacing a bundle while it is running leaves the old process attached to
# files that no longer exist. Stop it first — matched on the exact executable
# path, never a loose pattern, so this cannot reach an unrelated process.
if [ -d "$TARGET" ]; then
  RUNNING="$(pgrep -f "^$TARGET/Contents/MacOS/$APP_NAME$" || true)"
  if [ -n "$RUNNING" ]; then
    info "stopping the running copy (pid $RUNNING)"
    # shellcheck disable=SC2086
    kill $RUNNING 2>/dev/null || true
    sleep 1
  fi
fi

# ditto rather than cp: it preserves the code signature.
rm -rf "$TARGET"
ditto "$BUILT" "$TARGET"
info "installed"

# -------------------------------------------------------------------- plugin

if [ "$WITH_PLUGIN" = true ]; then
  step "Registering the Claude Code plugin"

  if claude plugin marketplace list 2>/dev/null | grep -q "^  ❯ $MARKETPLACE$"; then
    info "marketplace '$MARKETPLACE' already configured — leaving it alone"
  else
    # From GitHub by default, so the install is self-contained: the plugin keeps
    # working after this clone is deleted. --dev points it at the clone instead.
    SOURCE="$REPO"
    [ "$DEV" = true ] && SOURCE="$HERE"
    info "adding marketplace from $SOURCE"
    claude plugin marketplace add "$SOURCE" >/dev/null || \
      die "could not add the marketplace. Try it by hand: claude plugin marketplace add $SOURCE"
  fi

  if claude plugin list 2>/dev/null | grep -q "$PLUGIN"; then
    info "plugin already installed — leaving it alone"
  else
    claude plugin install "$PLUGIN" >/dev/null || \
      die "could not install the plugin. Try it by hand: claude plugin install $PLUGIN"
    info "installed $PLUGIN"
  fi
fi

# -------------------------------------------------------------------- launch

if [ "$LAUNCH" = true ]; then
  step "Starting the pet"
  open -a "$TARGET"
  # Long enough for the listener to bind or fail; short enough not to feel hung.
  sleep 2
  PORT=7777
  if lsof -nP -iTCP:$PORT -sTCP:LISTEN >/dev/null 2>&1; then
    info "listening on 127.0.0.1:$PORT"
  else
    warn "nothing is listening on port $PORT yet."
    warn "If another pet is already running, open Settings from the pet's"
    warn "right-click menu and choose a different port."
  fi
fi

# --------------------------------------------------------------------- done

echo
bold "Installed $APP_NAME $VERSION"
echo
echo "  Start it       open -a $APP_NAME"
echo "  Settings       right-click the pet"
echo "  Uninstall      rm -rf \"$TARGET\""
echo

if [ "$WITH_PLUGIN" = true ]; then
  echo "  Hooks apply to newly started Claude Code sessions. Open a new one and"
  echo "  the pet will start reacting."
else
  echo "  Nothing will drive the pet until you install the plugin on a machine"
  echo "  running Claude Code:"
  echo
  echo "      claude plugin marketplace add $REPO"
  echo "      claude plugin install $PLUGIN"
fi

echo
echo "  Watching a remote host over SSH, or sharing that host with other people?"
echo "  Both are covered in the README — the shared-host case in particular,"
echo "  since one SSH tunnel serves the whole machine."
echo
