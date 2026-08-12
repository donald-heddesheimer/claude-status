# Changelog

Notable changes to claude-status. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html), with the usual
pre-1.0 caveat that minor versions may break things.

Versions 0.1.0 through 0.3.0 were recorded in the plugin manifest but never
tagged or released — they are reconstructed here from the commit history so the
record is complete. **0.4.0 is the first release with a git tag and downloadable
artifacts.**

## [0.4.0] — unreleased

The release that makes this installable by someone who isn't me.

### Added

- **Single-session mode.** The pet follows one session — mood, bubble, animation
  and finish flourish all from that one — instead of collapsing everything into a
  single mood. Right-click the pet or use Settings ▸ Sessions. The mode is what
  persists, not the session id: those are new every launch, so the pet adopts
  whatever turns up, and adopts a replacement rather than going blank when the
  session it was following ends.
- **Colour-coded thought bubbles.** With more than one session running, each gets
  its own bubble colour, handed out on arrival and held for the life of the
  session. The first is always black — the ink the bubble has always used — so a
  lone session looks exactly as it did. Matching dots in the hover panel and the
  right-click menu say which is which.
- **The pet celebrates a finished turn.** When the last working session goes
  idle it hops with a delighted `^ ^` and throws a few sparks, for two and a
  half seconds, then settles. Reads off the collapsed mood, so a pet watching
  four sessions celebrates once — when the work is actually done.
- `install.sh`: clone and run one command. Builds the app, installs it to
  `/Applications`, registers the Claude Code plugin, and starts the pet.
- `scripts/build-app.sh`: assembles a universal (arm64 + x86_64) `.app` with a
  real `Info.plist` and an icon. Optionally produces a notarised DMG and ZIP with
  checksums when Apple credentials are present in the environment.
- In-app **Settings** window — port, click target, allowed accounts, token file,
  launch at login. Configuration no longer requires exported environment
  variables, though those still win where set, and the window says so.
- **Health** view: whether the listener is bound, when the last event arrived,
  which peers are silent, and why the last rejected event was rejected.
- **SSH setup wizard**: detects host aliases, proposes a `RemoteForward` line,
  writes it with a timestamped backup, installs a matching token over stdin, and
  interprets the result of a live probe rather than printing a bare status code.
- Launch at login, via `SMAppService`.
- Optional Sparkle auto-updates, off by default and behind a build flag, so the
  default build fetches nothing.
- Test suites: 102 Swift unit tests and 55 shell tests for `hooks/emit.sh`.
- CI on every push and pull request: Swift build and tests, app bundle assembly,
  shellcheck, the shell suite, and manifest validation.
- Governance: `CONTRIBUTING.md`, `SECURITY.md`, `SUPPORT.md`, `ROADMAP.md`,
  issue and pull request templates.
- `docs/design.md`, holding the reasoning behind the pet's motion, thought
  bubble, notification classification and session expiry.

### Changed

- **The pet is slightly narrower.** The body went from 12 cells to 11. Since only
  even widths centre on a 16-column grid, the sprite grid is now 32×20 and the
  on-screen cell halved to match — the same drawing at a finer denominator. The
  arm bar still spans the full width, so the arms project further than before.
- `hooks/emit.sh` parses the hook payload with `jq` or `python3` instead of
  scraping it with `sed`, falling back to the old path only when neither exists.
  Measured across 25 invocations: jq 23.0ms, python 39.3ms, fallback 61.7ms,
  against 63.4ms for the previous `sed` implementation.
- The app icon is rendered from the sprite map at build time rather than
  committed as a binary, so it cannot drift from the critter on screen.
- A port collision no longer quits the app. It stays up, reports the problem in
  Health, and Settings can move it to a free port without a relaunch.
- Settings distinguishes changes that need the listener restarted from changes
  that only affect how the pet looks. Toggling a colour no longer drops the
  socket out from under a hook that happens to be posting.

### Fixed

- The listener accepted **every path and every HTTP method** — the request line
  was parsed but discarded, so `GET /anything` was treated as a state update.
  It now requires `POST /state`.
- Comment lines in `~/.claude-status/users` were split on whitespace and every
  word became an allowed account, silently disabling the filter for anyone whose
  file had a comment in it.
- Token files are created `0600` at creation rather than being chmod'd after,
  closing the window where the file existed with default permissions.

### Security

- Requests carrying an `Origin` header are refused, and `Content-Type:
  application/json` is required. Loopback is reachable from a browser, and
  `text/plain` form posts avoid a CORS preflight — without both checks, any page
  you visited could post a fake session into your pet.
- Token comparison is constant-time.
- Field-by-field length limits and control-character stripping on every string
  taken off the wire.
- The SSH wizard passes secrets over stdin only, never as command arguments,
  since process command lines are world-readable on the shared host.

## [0.3.0] — 2026-08-11

### Added

- `agent_source` on every event. The pet reads it and ignores anything that
  isn't Claude Code, rather than folding a Codex session in as one of Claude's.
- One pet per agent — each with its own critter, session list, colour and saved
  position. Written and working, but parked behind a `TODO` in `PetPack.swift`
  pending a second agent worth watching.

## [0.2.1] — 2026-08-11

### Security

- Hardened the wire protocol: size limits, field validation, and optional
  shared-secret authentication via `X-Claude-Status-Token`.

## [0.2.0] — 2026-08-11

### Added

- Session life cycle. Sessions that stop reporting are dropped on a timer whose
  deadline depends on what they were doing: 90s for working, 30m for waiting on
  a human, an hour for idle.

### Changed

- Softened the motion. Squash and stretch anchored at the feet, damped springs
  on state changes, and 12fps for calm states instead of 30.

## [0.1.3] — 2026-08-11

### Added

- Account filtering, for shared remote hosts where one SSH tunnel serves the
  whole machine. Events with no account are kept if local and dropped if remote.

### Fixed

- The thought bubble no longer rides the walk cycle or vibrates with the
  waiting jitter.

## [0.1.2] — 2026-08-11

### Added

- Hover panel listing every known session — host, project, activity and age —
  with whatever needs you sorted to the top.
- Richer bubble text: `reading README.md` rather than `Read`.

## [0.1.1] — 2026-08-11

### Fixed

- Spurious needs-you jitter. `Notification` covers a family of events including
  one that fires 60s after a turn ends; only the types a human must answer now
  raise the pet's attention.
- Port conflicts fail loudly instead of silently doing nothing.

## [0.1.0] — 2026-08-11

Initial version: floating desktop pet, six Claude Code lifecycle hooks, and
loopback HTTP so the same plugin works locally and over an SSH reverse tunnel.

[0.4.0]: https://github.com/donald-heddesheimer/claude-status/releases/tag/v0.4.0
