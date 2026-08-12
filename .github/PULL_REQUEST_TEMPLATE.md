# What this changes

<!-- And why. The what is in the diff; the why is what a reviewer can't recover. -->

## Checks

<!-- CI runs all of these. Ticking them before pushing is faster than a red run. -->

- [ ] `swift test --package-path mac-app`
- [ ] `bash tests/emit_test.sh`
- [ ] `./scripts/check-manifests.sh`
- [ ] `shellcheck --severity=style install.sh scripts/*.sh hooks/emit.sh tests/emit_test.sh`
- [ ] `CHANGELOG.md` updated, if a user would notice this

## If you touched…

**`hooks/emit.sh`** — does it still exit 0 on every path, stay detached from the
session, and keep the jq, python and fallback parsers in agreement?

**The listener or the wire format** — is it still `POST /state`, JSON only, no
`Origin`? Does the [threat model](https://github.com/donald-heddesheimer/claude-status/blob/main/SECURITY.md) still describe what
the code actually does?

**`PetSprite.swift`** — the app icon renders from the same map, so it changed
too. Worth attaching a before/after image; the sprite is small enough that one
cell is a large proportional change.

**Anything touching secrets** — is the token still kept out of `argv`? Process
command lines are world-readable on the shared hosts this is built for.
