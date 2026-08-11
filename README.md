# claude-status

A floating desktop pet for macOS that reacts to Claude Code — including
sessions running on a **remote host over SSH**.

It shuffles its feet while Claude works, jitters with a pulsing ring when Claude
is blocked waiting on you, and shuts its eyes when nothing is running. A thought
bubble names the tool in flight. Sessions on a remote machine carry a badge with
that host's initial, so you can tell at a glance which box wants your attention.

Click it to bring Claude to the front.

---

## Why this exists

Comparable tools are local-only by construction.
[`gmr/claude-status`](https://github.com/gmr/claude-status) signals state
through a `.cstatus` file plus Darwin notifications — neither of which can cross
a machine boundary. Remote isn't a missing feature there; it's an architectural
exclusion.

This project uses **loopback HTTP**, which can cross that boundary, and that
single choice is the whole design:

```
  LOCAL                                 REMOTE (ssh)
  ─────                                 ────────────
  claude ──► hook ──► 127.0.0.1:7777    claude ──► hook ──► 127.0.0.1:7777
                          │                                     │
                          ▼                             SSH RemoteForward
                     [ the pet ]                                │
                          ▲                                     │
                          └─────────────────────────────────────┘
```

Hooks post to `127.0.0.1:7777` and never learn where they are. Locally that
address is the pet. Remotely it's an SSH reverse tunnel back to the pet.
**Identical plugin, identical configuration, both cases.**

---

## Requirements

- macOS 13 or later, for the pet
- Xcode's Swift toolchain (`swift build`)
- Claude Code on any machine you want to watch

No runtime dependencies. The HTTP listener is `Network.framework`, the pet is
drawn with AppKit, and the hook needs only `curl`.

---

## Install

### 1. The pet — on your Mac

```bash
git clone https://github.com/donaldheddesheimer/claude-status
cd claude-status/mac-app && swift run
```

| Gesture | Action |
|---|---|
| Click | Bring Claude to the front |
| Drag | Move it; the position persists |
| Right-click | Live session list, reset position, quit |

### 2. The plugin — on every machine running Claude Code

```
/plugin marketplace add donaldheddesheimer/claude-status
/plugin install claude-status@claude-status
```

Install it on your Mac for local sessions, on the remote box for SSH sessions,
or both. Nothing about the plugin differs between the two.

### 3. The tunnel — SSH only

See [Remote setup](#remote-setup-over-ssh) below.

---

## Remote setup over SSH

The pet runs on your Mac; Claude Code runs on the remote host. One SSH reverse
tunnel connects them.

**Step 1 — start the pet on your Mac.**

```bash
cd claude-status/mac-app && swift run
```

**Step 2 — add the tunnel to `~/.ssh/config` on your Mac.**

```
Host devbox
    HostName devbox.example.com
    User you
    RemoteForward 7777 127.0.0.1:7777
```

`RemoteForward` makes the remote host's `127.0.0.1:7777` a pipe back to your
Mac's `127.0.0.1:7777`. Both ends bind to loopback only — nothing is exposed to
any network, and it travels inside the SSH connection you already trust.

Or let the helper do it:

```bash
./scripts/setup-remote.sh devbox --write
```

**Step 3 — reconnect.** `RemoteForward` only applies to new connections, so an
existing session will not pick it up.

```bash
ssh devbox
```

**Step 4 — prove the tunnel works before installing anything.**

From the remote host:

```bash
curl -s -m 2 -o /dev/null -w 'HTTP %{http_code}\n' \
  -X POST http://127.0.0.1:7777/state \
  -H 'Content-Type: application/json' \
  --data-raw '{"state":"waiting","session_id":"tunnel-test","host":"devbox","remote":true}'
```

`HTTP 200` and a pulsing pet on your Mac means you're done. If you get a
connection refused, the tunnel isn't up — recheck steps 2 and 3.

**Step 5 — install the plugin on the remote host.**

```
/plugin marketplace add donaldheddesheimer/claude-status
/plugin install claude-status@claude-status
```

Every session on that host now drives the pet, in any directory, with no
per-session setup.

> **VS Code Remote-SSH** reads `~/.ssh/config`, so the same entry covers both
> the extension and a plain terminal. Remember that under Remote-SSH, Claude
> Code runs on the *remote* host — that's where the plugin belongs.

---

## States

| Hook event | Pet | Bubble |
|---|---|---|
| `UserPromptSubmit` | bobs, legs shuffling, eyes squint | `thinking` |
| `PreToolUse` / `PostToolUse` | bobs, legs shuffling, eyes squint | the tool name |
| `Notification` | jitters with a pulsing ring — **blocked on you** | `needs you` |
| `Stop` | settles, eyes open — idle | — |
| `SessionEnd` | forgets the session | — |

The thought bubble reports the most recent tool in flight, so a glance tells you
not just that Claude is busy but what it's busy doing. It stays quiet when idle.

**Idle vs. nothing running.** *Idle* means a session is alive and reporting but
not working — Claude finished its turn and is waiting for you to type. *Nothing
running* (eyes shut, dimmed) means no sessions at all.

Several sessions collapse into one mood, and **waiting outranks working** — the
session that needs you is the one worth surfacing.

Sessions that stop reporting are dropped on a timer, with the deadline
depending on what they were doing. A *working* session going quiet means
something broke, most likely a dropped tunnel, so it clears after 90 seconds
rather than stranding the pet mid-thought. An *idle* session going quiet is just
you not typing, so it's held for an hour. `SessionEnd` removes sessions cleanly
either way.

---

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_STATUS_PORT` | `7777` | Port used by both hook and pet |
| `CLAUDE_STATUS_CLICK_APP` | `/Applications/Claude.app` | What a click opens — app path or bundle id |
| `CLAUDE_STATUS_ART` | `~/.claude-status/pet.png` | Override artwork |
| `CLAUDE_STATUS_TOKEN_FILE` | `~/.claude-status/token` | Shared secret, if you want one |

The port is loopback-only at both ends and the SSH hop is already encrypted, so
a token is optional. To require one, create the file on both machines with
matching contents.

**Killswitch.** `touch ~/.claude-status/disabled` silences the hooks without
touching any configuration. Delete the file to resume.

---

## Artwork

The critter is drawn from a pixel map in
[`PetSprite.swift`](mac-app/Sources/StatusPet/PetSprite.swift) — no image files,
nothing to install, crisp at any scale. Body, legs and eyes are separate layers,
so it shuffles its feet and changes expression independently: squinting while it
works, wide-eyed when it needs you, lids shut when nothing is running.

To use your own pet, drop a PNG at `~/.claude-status/pet.png`. It replaces the
drawn sprite and still inherits the bounce, jitter and pulse.

---

## Troubleshooting

Run `/claude-status:status` inside any Claude Code session. It reports whether
you're local or remote, whether anything is listening on the port, and whether a
ping actually lands.

The hooks are built so they cannot hurt a session: `curl` is fully detached from
the hook's process group, capped at a one-second connect timeout, and the script
always exits 0. If the pet isn't running, your laptop is asleep, or the tunnel is
down, Claude Code never notices.

---

## Interoperability with petdex

Port `7777` and the `X-Petdex-Update-Token` header match
[petdex](https://github.com/agiagentsdev/agentpets-dev), so the two are wire
compatible. Run only one at a time, or both will drive the window.

---

## Architecture

| Path | Role |
|---|---|
| `hooks/hooks.json` | Maps six Claude Code lifecycle events to states |
| `hooks/emit.sh` | Reads the hook payload, posts state; dependency-free, always exits 0 |
| `mac-app/…/StateServer.swift` | Loopback HTTP listener on `Network.framework` |
| `mac-app/…/SessionStore.swift` | Tracks every session, collapses them to one mood |
| `mac-app/…/PetSprite.swift` | The critter's pixel map |
| `mac-app/…/PetWindow.swift` | Borderless floating panel and rendering |
| `scripts/setup-remote.sh` | Generates and verifies the SSH tunnel |

---

## License

MIT
