# Support

## Start here

Run this inside any Claude Code session:

```
/claude-status:status
```

It reports whether the session is local or remote, whether anything is listening
on the port, and whether a test event actually lands. Most problems are visible
in that output, and it's the first thing an issue will be asked for.

Then open the pet's **Settings → Health**, which shows whether the listener is
bound, when the last event arrived, and why the most recent rejected event was
rejected.

## Common problems

**The pet never reacts.** Hooks apply to *newly started* Claude Code sessions.
Start a new one. If it still does nothing, check that the plugin is installed on
the machine Claude Code is running on — under VS Code Remote-SSH that's the
remote host, not your Mac.

**The pet doesn't start, or the port is taken.** Something else holds 7777, most
likely another pet or [petdex](https://github.com/agiagentsdev/agentpets-dev),
which shares the port by design. Check with `lsof -nP -iTCP:7777 -sTCP:LISTEN`,
then pick another port in Settings — no relaunch needed.

**Remote sessions don't show up.** `RemoteForward` only applies to new SSH
connections, so an existing session won't pick it up. Reconnect, then verify with
the curl one-liner in the README before installing anything else.

**Someone else's work appears on my pet.** Expected on a shared host: one SSH
tunnel serves the whole machine. See [SECURITY.md](SECURITY.md) — and use a
token, since the username filter is convenience, not a boundary.

**A downloaded build won't open.** Release artifacts are ad-hoc signed and macOS
refuses them. Build from source instead; it takes about ten seconds. This is
explained in [SECURITY.md](SECURITY.md#known-limitations).

## Tested on

| | Version |
|---|---|
| macOS | 13 (minimum, `SMAppService` requires it) · CI builds on 14 · developed on 26 |
| Swift | 5.9 minimum (`swift-tools-version`), built with 6.3 |
| Claude Code | 2.1.x |
| Architectures | Apple silicon and Intel — releases are universal binaries |
| Remote hosts | Any Linux or macOS box with `bash` and `curl`; `jq` or `python3` preferred |

The pet is macOS only and will stay that way — it's an AppKit floating window.
The *hook* is portable and runs anywhere with bash and curl, which is what makes
watching a Linux dev box work.

## Asking for help

Open a [discussion](https://github.com/donald-heddesheimer/claude-status/discussions)
for questions, or an issue for something that looks like a bug. Please include
the `/claude-status:status` output and whether the session is local or over SSH.

Security reports go through [SECURITY.md](SECURITY.md), not public issues.

## What "supported" means here

This is a personal project maintained in spare time, offered under the MIT
licence with no warranty. Bugs get fixed when there's time. If you need
guaranteed response times, this isn't the right dependency — but pull requests
are genuinely welcome, and [CONTRIBUTING.md](CONTRIBUTING.md) will get you
building in a couple of minutes.
