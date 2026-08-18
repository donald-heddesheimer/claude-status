#!/usr/bin/env bash
# Tests for hooks/emit.sh.
#
# Two kinds of test here, and both are needed:
#
#   * Most run emit.sh against a stub `curl` that captures the config it was
#     handed, and assert on the JSON body. Fast, and precise about parsing.
#
#   * One runs the whole thing against real curl and a real listener. That one
#     exists because a stub cannot tell you whether curl actually *accepts* the
#     config file being written. An earlier version of this hook passed every
#     stub test while real curl silently dropped both headers and truncated any
#     body containing a space, because unquoted config values end at the first
#     whitespace. Only an end-to-end test sees that.
#
# No dependencies beyond bash, python3 and curl.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMIT="$HERE/../hooks/emit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

ok() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
    printf '  ok   %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL %s\n       expected: %s\n       actual:   %s\n' "$label" "$expected" "$actual"
  fi
}

section() { printf '\n%s\n' "$1"; }

# ------------------------------------------------------------ stub harness

mkdir -p "$TMP/bin" "$TMP/home"
cat > "$TMP/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Stands in for curl -K -: record the config we were given and exit happy.
cat > "$CAPTURE"
STUB
chmod +x "$TMP/bin/curl"

# Runs emit.sh with the stub on PATH and an isolated HOME, and echoes the raw
# curl config it produced.
#
# The real curl call is detached on purpose — the hook must never make a session
# wait — so the capture file appears slightly after emit.sh returns.
capture() {
  local state="$1" payload="$2"
  shift 2

  local capture_file="$TMP/capture.$$.$RANDOM"
  rm -f "$capture_file"
  env PATH="$TMP/bin:$PATH" HOME="$TMP/home" CAPTURE="$capture_file" \
      "$@" bash "$EMIT" "$state" <<<"$payload" >/dev/null 2>&1

  local waited=0
  while [ ! -s "$capture_file" ] && [ "$waited" -lt 200 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  cat "$capture_file" 2>/dev/null
  rm -f "$capture_file"
}

# Pulls the JSON body back out of a curl config, undoing the config quoting the
# same way curl does.
body_of() {
  python3 -c '
import re, sys
config = sys.stdin.read()
match = re.search(r"^data = \"(.*)\"$", config, re.M)
if not match:
    sys.exit(0)
# Inside a quoted curl config value, a backslash escapes the next character.
sys.stdout.write(re.sub(r"\\(.)", r"\1", match.group(1)))
'
}

# Reads one field out of a JSON body. Prints <missing> rather than failing, so a
# malformed body shows up as a readable diff instead of a stack trace.
field() {
  python3 -c '
import json, sys
try:
    print(json.loads(sys.stdin.read()).get(sys.argv[1], "<missing>"))
except Exception as error:
    print("<invalid json: %s>" % error)
' "$1"
}

headers_of() {
  python3 -c '
import re, sys
print(",".join(sorted(re.findall(r"^header = \"([^:]+):", sys.stdin.read(), re.M))))
'
}

# Runs one payload through every parser the ladder can pick and checks they all
# say the same thing. A fallback that disagrees with jq is a bug waiting to
# surface on whichever machine happens to lack jq.
for_each_parser() {
  local state="$1" payload="$2" want_field="$3" want_value="$4"
  for parser in jq python fallback; do
    local body
    body="$(capture "$state" "$payload" CLAUDE_STATUS_PARSER="$parser" | body_of)"
    ok "[$parser] $want_field" "$want_value" "$(printf '%s' "$body" | field "$want_field")"
  done
}

# --------------------------------------------------------------- the tests

section "detail extraction"

for_each_parser working \
  '{"session_id":"abc","tool_name":"Bash","tool_input":{"description":"Run the integration tests","command":"pytest -q"}}' \
  detail "Run the integration tests"

for_each_parser working \
  '{"tool_name":"Edit","tool_input":{"file_path":"/home/donald/src/PetPack.swift"}}' \
  detail "PetPack.swift"

for_each_parser working \
  '{"tool_name":"Grep","tool_input":{"pattern":"notification_type"}}' \
  detail "notification_type"

for_each_parser working \
  '{"tool_name":"WebFetch","tool_input":{"url":"https://docs.example.com/a/b?q=1"}}' \
  detail "docs.example.com"

# A tool with nothing worth reporting should say nothing, not guess.
for_each_parser working '{"tool_name":"TodoWrite","tool_input":{"todos":[]}}' detail ""

section "notification classification"

# Fires 60s after a turn ends. Treating it as a permission prompt makes the pet
# demand attention right after a chat finishes, which is exactly wrong.
for_each_parser waiting '{"notification_type":"idle_prompt"}' state "idle"
for_each_parser waiting '{"notification_type":"permission_prompt"}' state "waiting"
for_each_parser waiting '{"notification_type":"agent_needs_input"}' state "waiting"
# Absent field means an older Claude Code; keep the previous behaviour.
for_each_parser waiting '{}' state "waiting"
# An unrecognised type stays quiet: a false "needs you" is worse than a missed one.
for_each_parser waiting '{"notification_type":"some_future_thing"}' state "idle"
# Only the waiting state is reclassified; nothing else is touched.
for_each_parser working '{"notification_type":"idle_prompt"}' state "working"

section "AskUserQuestion blocks without a Notification event"

# AskUserQuestion never gets a Notification hook — Claude Code only fires
# PreToolUse/PostToolUse, both mapped to "working" by hooks.json. PreToolUse
# never carries tool_response; that absence is the only signal that the call
# is still pending on a human, so it must read as "waiting" even though the
# hook only ever asked for "working".
for_each_parser working \
  '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Deploy to prod?"}]}}' \
  state "waiting"

for_each_parser working \
  '{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Deploy to prod?"}]}}' \
  detail "Deploy to prod?"

# PostToolUse carries tool_response once you have actually answered — the
# call is not pending on anyone anymore, so it goes back to "working".
for_each_parser working \
  '{"tool_name":"AskUserQuestion","tool_response":{"answer":"yes"}}' \
  state "working"

# Every other tool is unaffected — only AskUserQuestion gets this treatment.
for_each_parser working '{"tool_name":"Bash","tool_input":{"command":"ls"}}' state "working"

section "hostile input"

# Every one of these would break a hand-rolled JSON string. The body has to
# survive being embedded in a curl config and come back as valid JSON.
NASTY='{"session_id":"s1","tool_name":"Bash","tool_input":{"description":"say \"hi\" \\ then break\nnewline\ttab"}}'

for parser in jq python; do
  body="$(capture working "$NASTY" CLAUDE_STATUS_PARSER="$parser" | body_of)"
  ok "[$parser] hostile body is valid JSON" "valid" \
    "$(printf '%s' "$body" | python3 -c 'import json,sys
try:
    json.loads(sys.stdin.read()); print("valid")
except Exception as e:
    print("invalid: %s" % e)')"
  # Quotes and backslashes survive; control characters are stripped.
  ok "[$parser] quotes survive" "say \"hi\" \\ then breaknewlinetab" \
    "$(printf '%s' "$body" | field detail)"
done

# The fallback strips quotes and backslashes rather than escaping them. That is
# lossy but must still be *valid*, since a malformed body would be rejected.
body="$(capture working "$NASTY" CLAUDE_STATUS_PARSER=fallback | body_of)"
ok "[fallback] hostile body is still valid JSON" "valid" \
  "$(printf '%s' "$body" | python3 -c 'import json,sys
try:
    json.loads(sys.stdin.read()); print("valid")
except Exception as e:
    print("invalid: %s" % e)')"

section "nested payloads"

# The old regex scraper matched the first "description" anywhere in the flat
# text, so a description nested in an unrelated object won the race.
DEEP='{"tool_name":"Bash","extra":{"description":"WRONG"},"tool_input":{"description":"RIGHT"}}'
for parser in jq python; do
  ok "[$parser] reads tool_input, not the first match" "RIGHT" \
    "$(capture working "$DEEP" CLAUDE_STATUS_PARSER="$parser" | body_of | field detail)"
done

section "identity and fallbacks"

ok "session id falls back to the pid" "true" \
  "$(capture working '{"tool_name":"Read"}' | body_of | field session_id \
     | grep -q '^pid-[0-9]\+$' && echo true || echo false)"

ok "user is stamped" "$(id -un)" \
  "$(capture working '{}' | body_of | field user)"

ok "remote is false without SSH vars" "False" \
  "$(capture working '{}' | body_of | field remote)"

ok "remote is true under SSH" "True" \
  "$(capture working '{}' SSH_CONNECTION="10.0.0.1 22 10.0.0.2 22" | body_of | field remote)"

ok "agent is stamped" "claude-code" \
  "$(capture working '{}' | body_of | field agent_source)"

# $2 lets a hook config for another agent point straight at this script
# instead of forking it — Codex's hooks.json does exactly this.
capture_agent() {
  local state="$1" agent="$2" payload="$3"
  local capture_file="$TMP/capture.$$.$RANDOM"
  rm -f "$capture_file"
  env PATH="$TMP/bin:$PATH" HOME="$TMP/home" CAPTURE="$capture_file" \
      bash "$EMIT" "$state" "$agent" <<<"$payload" >/dev/null 2>&1
  local waited=0
  while [ ! -s "$capture_file" ] && [ "$waited" -lt 200 ]; do
    sleep 0.01
    waited=$((waited + 1))
  done
  cat "$capture_file" 2>/dev/null
  rm -f "$capture_file"
}

ok "a second agent is stamped as itself" "codex" \
  "$(capture_agent working codex '{}' | body_of | field agent_source)"

# No caller has ever been able to inject arbitrary JSON through $2 — bad
# characters fall back to the default rather than reaching the wire.
ok "a hostile agent name falls back to claude-code" "claude-code" \
  "$(capture_agent working '"};{"pwned":true' '{}' | body_of | field agent_source)"

section "silence"

touch "$TMP/home/killswitch"
ok "killswitch sends nothing" "" \
  "$(capture working '{"tool_name":"Bash"}' CLAUDE_STATUS_DISABLED_FILE="$TMP/home/killswitch")"
rm -f "$TMP/home/killswitch"

ok "wrong account sends nothing" "" \
  "$(capture working '{"tool_name":"Bash"}' CLAUDE_STATUS_USER="somebody-else")"

ok "matching account still sends" "Bash" \
  "$(capture working '{"tool_name":"Bash"}' CLAUDE_STATUS_USER="$(id -un)" | body_of | field tool)"

section "token handling"

mkdir -p "$TMP/home/.claude-status"
printf 'deadbeef0123456789abcdef\n' > "$TMP/home/.claude-status/token"
ok "token becomes a header" "Content-Type,X-Petdex-Update-Token" \
  "$(capture working '{}' | headers_of)"

# A token with characters that would end the config line early is dropped
# rather than sent truncated — half a secret authenticates as nothing and is
# far harder to diagnose than none.
printf 'has a space and "quotes"\n' > "$TMP/home/.claude-status/token"
ok "malformed token is omitted" "Content-Type" "$(capture working '{}' | headers_of)"
rm -f "$TMP/home/.claude-status/token"

section "end to end through real curl"

# The one test a stub cannot do. Real curl, real socket, real listener.
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 - "$PORT" "$TMP/received.json" <<'SERVER' &
import http.server, sys, json

port, target = int(sys.argv[1]), sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        with open(target, "wb") as handle:
            handle.write(json.dumps({
                "path": self.path,
                "content_type": self.headers.get("Content-Type"),
                "token": self.headers.get("X-Petdex-Update-Token"),
                "body": body.decode("utf-8", "replace"),
            }).encode())
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass

http.server.HTTPServer(("127.0.0.1", port), Handler).handle_request()
SERVER
SERVER_PID=$!
sleep 0.6

mkdir -p "$TMP/home/.claude-status"
printf 'abc123def456\n' > "$TMP/home/.claude-status/token"

# A description with spaces and quotes in it — exactly what used to be
# truncated at the first space by an unquoted config value.
env HOME="$TMP/home" CLAUDE_STATUS_PORT="$PORT" \
  bash "$EMIT" working \
  <<<'{"session_id":"e2e","tool_name":"Bash","tool_input":{"description":"Run the \"full\" suite now"}}' \
  >/dev/null 2>&1

waited=0
while [ ! -s "$TMP/received.json" ] && [ "$waited" -lt 300 ]; do sleep 0.01; waited=$((waited + 1)); done
wait "$SERVER_PID" 2>/dev/null

if [ -s "$TMP/received.json" ]; then
  # One field per line: the detail deliberately contains spaces, which is the
  # whole point of the test, so splitting on whitespace would defeat it.
  received_field() {
    python3 -c '
import json, sys
received = json.load(open(sys.argv[1]))
body = json.loads(received["body"])
print(body[sys.argv[2]] if sys.argv[2] in ("detail", "state") else received[sys.argv[2]])
' "$TMP/received.json" "$1"
  }
  got_path="$(received_field path)"
  got_type="$(received_field content_type)"
  got_token="$(received_field token)"
  got_state="$(received_field state)"
  got_detail="$(received_field detail)"
  ok "e2e path"         "/state"                      "$got_path"
  ok "e2e content type" "application/json"            "$got_type"
  ok "e2e token header" "abc123def456"                "$got_token"
  ok "e2e state"        "working"                     "$got_state"
  ok "e2e detail survives spaces and quotes" 'Run the "full" suite now' "$got_detail"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL end-to-end request never arrived\n'
fi

# ------------------------------------------------------------------ result

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
