#!/usr/bin/env bash
# Wire Codex CLI's hooks to this pet, the same way Claude Code's plugin
# manifest does — Codex mirrors Claude Code's hook names and payload shape
# closely enough that hooks/emit.sh works unmodified, with "codex" passed as
# the agent ($2) so the pet can tell the two apart.
#
# Run this ON YOUR MAC, where the pet runs. Prints the hooks.json it would
# write and does nothing unless you pass --write, because silently
# overwriting another tool's config is a bad way to make friends — and
# ~/.codex/hooks.json may already be doing something else (petdex, say).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
EMIT="$REPO_ROOT/hooks/emit.sh"
TARGET="${CODEX_HOOKS_FILE:-$HOME/.codex/hooks.json}"
WRITE="${1:-}"

if [ ! -f "$EMIT" ]; then
  echo "error: $EMIT not found — run this from a clone of claude-status" >&2
  exit 1
fi

hook() {
  local state="$1"
  cat <<JSON
      [
        {
          "hooks": [
            {
              "type": "command",
              "command": "bash \\"$EMIT\\" $state codex"
            }
          ]
        }
      ]
JSON
}

RAW=$(cat <<JSON
{
  "hooks": {
    "UserPromptSubmit": $(hook thinking),
    "PreToolUse": $(hook working),
    "PostToolUse": $(hook working),
    "PermissionRequest": $(hook waiting),
    "Stop": $(hook idle)
  }
}
JSON
)
CONFIG="$(printf '%s' "$RAW" | python3 -m json.tool)"

echo "== This would replace $TARGET with: =="
echo
echo "$CONFIG"
echo

if [ "$WRITE" != "--write" ]; then
  echo "Dry run only — nothing written. Re-run with --write to apply."
  if [ -f "$TARGET" ]; then
    echo "(a backup of the current file would be made first: ${TARGET}.bak.<timestamp>)"
  fi
  exit 0
fi

if [ -f "$TARGET" ]; then
  BACKUP="${TARGET}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$TARGET" "$BACKUP"
  echo "backed up existing $TARGET to $BACKUP"
fi

mkdir -p "$(dirname "$TARGET")"
printf '%s\n' "$CONFIG" > "$TARGET"
echo "wrote $TARGET"
echo
echo "Restart Codex for the new hooks to take effect."
