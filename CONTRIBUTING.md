# Contributing

Thanks for looking. This is a small project with a small surface, so the process
is deliberately light.

## Getting set up

```bash
git clone https://github.com/donald-heddesheimer/claude-status
cd claude-status
./install.sh --dev
```

`--dev` registers the plugin from your clone rather than from GitHub, so hook
edits take effect in the next Claude Code session without reinstalling. The
tradeoff is that deleting the clone breaks your hooks.

For a faster loop while working on the pet itself, skip the bundle entirely:

```bash
swift run --package-path mac-app
```

That runs a debug build in the foreground with the banner and any debug logging
visible, which is usually what you want while iterating. Note that it uses a
different preferences domain than the installed `.app`, so the two do not share
settings.

## Running the tests

Three suites, all of which CI runs on every pull request:

```bash
swift test --package-path mac-app     # 106 unit tests
bash tests/emit_test.sh               # 55 hook tests
./scripts/check-manifests.sh          # manifest and changelog consistency
```

And the linter, if you have it (`brew install shellcheck`):

```bash
shellcheck --severity=style install.sh scripts/*.sh hooks/emit.sh tests/emit_test.sh
```

`style` is shellcheck's strictest level. The scripts are small enough to hold to
it, so please keep them there — with a `# shellcheck disable=` and a comment
saying *why* when a finding is genuinely wrong.

## Things worth knowing before you change something

[docs/design.md](docs/design.md) covers why the pet moves and reads the way it
does — motion, the thought bubble, notification classification, session expiry.
Worth skimming before changing any of that. The constraints below are the ones
that will bite you regardless of what you're working on.

**The hook must never be able to hurt a session.** `hooks/emit.sh` always exits
0, detaches `curl` from its process group, and caps the connect timeout at one
second. If the pet is down, your laptop is asleep, or the tunnel dropped, Claude
Code must not notice. Changes that could block, fail loudly, or write to stdout
are a problem regardless of how correct they are otherwise.

**The hook runs on machines you don't control.** It has three parser paths — jq,
python3, and a sed fallback for a box with neither — and `tests/emit_test.sh`
asserts all three produce identical output. If you touch parsing, keep them in
agreement.

**The end-to-end hook test is not redundant.** One test runs the real script
against real `curl` and a real listener. It exists because an earlier version
passed every stub test while curl silently dropped both headers and truncated
any body containing a space: unquoted values in a curl config file end at the
first whitespace. Only an end-to-end test sees that class of bug.

**The app icon is generated from the sprite.** `PetSprite.swift` is the single
source for both the on-screen critter and `AppIcon.icns`, which is rendered at
build time by `IconExporter`. Change the sprite and the icon follows. There is
no PNG to update, and adding one would reintroduce the drift this avoids.

**The sprite grid is 32×20 on purpose.** Every feature is an even number of
cells across, so nothing needs that resolution for itself. It exists so the body
width can land on a half-step — at 16 columns only even widths centre.

**Loopback is per-machine, not per-user.** Anything you change about filtering or
authentication should start from the [threat model](SECURITY.md), which is
specific about what the username filter is and is not.

## Pull requests

- Branch from `main`.
- Keep the commit history readable. Subjects are written as sentences in the
  imperative — "Harden the wire protocol", not "fix: harden wire protocol". This
  project does not use Conventional Commits.
- Explain *why* in the commit body. The what is in the diff.
- Add a `CHANGELOG.md` entry under the unreleased heading for anything a user
  would notice.
- Comments should say why the code is the way it is, especially when it looks
  odd. A comment restating the next line is noise; one explaining which bug the
  odd-looking line prevents is worth its space.

CI must be green. If a job fails for a reason you believe is unrelated, say so in
the PR rather than rerunning until it passes.

## Reporting bugs

Use the issue templates — they ask for the handful of things needed to reproduce
anything here (macOS version, local or SSH, and what `/claude-status:status`
reports). For anything security-relevant, follow [SECURITY.md](SECURITY.md)
instead of opening a public issue.
