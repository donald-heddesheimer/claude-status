---
description: Diagnose the claude-status desktop pet connection
---

Diagnose why the desktop pet is or isn't reacting. Run these checks and report
the results plainly — don't fix anything unless asked.

1. Am I running through SSH?

```bash
[ -n "$SSH_CONNECTION" ] && echo "remote session (ssh)" || echo "local session"
```

2. Is anything listening on the pet port on *this* machine? On a local Mac this
   should be the StatusPet app. On a remote host it should be the SSH
   RemoteForward.

```bash
(command -v lsof >/dev/null && lsof -nP -iTCP:7777 -sTCP:LISTEN) || echo "nothing on :7777"
```

3. Does a ping actually land?

```bash
curl -s -m 2 -o /dev/null -w 'HTTP %{http_code}\n' -X POST http://127.0.0.1:7777/state \
  -H 'Content-Type: application/json' \
  --data-raw '{"state":"waiting","session_id":"doctor","host":"'"$(hostname -s)"'","remote":false}' \
  || echo "no route to the pet"
```

4. Is the killswitch on?

```bash
[ -f "$HOME/.claude-status/disabled" ] && echo "DISABLED (rm ~/.claude-status/disabled to re-enable)" || echo "enabled"
```

Interpretation:

- `HTTP 200` means the pet received it. If it still didn't move, the app is
  running but the state didn't change — check the right-click menu for the
  session list.
- Connection refused on a **local** machine means the app isn't running.
  Start it from the repo: `cd mac-app && swift run`.
- Connection refused on a **remote** machine means the SSH tunnel isn't up.
  The Mac's `~/.ssh/config` needs `RemoteForward 7777 127.0.0.1:7777` for this
  host, and you must reconnect for it to take effect.
