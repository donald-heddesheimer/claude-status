#!/usr/bin/env bash
# Consistency checks for the things that are easy to leave half-updated: the
# plugin manifest, the marketplace entry, the hook wiring and the changelog.
#
# Every one of these has a failure mode that is silent at build time and only
# shows up when someone tries to install the thing.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
cd "$ROOT" || exit 2

FAIL=0
pass() { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "check-manifests needs jq" >&2; exit 2; }

echo "Manifests"

# ---------------------------------------------------------------- well formed

for file in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  if jq empty "$file" 2>/dev/null; then
    pass "$file is valid JSON"
  else
    fail "$file is not valid JSON"
  fi
done

# ------------------------------------------------------------------- required

NAME="$(jq -r '.name // empty' .claude-plugin/plugin.json)"
VERSION="$(jq -r '.version // empty' .claude-plugin/plugin.json)"

if [ -n "$NAME" ]; then
  pass "plugin name: $NAME"
else
  fail "plugin.json has no name"
fi

if printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  pass "plugin version: $VERSION"
else
  fail "plugin.json version '$VERSION' is not semver"
fi

# The marketplace has to actually offer the plugin it claims to.
if jq -e --arg n "$NAME" '.plugins | map(.name) | index($n)' \
     .claude-plugin/marketplace.json >/dev/null; then
  pass "marketplace.json lists '$NAME'"
else
  fail "marketplace.json does not list a plugin called '$NAME'"
fi

# ----------------------------------------------------------------- hook paths

# A hook pointing at a script that does not exist fails once per session, in a
# place nobody is looking.
echo "Hooks"
MISSING=0
# shellcheck disable=SC2016  # ${CLAUDE_PLUGIN_ROOT} is Claude Code's own
# placeholder, matched literally. Expanding it is exactly what we must not do.
while IFS= read -r script; do
  if [ -f "$script" ]; then
    pass "$script exists"
  else
    fail "hooks.json references $script, which does not exist"
    MISSING=$((MISSING + 1))
  fi
done < <(jq -r '.hooks | to_entries[] | .value[] | .hooks[] | .command' hooks/hooks.json \
           | grep -o '\${CLAUDE_PLUGIN_ROOT}/[^"]*' | sed 's|${CLAUDE_PLUGIN_ROOT}/||' | sort -u)

EVENTS="$(jq -r '.hooks | keys | join(", ")' hooks/hooks.json)"
pass "events wired: $EVENTS"

# ------------------------------------------------------------------ changelog

echo "Changelog"
if [ ! -f CHANGELOG.md ]; then
  fail "CHANGELOG.md is missing"
else
  # The topmost version heading must be the version in the manifest, or the
  # release notes will describe something other than what shipped.
  TOP="$(grep -m1 -Eo '^## \[[0-9]+\.[0-9]+\.[0-9]+\]' CHANGELOG.md \
          | tr -d '#[] ' || true)"
  if [ "$TOP" = "$VERSION" ]; then
    pass "newest changelog entry ($TOP) matches plugin.json"
  else
    fail "newest changelog entry is '$TOP' but plugin.json says '$VERSION'"
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  printf '\033[31m%d check(s) failed\033[0m\n' "$FAIL"
  exit 1
fi
printf '\033[32mall manifest checks passed\033[0m\n'
