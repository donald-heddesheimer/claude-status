# Security

## Reporting a vulnerability

Report privately through GitHub's
[security advisory form](https://github.com/donald-heddesheimer/claude-status/security/advisories/new).
Please don't open a public issue for anything exploitable.

Expect an acknowledgement within a week. This is a personal project maintained in
spare time — if you need a guaranteed response window, this isn't software to
depend on for that.

## Supported versions

| Version | Supported |
|---|---|
| 0.4.x | Yes |
| < 0.4 | No — upgrade |

Fixes land on `main` and go out in the next release. There are no backports.

## Threat model

Being precise about this matters more than the usual boilerplate, because two of
the design constraints are genuinely counterintuitive.

### What the pet trusts

The listener binds `127.0.0.1` only, never `0.0.0.0`. Nothing is exposed to any
network. Remote sessions reach it through an SSH reverse tunnel, inside a
connection you already trust.

Every request must be `POST /state` with `Content-Type: application/json`, and
any request carrying an `Origin` header is refused. Both checks exist because
loopback is reachable from your browser: a page you visit can POST to
`127.0.0.1`, and a `text/plain` form post avoids a CORS preflight entirely.
Without these, any site could push fake sessions into your pet.

Strings taken off the wire are length-capped per field and stripped of control
characters. Sessions are capped at 200, oldest evicted first.

### Loopback is per-machine, not per-user

This is the important one. `RemoteForward 7777 127.0.0.1:7777` binds **one**
address for the whole remote box, and it belongs to whoever's tunnel is up. On a
shared host, every claude-status hook run by anyone lands in *your* tunnel —
their file names, their Bash descriptions, their permission prompts on your
desktop.

### The username filter is not a security boundary

`~/.claude-status/users` and `CLAUDE_STATUS_USERS` filter by an account name that
is **self-reported by the hook**. Anyone with a shell on that host can post
`"user":"you"` and reach your pet regardless.

It exists to keep colleagues' ordinary work off your screen. It does not keep out
anyone who doesn't want to be kept out, and it should never be described as
though it does.

**For an actual boundary on a shared host, use a token.** Requests without a
matching `X-Claude-Status-Token` are refused, and the comparison is
constant-time.

```bash
umask 077 && openssl rand -hex 16 \
  | tee ~/.claude-status/token \
  | ssh devbox 'mkdir -p ~/.claude-status && umask 077 && cat > ~/.claude-status/token'
```

The `umask` is not decoration. A token other accounts can read is not a secret,
and the pet warns at startup if the file is group- or world-readable.

### Secrets never appear in a command line

Process command lines are world-readable on Linux via `/proc/<pid>/cmdline`. A
token passed as `curl -H "X-Token: …"` or `ssh host "echo secret > file"` is
visible to every account on that machine for as long as the process lives.

So the hook passes the token to curl through a config file on **stdin**, and the
SSH setup wizard installs the remote token by piping it into a quoted heredoc
over stdin. Neither ever puts the secret in `argv`. Please preserve this if you
touch either path.

## Known limitations

**Downloaded release builds are not notarised.** They are signed ad-hoc, which
macOS refuses to open once the download quarantine is applied. This is a funding
limit, not an oversight — notarisation requires a paid Apple Developer account.
Building from source is the supported install path and is never quarantined.

**The pet displays text from other machines.** Captions come from tool inputs on
whatever host is reporting. They are stripped of control characters and truncated,
and rendered as text rather than interpreted — but on a shared host without a
token, what appears on your desktop is whatever someone else's session was doing.

**No sandbox.** The app runs unsandboxed with a hardened runtime. It reads its own
preferences, the token and users files, and the artwork override path; it opens
the app configured for click-through. It requests no entitlements beyond that.

**Crash reporting: none.** Nothing is collected, transmitted, or phoned home.
There is no telemetry to opt out of.
