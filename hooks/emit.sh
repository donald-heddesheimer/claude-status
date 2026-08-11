#!/usr/bin/env bash
# claude-status: emit one lifecycle state event to the desktop pet.
#
# Invoked by Claude Code hooks with the target state as $1, and the hook's
# JSON payload on stdin. Runs on whatever machine Claude Code runs on:
#
#   local sessions  -> 127.0.0.1:7777 is the pet app itself
#   ssh sessions    -> 127.0.0.1:7777 is an SSH RemoteForward back to your Mac
#
# Identical config works in both cases, which is the whole point of using
# loopback HTTP rather than a file or a Darwin notification.
#
# This script must NEVER fail a session and must NEVER add latency. It always
# exits 0, and the network call is fully detached.

STATE="${1:-idle}"

PORT="${CLAUDE_STATUS_PORT:-7777}"
HOST_ADDR="${CLAUDE_STATUS_HOST:-127.0.0.1}"
TOKEN_FILE="${CLAUDE_STATUS_TOKEN_FILE:-$HOME/.claude-status/token}"
KILLSWITCH="${CLAUDE_STATUS_DISABLED_FILE:-$HOME/.claude-status/disabled}"

# Killswitch: `touch ~/.claude-status/disabled` silences the pet without
# touching any config.
[ -f "$KILLSWITCH" ] && exit 0

# curl is the only hard dependency. If it's missing, do nothing quietly.
command -v curl >/dev/null 2>&1 || exit 0

PAYLOAD=""
# Read stdin only if it's available; guard so a manual run doesn't block.
if [ ! -t 0 ]; then
  PAYLOAD="$(cat 2>/dev/null)"
fi

# Pull a value out of the hook JSON without requiring jq/node/python.
# Good enough for the flat, machine-generated fields we need.
json_str() {
  printf '%s' "$PAYLOAD" \
    | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
    | head -n 1
}

# Strip anything that could break out of a JSON string literal.
sanitize() {
  printf '%s' "$1" | tr -d '"\\' | tr -d '\000-\037' | cut -c1-120
}

SESSION_ID="$(sanitize "$(json_str session_id)")"
TOOL="$(sanitize "$(json_str tool_name)")"
CWD="$(sanitize "$(json_str cwd)")"

# A bare tool name says almost nothing — "Bash" and "Edit" are true of half the
# session. Pull the one field from tool_input that says what this call is
# actually about, so the pet can show "running tests" instead of "Bash".
# json_str scrapes the flat text, so nested tool_input keys resolve fine.
case "$TOOL" in
  Bash|BashOutput)
    # Claude writes a short description for every Bash call; it beats anything
    # we could derive from the command line itself.
    DETAIL="$(json_str description)"
    [ -n "$DETAIL" ] || DETAIL="$(json_str command | cut -d' ' -f1)"
    ;;
  Read|Edit|Write|MultiEdit|NotebookEdit)
    DETAIL="$(basename "$(json_str file_path)" 2>/dev/null)"
    ;;
  Grep|Glob)
    DETAIL="$(json_str pattern)"
    ;;
  WebFetch)
    DETAIL="$(json_str url | sed -e 's|^[a-z]*://||' -e 's|/.*||')"
    ;;
  WebSearch)
    DETAIL="$(json_str query)"
    ;;
  Task|Agent)
    DETAIL="$(json_str description)"
    ;;
  *)
    DETAIL=""
    ;;
esac
DETAIL="$(sanitize "$DETAIL")"

# The Notification hook fires for a whole family of events, only some of which
# mean "a human has to answer something". Notably it also fires 60s after a turn
# ends ("Claude is waiting for your input", notification_type=idle_prompt) —
# treating that as a permission prompt makes the pet demand attention right
# after a chat finishes, which is exactly wrong.
#
# So re-classify using notification_type. Anything not on the blocked-on-you
# list falls back to idle: a false "needs you" is far more annoying than a
# missed one, so unknown types stay quiet.
if [ "$STATE" = "waiting" ]; then
  case "$(json_str notification_type)" in
    permission_prompt|worker_permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog)
      STATE="waiting"
      ;;
    "")
      # Field absent — an older Claude Code that doesn't send it. Keep the
      # previous behaviour rather than silently going quiet.
      STATE="waiting"
      ;;
    *)
      STATE="idle"
      ;;
  esac
fi

# Fall back to a per-terminal identity so events still group sensibly if the
# payload is ever missing (manual runs, older versions).
[ -n "$SESSION_ID" ] || SESSION_ID="pid-$PPID"

HOSTNAME_SHORT="$(sanitize "$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)")"

# Mark whether this session is running through SSH. The pet uses this to badge
# remote work differently from local work.
if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ] || [ -n "$SSH_CLIENT" ]; then
  REMOTE="true"
else
  REMOTE="false"
fi

BODY="{\"state\":\"${STATE}\",\"session_id\":\"${SESSION_ID}\",\"host\":\"${HOSTNAME_SHORT}\",\"remote\":${REMOTE},\"tool\":\"${TOOL}\",\"detail\":\"${DETAIL}\",\"cwd\":\"${CWD}\",\"agent_source\":\"claude-code\"}"

TOKEN=""
if [ -r "$TOKEN_FILE" ]; then
  TOKEN="$(head -n 1 "$TOKEN_FILE" 2>/dev/null | tr -d '\r\n')"
fi

# Fire and forget, fully detached from the hook's process group. Even if the
# far end is wedged behind a half-open SSH tunnel, the session never waits.
(
  if [ -n "$TOKEN" ]; then
    curl -s -o /dev/null \
      --connect-timeout 1 --max-time 2 \
      -X POST "http://${HOST_ADDR}:${PORT}/state" \
      -H 'Content-Type: application/json' \
      -H "X-Petdex-Update-Token: ${TOKEN}" \
      --data-raw "$BODY"
  else
    curl -s -o /dev/null \
      --connect-timeout 1 --max-time 2 \
      -X POST "http://${HOST_ADDR}:${PORT}/state" \
      -H 'Content-Type: application/json' \
      --data-raw "$BODY"
  fi
) >/dev/null 2>&1 &

exit 0
