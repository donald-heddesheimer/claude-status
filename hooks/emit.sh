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

# Which account produced this event.
#
# This matters because loopback is not private on a shared host. The SSH
# RemoteForward binds one 127.0.0.1:7777 for the *whole machine*, so every
# account on that box running claude-status posts into whoever's tunnel is up —
# their file names and permission prompts land on someone else's desktop. The
# pet needs to know who each event came from to keep that from happening.
USER_NAME="$(sanitize "${USER:-$(id -un 2>/dev/null)}")"

# Optional local guard. The pet does the real filtering — it's the only end that
# sees everyone's events — but if you set CLAUDE_STATUS_USER, this install stays
# quiet unless it's running as that account.
if [ -n "${CLAUDE_STATUS_USER:-}" ] && [ "$USER_NAME" != "$CLAUDE_STATUS_USER" ]; then
  exit 0
fi

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

BODY="{\"state\":\"${STATE}\",\"session_id\":\"${SESSION_ID}\",\"user\":\"${USER_NAME}\",\"host\":\"${HOSTNAME_SHORT}\",\"remote\":${REMOTE},\"tool\":\"${TOOL}\",\"detail\":\"${DETAIL}\",\"cwd\":\"${CWD}\",\"agent_source\":\"claude-code\"}"

TOKEN=""
if [ -r "$TOKEN_FILE" ]; then
  TOKEN="$(head -n 1 "$TOKEN_FILE" 2>/dev/null | tr -d '\r\n')"
  # A stray newline or quote would end the curl config line early and silently
  # truncate the secret, so hold the token to the characters it's generated
  # from rather than shipping a half one.
  case "$TOKEN" in
    *[!A-Za-z0-9_.:+/=-]*) TOKEN="" ;;
  esac
fi

# Fire and forget, fully detached from the hook's process group. Even if the
# far end is wedged behind a half-open SSH tunnel, the session never waits.
#
# The token and the body go to curl on **stdin**, never as arguments. Process
# command lines are world-readable on a shared host — anyone with an account can
# read /proc/<pid>/cmdline — so passing the shared secret as `-H` would publish
# it to every user on the box, along with the file names and descriptions in the
# body. A config file read from `-` keeps both out of the process table.
#
# Config values must be quoted: an unquoted one ends at the first space, which
# silently drops "Content-Type: application/json" down to "Content-Type:" and
# truncates any body containing a description. Quoted values honour backslash
# escapes, so " and \ are escaped going in — sanitize() has already stripped
# both from every field we interpolate, along with every control character, so
# what's left is only the punctuation this script emits itself.
ESCAPED_BODY="$(printf '%s' "$BODY" | sed 's/["\\]/\\&/g')"

(
  {
    printf 'url = "http://%s:%s/state"\n' "$HOST_ADDR" "$PORT"
    printf 'header = "Content-Type: application/json"\n'
    [ -n "$TOKEN" ] && printf 'header = "X-Petdex-Update-Token: %s"\n' "$TOKEN"
    printf 'data = "%s"\n' "$ESCAPED_BODY"
  } | curl -K - -s -o /dev/null --connect-timeout 1 --max-time 2
) >/dev/null 2>&1 &

exit 0
