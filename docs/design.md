# Design notes

Why the pet looks and behaves the way it does. None of this is needed to use it
— see the [README](../README.md) for that. It's here so the reasoning survives
contact with the next person to change something.

## Motion

**The pet is never completely still**, because a frozen sprite reads as a hung
app. Every state has a resting behaviour:

| State | Resting |
|---|---|
| asleep | slow breathing, lids down, `z` glyphs drifting off the head |
| idle | quicker breathing, blinks — singly, and in pairs about a third of the time |
| busy | bob, leg shuffle, blinks |
| waiting | jitter, a two-footed hop every 1.6s, an impatient foot tap between hops |

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

## The thought bubble

A bare tool name is true of half the session, so the hook scrapes the one field
from `tool_input` that says what a call is *about* — the file for `Read`/`Edit`,
Claude's own one-line description for `Bash` and `Task`, the pattern for `Grep`,
the host for `WebFetch`.

The bubble sits centred overhead, where a thought belongs, and is given room to
spread sideways so a full phrase fits without shrinking to nothing. It is laid
out against the part of the window a display can actually show, so it drops
below the pet when there's no room above — park the pet under the menu bar and
it thinks downward — and slides back inboard, truncating if it must, rather than
running off an edge.

It's anchored to where the pet *rests*, not to the walk cycle. A caption that
bobbed along with the animation, and vibrated with the waiting jitter, read as
broken; the pet moves and the thought holds still. Everything lands on whole
pixels for the same reason — text redrawn on fractional offsets shimmers.

Only the critter takes clicks. The space reserved for the bubble is
click-through, so it never becomes an invisible target for whatever is behind it.

The hover panel is a child window, so it tracks the pet exactly during a drag
instead of trailing a frame behind, and it flips to whichever side has room so it
works in any screen corner.

## Why the pet is late to react

**Not every notification means "needs you".** The `Notification` hook covers a
family of events, including one that fires 60 seconds after a turn ends
(*"Claude is waiting for your input"*). Taking that at face value makes the pet
demand attention right after a chat finishes, so the hook re-reads
`notification_type` and only raises the alarm for the ones a human has to
answer — `permission_prompt`, `agent_needs_input`, and the elicitation dialogs.
Unrecognised types settle to idle, on the theory that a false alarm is worse than
a missed one.

**The jitter is deliberately late.** Claude Code holds the permission
notification for about six seconds and skips it entirely if you've touched the
session in that window, so prompts you answer immediately never reach the pet.
That's intended: the pet is for the prompts you walked away from.

`Notification` carries no tool name of its own, so the pet keeps the one from the
preceding `PreToolUse`. That's what turns a vague `needs you` into `allow Bash?`
— enough to decide whether it's worth getting up for.

## Finishing

When the last working session goes idle, the pet hops three times with a
delighted `^ ^` and throws a few sparks, for two and a half seconds.

**Why it's a flourish and not a notification.** The point of the pet is that you
find things out by glancing, not by being interrupted. A banner for "finished"
would compete with Claude Code's own notifications and would still be there when
you looked back. Two and a half seconds is long enough to catch a glance and
short enough to be gone before you return — after which the pet is just idle,
which is the truth.

**Why it reads off the collapsed mood.** Firing per session means a pet watching
four of them celebrates four times, and celebrates the first one while three are
still running — which claims the work is done when it isn't. Firing when the
collapsed mood goes busy-or-waiting → idle means one flourish, at the moment
there is genuinely nothing left in flight.

**Why not `SessionEnd`.** Closing a terminal is not an achievement, and a session
that dies mid-task would celebrate a failure.

**Why the expression is an arc.** At this size a happy face has to come from
shape — there is no room for a mouth, and a merely smaller eye reads as a squint,
which is already what concentration looks like. So the eye becomes an upturned
arc, four cells wide, drawn from the same map as every other expression.

The sparks are drawn rather than set as text, unlike the sleeping `z` glyphs: an
emoji would inherit whatever the system font does this year, and a coloured glyph
would ignore the pet's tint. They're diamonds in the body colour, so a retinted
pet keeps its own confetti. They're also drawn *after* the critter and thrown
from the crown of its head — sparks the head then draws over are an expensive way
to draw nothing, which is exactly what the first version did.

## Session expiry

Sessions that stop reporting are dropped on a timer, and the deadline depends on
what they were doing:

| State when it went quiet | Held for | Why |
|---|---|---|
| working | 90 seconds | Something broke, most likely a dropped tunnel. Don't strand the pet mid-thought. |
| waiting | 30 minutes | Blocked on a human by definition. Giving up while the prompt is still on screen defeats the point. |
| idle | 1 hour | That's just you not typing. |

`SessionEnd` removes sessions cleanly regardless.

## Pinning

Collapsing several sessions into one mood is the right default — you want the pet
to surface whatever is blocked. But with several running, "what is *that* one
doing" is otherwise only answerable from the hover panel.

Pinned, the pet also reports `idle`, which the collapsed view stays silent about:
you asked after that session specifically, so "nothing right now" is an answer.
The tool name is dropped when a pinned session goes idle — it's carried forward
from the last call so a permission prompt can say `allow Bash?`, and once the
turn is over, still claiming `editing PetPack.swift` would be a lie about live
work.

A pinned session that ends releases the pin rather than stranding the pet on
something that no longer exists.

## The sprite

The critter is a cell map in
[`PetSprite.swift`](../mac-app/Sources/StatusPetCore/PetSprite.swift) rather than
an image: crisp at any size, nothing to install, and body, legs and eyes are
separate layers so it can shuffle its feet and change expression independently.

The grid is 32×20, which is twice as fine as anything drawn on it — every
feature is an even number of cells across. That resolution buys exactly one
thing: a body width that centres on a half-step. At 16 columns only even widths
centre, which made the choices either side of a 12-wide body 10 (too lean) and 14
(wider still). 11 sits where it should and costs nothing but a denominator.

The app icon and the README's state strip are both rendered from this same map at
build time (`--export-icon`, `--export-states`). Hand-drawn documentation art
drifts from the thing it documents and nobody notices.

## Other agents

Every event carries `agent_source`. The pet reads it and **ignores anything that
isn't Claude Code** — a Codex session is dropped rather than folded in, since
showing it as one of Claude's would misreport both.

One pet per agent is written and working — each with its own critter, session
list, colour and saved position — but parked behind a `TODO` in
[`PetPack.swift`](../mac-app/Sources/StatusPetCore/PetPack.swift), waiting on a
second agent actually worth watching.

> [petdex](https://github.com/agiagentsdev/agentpets-dev) reserves the same field
> for the same purpose — *"stamp `agent_source` so the sidecar can route per-pet
> when we ship multi-mascot"* — and doesn't route on it either, so there's no
> interop cost to leaving it off.

## Why loopback HTTP

The transport choice is the whole design. Comparable tools signal state through
local files and Darwin notifications, neither of which can cross a machine
boundary — remote isn't a missing feature there, it's an architectural exclusion.

Loopback HTTP can cross that boundary, because SSH already knows how to forward a
port. Hooks post to `127.0.0.1:7777` and never learn where they are: locally that
address is the pet, remotely it's a reverse tunnel back to the pet. Identical
plugin, identical configuration, both cases.

The cost is that loopback is per-machine rather than per-user, which is the
single most important thing to understand before using this on a shared host.
See [SECURITY.md](../SECURITY.md).
