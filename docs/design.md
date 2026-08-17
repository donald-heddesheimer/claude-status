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

## Several sessions at once

Collapsing every session into one mood is the right default — you want the pet to
surface whatever is blocked, wherever it is. It stops being right at about three
sessions, where the bubble belongs to whichever one spoke last and there is
nothing on screen saying which that was. There are two answers, and they are for
different moods.

### Following one

The pet's mood, bubble, animation and finish flourish all come from one session.
It also reports `idle`, which the collapsed view stays silent about: you asked
after that session specifically, so "nothing right now" is an answer. The tool
name is dropped when it goes idle — it's carried forward from the last call so a
permission prompt can say `allow Bash?`, and once the turn is over, still
claiming `editing PetPack.swift` would be a lie about live work.

**The mode persists; the session does not.** Session ids are minted afresh every
time Claude Code starts, so an id saved yesterday names nothing today. What is
remembered is that you want one session, and the pet adopts whatever turns up.

**A followed session that ends is replaced, not released.** The earlier version
of this dropped back to showing everything, which meant re-arming it by hand
every time a session ended — and a mode you have to re-arm is not a mode.
Adoption fires only when the followed session is actually gone: a second session
getting blocked must not drag the pet off the one you chose, or "follow one"
would just be the collapsed view with extra steps.

**The hover panel lists that session alone**, and says how many it is hiding. A
pet quietly following one session would otherwise look exactly like a pet that
had lost the other three.

**Changing focus is not a finish.** The [finish flourish](#finishing) fires on
the collapsed mood going busy-or-blocked → idle, and changing which session the
pet watches moves that mood too: follow a quiet one while another is mid-run and
the mood drops to idle having finished nothing. So the store records whether its
last change came from a session or from you, and the flourish only reads the
former. A pet that celebrated because you opened a menu would be lying about
your work.

### Colour

Each session gets its own bubble colour, so the caption identifies its speaker
without a word of explanation.

**Keyed to arrival, not to position.** Every list here re-sorts — the hover panel
puts whatever needs you at the top — so a colour taken from position would change
at the precise moment a session got blocked, which is when you least want it to
move. Slots are handed out on first sight and released when the session ends, so
the lowest free colour is reused rather than marching through all six over an
afternoon.

**The first is black**, which is the ink the bubble has always used. Colour
answers "which of these is talking", and with one session — the normal case —
there is no question to answer, so nothing changes until there is a second.

**Six colours, then they repeat.** That is where legibility runs out rather than
an arbitrary cap: all six carry the bubble's white text at better than 7:1, and
they differ in lightness as well as hue so none of them relies on hue alone. Past
six the hover panel is the authority.

The panel and the right-click menu carry the same dot beside each session. A
coloured bubble with no legend is decoration; the legend is what makes it
information. Both dots are ringed, because the first colour is near-black and so
is the panel behind it — without the ring that row reads as having no colour
rather than as having the darkest one.

One consequence worth knowing: picking the speaker used to be arbitrary. Two
sessions blocked at once both said `allow Bash?`, so it never mattered which one
the dictionary handed back. It matters now — an unstable pick would flip the
bubble's colour between them on every redraw — so the order is fully determined,
tiebreak included.

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

The app icon and every picture in the README are rendered from this same map
(`--export-icon`, `--export-states`, `--export-sessions`, `--export-agents`,
`--export-animation`).
Hand-drawn documentation art drifts from the thing it documents and nobody
notices.

## Other agents

Every event carries `agent_source`. Codex, opencode, or anything else speaking
the same protocol shares Claude's pet rather than getting a window of its own —
a second critter competing for desktop space wasn't worth it for what amounts
to a colour and a name.

**One agent looks exactly as it always has.** Colour still tells that agent's
own sessions apart from each other, same as [Several sessions at
once](#several-sessions-at-once) describes. Nothing about a solo Claude session
changes because the code can now hear from more than one agent.

**A second agent gets a colour and a name.** Once `SessionStore.multipleAgents`
is true, colour stops answering "which session" and starts answering "which
agent" — every session belonging to one agent shares a slot, handed out and
released the same arrival-ordered way sessions already were. The name appears
under the critter, in the same spot a separate-pet-per-agent build used to put
it: built once, shelved when that build was parked, and picked back up here
rather than invented twice.

**The label always names whoever the bubble is quoting.** Both come from the
same `Thought` — deriving them separately is how a label ends up next to the
wrong agent's words, the same reasoning [colour](#colour) already follows for
sessions.

A pet per agent was written and worked — its own critter, session list, colour
and saved position, routed on `agent_source`. It's still true, just not what
this does: watching a second agent turned out to want a badge on the one pet
you already look at, not a second thing to look at.

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
