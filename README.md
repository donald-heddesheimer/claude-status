# claude-status

A floating desktop pet for macOS that reacts to Claude Code — including
sessions running on a **remote host over SSH**.

It shuffles its feet while Claude works, jitters with a pulsing ring when Claude
is blocked waiting on you, and shuts its eyes when nothing is running. A thought
bubble says what Claude is actually doing — `editing SessionStore.swift`, not
`Edit`. Sessions on a remote machine carry a badge with that host's initial, so
you can tell at a glance which box wants your attention.

Hover for the full picture; click to bring Claude to the front.

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
git clone https://github.com/donald-heddesheimer/claude-status
cd claude-status/mac-app && swift run
```

| Gesture | Action |
|---|---|
| Click | Bring Claude to the front |
| Drag | Move it; the position persists |
| Right-click | Session list — pick one to pin the pet to it — reset position, quit |

### 2. The plugin — on every machine running Claude Code

```
/plugin marketplace add donald-heddesheimer/claude-status
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
/plugin marketplace add donald-heddesheimer/claude-status
/plugin install claude-status@claude-status
```

Every session on that host now drives the pet, in any directory, with no
per-session setup.

> **VS Code Remote-SSH** reads `~/.ssh/config`, so the same entry covers both
> the extension and a plain terminal. Remember that under Remote-SSH, Claude
> Code runs on the *remote* host — that's where the plugin belongs.

### Shared hosts

Loopback is per-machine, not per-user. `RemoteForward` binds **one**
`127.0.0.1:7777` for the whole box, and it belongs to whoever connected — so on
a host you share with colleagues, their claude-status hooks post into *your*
tunnel. Their file names and Bash descriptions appear on your desktop, and their
permission prompts make your pet ask for attention you can't act on.

Name the accounts that are actually yours:

```bash
echo donald > ~/.claude-status/users
```

Or `CLAUDE_STATUS_USERS=donald,donald.heddesheimer`. Your own Mac account is
always allowed, so a filter added for a remote host never silences local work.
Unconfigured, the pet accepts everyone — the right default on a machine only you
use.

Events carrying no account at all come from a plugin older than 0.1.3. Local
ones are kept, since they reached the port from a process on your own Mac.
Remote ones are dropped, since they came down a tunnel from a machine you may
share — which is the whole point.

**The username is a filter, not a boundary.** It's self-reported by the hook, so
anyone with an account on that host can post `"user":"you"` and land on your pet
anyway. It exists to keep colleagues' work off your desktop, not to keep an
adversary out.

For an actual boundary, give both ends a shared secret. Anything without it is
refused, and the token never appears in a command line, so it stays out of
`ps` and `/proc` on the shared host:

```bash
umask 077 && openssl rand -hex 16 | tee ~/.claude-status/token | ssh devbox 'mkdir -p ~/.claude-status && umask 077 && cat > ~/.claude-status/token'
```

The `umask` matters — a token other accounts can read is not a secret, and the
pet will warn you at startup if the file is group- or world-readable.

---

## States

| Hook event | Pet | Bubble |
|---|---|---|
| `UserPromptSubmit` | bobs with squash and stretch, legs shuffling, eyes squint | `thinking` |
| `PreToolUse` / `PostToolUse` | bobs with squash and stretch, legs shuffling, eyes squint | `editing PetView.swift` |
| `Notification` | jitters and hops inside a pulsing ring, tapping a foot — **blocked on you** | `allow Bash?` |
| `Stop` | settles, breathes, blinks — idle | — |
| `SessionEnd` | forgets the session | — |

### Motion

The pet is never completely still, because a frozen sprite reads as a hung app.
Every state has a resting behaviour and an entrance:

| State | Resting | |
|---|---|---|
| asleep | slow breathing, lids down, `z` glyphs drifting off the head | |
| idle | quicker breathing, blinks — singly, and in pairs about a third of the time | |
| busy | bob, leg shuffle, blinks | |
| waiting | jitter, a two-footed hop every 1.6s, an impatient foot tap between hops | |

The bob carries **squash and stretch**, anchored at the feet — compressed on the
ground, drawn out at the top. That's the difference between a sprite sliding up
and down and one that has weight. The attention ring is fitted to the squashed
silhouette, so a stretched pet never pokes out through its own pulse.

Changing state plays a short damped spring, so you notice the change out of the
corner of your eye rather than only when you look straight at it. Waking eases
its opacity instead of switching it. Dropping off to sleep is exempt — that one
should be quiet.

Calm states run at 12fps rather than 30. Breathing and blinking read the same,
and the pet is on screen all day.

A bare tool name is true of half the session, so the hook also scrapes the one
field from `tool_input` that says what the call is *about* — the file for
`Read`/`Edit`, Claude's own one-line description for `Bash` and `Task`, the
pattern for `Grep`, the host for `WebFetch`. The bubble reads as a phrase:
`reading README.md`, `searching notification_type`, `Run the integration tests`.

The bubble sits centred overhead, where a thought belongs, and is held open room
to spread sideways so a full phrase fits without shrinking to nothing. It is
laid out against the part of the window a display can actually show, so it drops
below the pet when there's no room above — park the pet under the menu bar and
it thinks downward — and slides back inboard, truncating if it must, rather than
running off an edge.

It's anchored to where the pet *rests*, not to the walk cycle. A caption that
bobbed along with the animation, and vibrated with the waiting jitter, read as
broken; the pet moves and the thought holds still. Everything lands on whole
pixels for the same reason — text redrawn on fractional offsets shimmers.

Only the critter takes clicks: the space reserved for the bubble is
click-through, so it never becomes an invisible target for whatever is behind
it.

`Notification` carries no tool name, so the pet keeps the one from the preceding
`PreToolUse`. That's what turns a vague `needs you` into `allow Bash?` — enough
to decide whether it's worth getting up for.

**Not every notification means "needs you".** The `Notification` hook covers a
whole family of events, including one that fires 60s after a turn ends (*"Claude
is waiting for your input"*). Taking that at face value makes the pet demand
attention right after a chat finishes, so the hook re-reads `notification_type`
and only jitters for the ones a human actually has to answer —
`permission_prompt`, `agent_needs_input`, and the elicitation dialogs.
Unrecognised types settle to idle, on the theory that a false alarm is worse
than a missed one.

**The jitter is deliberately late.** Claude Code holds the permission
notification for about 6 seconds and skips it entirely if you've touched the
session in that window, so prompts you answer immediately never reach the pet.
That's the intended behaviour: the pet is for the prompts you walked away from.

### Hover for detail

The bubble is a glance. Hovering the pet opens a panel with every session it
knows about — where it's running, which project, what it's doing, and how long
it's been doing it — plus the pet's own uptime and event count at the bottom.
Whatever needs you sorts to the top and is tinted.

```
┌──────────────────────────────────────────┐
│  2 sessions · 1 needs you                │
│  ────────────────────────────────────    │
│  devbox (ssh) — drone-es-rd              │
│  waiting · allow Bash? · 4m              │
│  ────────────────────────────────────    │
│  local — claude-status                   │
│  working · editing PetWindow.swift · 12s │
│  ────────────────────────────────────    │
│  up 3h 20m · 412 events                  │
└──────────────────────────────────────────┘
```

The panel is click-through and sits *beside* the pet — bubble overhead, detail
alongside — flipping to whichever side has room so it works in any screen
corner. It's a child window, so it tracks the pet exactly during a drag instead
of trailing a frame behind.

**Idle vs. nothing running.** *Idle* means a session is alive and reporting but
not working — Claude finished its turn and is waiting for you to type. *Nothing
running* (eyes shut, dimmed) means no sessions at all.

Several sessions collapse into one mood, and **waiting outranks working** — the
session that needs you is the one worth surfacing.

### Pinning one session

Collapsing is the right default: you want the pet to surface whatever is
blocked. But with several sessions running, "what is *that* one doing" is
otherwise only answerable from the hover panel.

Right-click and pick a session, and the pet follows that one alone — its mood,
its bubble. Pick **All sessions** to go back. A pinned session that ends releases
the pin rather than stranding the pet on something that no longer exists.

Pinned, the pet also reports `idle`, which the collapsed view stays silent about
— you asked after that session specifically, so "nothing right now" is an answer.
The tool name is dropped when a pinned session goes idle: it's carried forward
from the last call so a permission prompt can say `allow Bash?`, and once the
turn is over, still claiming `editing PetPack.swift` would be a lie about live
work.

---

## Multiple agents

Every event carries `agent_source`, and each agent gets **its own pet** — its own
session list, its own saved position, its own colour. Claude Code keeps the clay
it was drawn in; other agents get a hue derived from their name, so you learn
which pet is which by sight. The name only appears under the critter when
there's more than one pet, since a lone pet needs no label.

Sessions from different agents were never comparable anyway. Collapsing Codex's
"waiting" and Claude's "working" into a single mood produces a pet that is lying
about both.

The Claude Code pet is always present, so an empty desktop still tells you the
difference between *idle* and *not installed*. Other agents' pets appear on their
first event and leave when their last session does.

> [petdex](https://github.com/agiagentsdev/agentpets-dev) reserves the same field
> for this — *"stamp `agent_source` so the sidecar can route per-pet when we ship
> multi-mascot"* — but doesn't route on it yet. This is that routing.

Sessions that stop reporting are dropped on a timer, with the deadline
depending on what they were doing. A *working* session going quiet means
something broke, most likely a dropped tunnel, so it clears after 90 seconds
rather than stranding the pet mid-thought. An *idle* session going quiet is just
you not typing, so it's held for an hour. A *waiting* session is held for 30
minutes — it's blocked on a human by definition, and the pet giving up while the
prompt is still on screen defeats the point. `SessionEnd` removes sessions
cleanly either way.

---

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `CLAUDE_STATUS_PORT` | `7777` | Port used by both hook and pet |
| `CLAUDE_STATUS_USERS` | *(all)* | Accounts the pet accepts, comma separated. Also read from `~/.claude-status/users`, one per line |
| `CLAUDE_STATUS_USER` | *(unset)* | Hook-side: stay silent unless running as this account |
| `CLAUDE_STATUS_DEBUG` | `0` | `1` logs every event the pet receives, taken or dropped |
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

The listener requires `Content-Type: application/json` and rejects anything
carrying an `Origin` header. Loopback is reachable from the browser, and without
those two checks any page you visited could POST a fake session into your pet.
A client that doesn't set a JSON content type won't be accepted.

---

## Architecture

| Path | Role |
|---|---|
| `hooks/hooks.json` | Maps six Claude Code lifecycle events to states |
| `hooks/emit.sh` | Reads the hook payload, posts state; dependency-free, always exits 0 |
| `mac-app/…/StateServer.swift` | Loopback HTTP listener on `Network.framework` |
| `mac-app/…/SessionStore.swift` | Tracks every session, collapses them to one mood |
| `mac-app/…/PetPack.swift` | One pet per agent, routed on `agent_source` |
| `mac-app/…/PetAnimator.swift` | Poses the critter each frame |
| `mac-app/…/UserFilter.swift` | Keeps other accounts off your pet on a shared host |
| `mac-app/…/PetSprite.swift` | The critter's pixel map |
| `mac-app/…/PetWindow.swift` | Borderless floating panel and rendering |
| `scripts/setup-remote.sh` | Generates and verifies the SSH tunnel |

---

## License

MIT
