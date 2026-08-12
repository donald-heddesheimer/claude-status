# Roadmap

No dates. Rough order of intent, and honest about what's blocked on money rather
than on effort.

## Next

**Signed and notarised releases.** Everything needed is already written —
`scripts/build-app.sh` does the full hardened-runtime, notarise and staple dance,
and the release workflow imports a certificate and key when the secrets exist.
The only missing piece is an Apple Developer Program membership ($99/yr), without
which downloaded builds are refused by Gatekeeper. Until then, building from
source is the supported path, and it is genuinely fast — about ten seconds.

**Homebrew cask.** Only worth doing once the above lands. A cask that installs an
app macOS then refuses to open is worse than no cask.

**Sparkle auto-updates, switched on.** The integration exists behind
`CLAUDE_STATUS_SPARKLE=1` and is off by default so the ordinary build fetches
nothing. Turning it on needs a signed release to update *to*, plus an appcast
published from the release workflow and an EdDSA key.

## Wanted, not blocked

**Screenshots and a short demo.** The README describes motion in prose, which is
the wrong medium for it. The pet is a moving thing and should be shown moving.

**A first-run experience.** Right now a fresh install shows a critter and no
explanation. It should offer the SSH wizard and say what to do next, once, and
never again.

**Per-agent pets.** Already written and working — each agent gets its own
critter, session list, colour and saved position. It's parked behind a `TODO` in
`PetPack.swift` with instructions for switching it on, waiting on a second agent
actually worth watching. Today anything that isn't Claude Code is dropped rather
than folded in, since showing it as one of Claude's would misreport both.

**Better remote diagnosis.** Health knows when a peer went quiet but can't tell a
dropped tunnel from an idle developer. The distinction is the single most useful
thing it could learn.

## Considered and declined

**Windows and Linux ports.** The pet is an AppKit floating window; a port is a
rewrite, not a port. The *hook* is already portable — bash and curl — which is
what makes watching a Linux box work today. That's the useful half, and it's
done.

**Telemetry, including the crash-reporting kind.** A desktop pet does not need to
know anything about you. There is nothing to opt out of because there is nothing
collected, and keeping it that way is worth more than the crash reports would be.

**Exposing the listener beyond loopback.** Binding anything but `127.0.0.1` turns
a toy into an attack surface. SSH already solves the remote case, with
authentication and encryption you already trust.

**A menu bar icon.** Considered, but the pet *is* the interface. Two places to
look at the same state is one too many.
