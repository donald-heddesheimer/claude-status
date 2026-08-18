#!/usr/bin/env bash
# claude-status: emit one lifecycle state event to the desktop pet.
#
# Invoked by hooks with the target state as $1 and, optionally, which agent
# is calling as $2 (default "claude-code" — Claude Code is still the only
# caller wired up by hooks.json in this repo). The hook's JSON payload comes
# on stdin. Runs on whatever machine the agent runs on:
#
#   local sessions  -> 127.0.0.1:7777 is the pet app itself
#   ssh sessions    -> 127.0.0.1:7777 is an SSH RemoteForward back to your Mac
#
# Identical config works in both cases, which is the whole point of using
# loopback HTTP rather than a file or a Darwin notification.
#
# $2 exists so another agent's hook config can point straight at this script
# rather than needing a fork of it — the payload shape assumed below
# (tool_name/tool_input/notification_type/session_id/cwd) is Claude Code's,
# but anything that mirrors it gets the same tool-name-to-detail extraction
# and Notification classification for free. An agent with a different shape
# still gets a working pet: every field defaults to empty rather than failing.
#
# This script must NEVER fail a session and must NEVER add latency. It always
# exits 0, and the network call is fully detached.

STATE="${1:-idle}"
AGENT="${2:-claude-code}"
# Keep this to a safe charset before it goes anywhere near JSON — $2 is a
# trusted literal from hooks.json today, but there's no reason to rely on
# that holding forever.
case "$AGENT" in
  *[!A-Za-z0-9_.-]*) AGENT="claude-code" ;;
esac

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
[ -n "$PAYLOAD" ] || PAYLOAD='{}'

# Which account produced this event.
#
# This matters because loopback is not private on a shared host. The SSH
# RemoteForward binds one 127.0.0.1:7777 for the *whole machine*, so every
# account on that box running claude-status posts into whoever's tunnel is up —
# their file names and permission prompts land on someone else's desktop. The
# pet needs to know who each event came from to keep that from happening.
USER_NAME="${USER:-$(id -un 2>/dev/null)}"

# Optional local guard. The pet does the real filtering — it's the only end that
# sees everyone's events — but if you set CLAUDE_STATUS_USER, this install stays
# quiet unless it's running as that account.
if [ -n "${CLAUDE_STATUS_USER:-}" ] && [ "$USER_NAME" != "$CLAUDE_STATUS_USER" ]; then
  exit 0
fi

HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"

# Mark whether this session is running through SSH. The pet uses this to badge
# remote work differently from local work.
if [ -n "$SSH_CONNECTION" ] || [ -n "$SSH_TTY" ] || [ -n "$SSH_CLIENT" ]; then
  REMOTE="true"
else
  REMOTE="false"
fi

FALLBACK_SESSION="pid-$PPID"

# ---------------------------------------------------------------- parsing
#
# The hook payload is real JSON: nested, with escaped quotes and embedded
# newlines in exactly the fields worth reading. It is parsed with a real parser
# rather than scraped with a regex, and the *outgoing* body is built by that
# same parser, so the escaping is never hand-rolled.
#
# The ladder is jq, then python3, then a regex fallback. jq is one process and
# beats the six-or-so `sed` invocations this used to cost; python3 is on
# essentially every machine that runs Claude Code. The fallback exists only so a
# bare container still gets a pet rather than an error, and is documented as
# best-effort — it cannot see nested objects reliably and gives up on escapes.
#
# Which of the three ran is not something the caller can influence, so there is
# no injection surface here: all three read the same stdin and emit one JSON
# object on stdout.

read -r -d '' JQ_PROGRAM <<'JQ'
def scrub: if type == "string" then gsub("[[:cntrl:]]"; "") else "" end;
def clip($n): .[0:$n];

. as $p
| (if ($p.tool_input | type) == "object" then $p.tool_input else {} end) as $ti
| (($p.tool_name // "") | scrub | clip(64)) as $tool

# A bare tool name says almost nothing — "Bash" and "Edit" are true of half the
# session. Pull the one field from tool_input that says what this call is
# actually about, so the pet can show "running tests" instead of "Bash".
| (if $tool == "Bash" or $tool == "BashOutput" then
     (if (($ti.description // "") | scrub) != ""
      then ($ti.description | scrub)
      # Claude writes a description for every Bash call; the bare command name
      # is only a fallback for payloads that somehow lack one.
      else (($ti.command // "") | scrub | split(" ") | .[0] // "") end)
   elif ($tool | test("^(Read|Edit|Write|MultiEdit|NotebookEdit)$")) then
     (($ti.file_path // "") | scrub | split("/") | .[-1] // "")
   elif ($tool == "Grep" or $tool == "Glob") then (($ti.pattern // "") | scrub)
   elif $tool == "WebFetch" then
     (($ti.url // "") | scrub | sub("^[A-Za-z][A-Za-z0-9+.-]*://"; "") | split("/") | .[0] // "")
   elif $tool == "WebSearch" then (($ti.query // "") | scrub)
   elif ($tool == "Task" or $tool == "Agent") then (($ti.description // "") | scrub)
   elif $tool == "AskUserQuestion" then (($ti.questions[0].question // "") | scrub)
   else "" end | clip(120)) as $detail

# The Notification hook fires for a whole family of events, only some of which
# mean "a human has to answer something". Notably it also fires 60s after a turn
# ends ("Claude is waiting for your input", notification_type=idle_prompt) —
# treating that as a permission prompt makes the pet demand attention right
# after a chat finishes, which is exactly wrong.
#
# Anything not on the blocked-on-you list falls back to idle: a false "needs
# you" is far more annoying than a missed one, so unknown types stay quiet.
| (($p.notification_type // "") | scrub) as $nt
# AskUserQuestion never fires a Notification event — Claude Code only sends
# PreToolUse/PostToolUse for it, both mapped to "working" by hooks.json. But
# unlike a slow Bash call, a pending AskUserQuestion is blocking by
# definition: it cannot resolve without you. PostToolUse carries
# tool_response; PreToolUse never does, so its absence is what tells the two
# apart.
| (($p.tool_response != null)) as $answered
| (if $state == "working" and $tool == "AskUserQuestion" and ($answered | not) then "waiting"
   elif $state != "waiting" then $state
   # Field absent — an older Claude Code that doesn't send it. Keep the previous
   # behaviour rather than silently going quiet.
   elif $nt == "" then "waiting"
   elif (["permission_prompt", "worker_permission_prompt", "agent_needs_input",
          "elicitation_dialog", "elicitation_url_dialog"] | index($nt)) then "waiting"
   else "idle" end) as $final_state

| (($p.session_id // "") | scrub | clip(128)) as $sid

| {
    state: $final_state,
    # Fall back to a per-terminal identity so events still group sensibly if the
    # payload is ever missing (manual runs, older versions).
    session_id: (if $sid == "" then $fallback else $sid end),
    user: ($user | clip(64)),
    host: ($host | clip(64)),
    remote: $remote,
    tool: $tool,
    detail: $detail,
    cwd: (($p.cwd // "") | scrub | clip(240)),
    agent_source: $agent
  }
JQ

build_body_jq() {
  printf '%s' "$PAYLOAD" | jq -c \
    --arg state "$STATE" \
    --arg user "$USER_NAME" \
    --arg host "$HOSTNAME_SHORT" \
    --argjson remote "$REMOTE" \
    --arg fallback "$FALLBACK_SESSION" \
    --arg agent "$AGENT" \
    "$JQ_PROGRAM" 2>/dev/null
}

build_body_python() {
  printf '%s' "$PAYLOAD" | python3 -c '
import json, re, sys

state, user, host, remote, fallback, agent = sys.argv[1:7]
control = re.compile(r"[\x00-\x1f\x7f]")

try:
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        payload = {}
except Exception:
    payload = {}

def scrub(value, limit):
    if not isinstance(value, str):
        return ""
    return control.sub("", value)[:limit]

tool_input = payload.get("tool_input")
if not isinstance(tool_input, dict):
    tool_input = {}

def field(name, limit=120):
    return scrub(tool_input.get(name), limit)

tool = scrub(payload.get("tool_name"), 64)

if tool in ("Bash", "BashOutput"):
    detail = field("description") or field("command").split(" ")[0]
elif tool in ("Read", "Edit", "Write", "MultiEdit", "NotebookEdit"):
    detail = field("file_path", 240).rsplit("/", 1)[-1][:120]
elif tool in ("Grep", "Glob"):
    detail = field("pattern")
elif tool == "WebFetch":
    detail = re.sub(r"^[A-Za-z][A-Za-z0-9+.-]*://", "", field("url", 240)).split("/")[0][:120]
elif tool == "WebSearch":
    detail = field("query")
elif tool in ("Task", "Agent"):
    detail = field("description")
elif tool == "AskUserQuestion":
    questions = tool_input.get("questions")
    first = questions[0] if isinstance(questions, list) and questions else None
    detail = scrub(first.get("question"), 120) if isinstance(first, dict) else ""
else:
    detail = ""

# AskUserQuestion never fires a Notification event, so unlike a permission
# prompt the pet would never learn it is blocking. PreToolUse and PostToolUse
# both map to "working"; PostToolUse alone carries tool_response, so its
# absence is what marks the call as still pending on you.
if state == "working" and tool == "AskUserQuestion" and payload.get("tool_response") is None:
    state = "waiting"

blocking = {
    "permission_prompt", "worker_permission_prompt", "agent_needs_input",
    "elicitation_dialog", "elicitation_url_dialog",
}
if state == "waiting":
    kind = scrub(payload.get("notification_type"), 64)
    state = "waiting" if (kind == "" or kind in blocking) else "idle"

json.dump({
    "state": state,
    "session_id": scrub(payload.get("session_id"), 128) or fallback,
    "user": user[:64],
    "host": host[:64],
    "remote": remote == "true",
    "tool": tool,
    "detail": detail,
    "cwd": scrub(payload.get("cwd"), 240),
    "agent_source": agent,
}, sys.stdout, separators=(",", ":"))
' "$STATE" "$USER_NAME" "$HOSTNAME_SHORT" "$REMOTE" "$FALLBACK_SESSION" "$AGENT" 2>/dev/null
}

# Best-effort only. Kept so a machine with neither jq nor python3 still shows a
# pet, at the cost of misreading anything nested or escaped.
build_body_fallback() {
  json_str() {
    printf '%s' "$PAYLOAD" \
      | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" \
      | head -n 1
  }
  # Strip anything that could break out of a JSON string literal.
  # shellcheck disable=SC1003  # '"\\' is a two-character set: a quote and a
  # backslash. Not an attempt to escape a single quote.
  sanitize() {
    printf '%s' "$1" | tr -d '"\\' | tr -d '\000-\037' | cut -c1-120
  }

  local tool session cwd detail nt state
  tool="$(sanitize "$(json_str tool_name)")"
  session="$(sanitize "$(json_str session_id)")"
  cwd="$(sanitize "$(json_str cwd)")"
  state="$STATE"

  case "$tool" in
    Bash|BashOutput)
      detail="$(json_str description)"
      [ -n "$detail" ] || detail="$(json_str command | cut -d' ' -f1)"
      ;;
    Read|Edit|Write|MultiEdit|NotebookEdit)
      detail="$(basename "$(json_str file_path)" 2>/dev/null)" ;;
    Grep|Glob)    detail="$(json_str pattern)" ;;
    WebFetch)     detail="$(json_str url | sed -e 's|^[a-z]*://||' -e 's|/.*||')" ;;
    WebSearch)    detail="$(json_str query)" ;;
    Task|Agent)   detail="$(json_str description)" ;;
    AskUserQuestion) detail="$(json_str question)" ;;
    *)            detail="" ;;
  esac
  detail="$(sanitize "$detail")"

  # AskUserQuestion never fires a Notification event, so unlike a permission
  # prompt the pet would never learn it's blocking. PreToolUse and PostToolUse
  # both map to "working"; PostToolUse alone carries tool_response, so its
  # absence marks the call as still pending on you.
  if [ "$state" = "working" ] && [ "$tool" = "AskUserQuestion" ]; then
    case "$PAYLOAD" in
      *'"tool_response"'*) : ;;
      *) state="waiting" ;;
    esac
  fi

  if [ "$state" = "waiting" ]; then
    nt="$(json_str notification_type)"
    case "$nt" in
      permission_prompt|worker_permission_prompt|agent_needs_input|elicitation_dialog|elicitation_url_dialog|"")
        state="waiting" ;;
      *)
        state="idle" ;;
    esac
  fi

  [ -n "$session" ] || session="$FALLBACK_SESSION"

  printf '{"state":"%s","session_id":"%s","user":"%s","host":"%s","remote":%s,"tool":"%s","detail":"%s","cwd":"%s","agent_source":"%s"}' \
    "$state" "$session" "$(sanitize "$USER_NAME")" "$(sanitize "$HOSTNAME_SHORT")" \
    "$REMOTE" "$tool" "$detail" "$cwd" "$AGENT"
}

BODY=""
if [ -z "${CLAUDE_STATUS_PARSER:-}" ] || [ "${CLAUDE_STATUS_PARSER}" = "jq" ]; then
  command -v jq >/dev/null 2>&1 && BODY="$(build_body_jq)"
fi
if [ -z "$BODY" ] && { [ -z "${CLAUDE_STATUS_PARSER:-}" ] || [ "${CLAUDE_STATUS_PARSER}" = "python" ]; }; then
  command -v python3 >/dev/null 2>&1 && BODY="$(build_body_python)"
fi
if [ -z "$BODY" ]; then
  BODY="$(build_body_fallback)"
fi

# A parser that produced nothing usable is not worth a malformed request.
case "$BODY" in
  '{'*'}') ;;
  *) exit 0 ;;
esac

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
# escapes, so " and \ are escaped going in. The body is already valid JSON, so
# any control character it contains is a two-character escape sequence rather
# than a literal, and doubling its backslash is exactly what preserves it.
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
