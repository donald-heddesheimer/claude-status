#!/usr/bin/env bash
# Wire an SSH host so Claude Code sessions there can reach the pet on this Mac.
#
# Run this ON YOUR MAC. It prints the SSH config you need and verifies the
# tunnel end to end. It does not edit your ~/.ssh/config unless you pass
# --write, because silently rewriting SSH config is a bad way to make friends.
set -euo pipefail

PORT="${CLAUDE_STATUS_PORT:-7777}"
HOST="${1:-}"
WRITE="${2:-}"

if [ -z "$HOST" ]; then
  cat >&2 <<EOF
usage: setup-remote.sh <ssh-host-alias> [--write]

  <ssh-host-alias>  the Host name from your ~/.ssh/config, e.g. devbox
  --write           append the RemoteForward line to ~/.ssh/config

EOF
  exit 1
fi

BLOCK="Host ${HOST}
    RemoteForward ${PORT} 127.0.0.1:${PORT}"

echo "== 1. Is the pet running on this Mac? =="
if lsof -nP -iTCP:"${PORT}" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "   ok — something is listening on 127.0.0.1:${PORT}"
else
  echo "   NOT RUNNING. Start it first:  cd mac-app && swift run"
fi

echo
echo "== 2. SSH config =="
if grep -qE "^[[:space:]]*RemoteForward[[:space:]]+${PORT}[[:space:]]" "$HOME/.ssh/config" 2>/dev/null; then
  echo "   ok — a RemoteForward for ${PORT} already exists in ~/.ssh/config"
elif [ "$WRITE" = "--write" ]; then
  mkdir -p "$HOME/.ssh"
  printf '\n%s\n' "$BLOCK" >> "$HOME/.ssh/config"
  echo "   appended to ~/.ssh/config:"
  printf '%s\n' "$BLOCK" | sed 's/^/     /'
else
  echo "   MISSING. Add this to ~/.ssh/config (or re-run with --write):"
  echo
  printf '%s\n' "$BLOCK" | sed 's/^/     /'
fi

echo
echo "== 3. Verify the tunnel =="
echo "   Reconnect first — RemoteForward only applies to new connections."
echo
echo "   ssh ${HOST} 'curl -s -m 2 -o /dev/null -w \"HTTP %{http_code}\\n\" \\"
echo "     -X POST http://127.0.0.1:${PORT}/state \\"
echo "     -H \"Content-Type: application/json\" \\"
echo "     --data-raw \"{\\\"state\\\":\\\"waiting\\\",\\\"session_id\\\":\\\"tunnel-test\\\",\\\"host\\\":\\\"${HOST}\\\",\\\"remote\\\":true}\"'"
echo
echo "   HTTP 200 and a pulsing pet means you're done."
echo
echo "== 4. Install the plugin on ${HOST} =="
echo "   ssh ${HOST}, run claude, then:"
echo "     /plugin marketplace add donaldheddesheimer/claude-status"
echo "     /plugin install claude-status@claude-status"
