# Homebase-side metadata for the xcodebuildmcp-cli skill

This file is **not** read by Claude Code's skill loader (only `SKILL.md` is).
It exists so the homebase-side governance trail of the vendored skill is
visible at the same path as the content it governs.

## Vendored from

- Upstream: `xcodebuildmcp` brew formula, tap `getsentry/xcodebuildmcp`
- Version pin: see `.homebase/dependencies.yml` → `dependencies.xcodebuildmcp.version`
- Upstream path on disk: `/opt/homebrew/Cellar/xcodebuildmcp/<version>/libexec/skills/xcodebuildmcp-cli/SKILL.md`
- Vendored verbatim — no homebase-side edits to `SKILL.md`. If you find
  yourself wanting to edit `SKILL.md` for homebase-specific reasons, the
  right place is `sops/HOMEBASE-SOP-015-APPLE_TOOLCHAIN.md` instead.

## Drift detection

`bin/homebase bootstrap` runs `bootstrap_xcodebuildmcp` which compares this
vendored `SKILL.md` against the upstream-for-pinned-version copy. Any
diff is a **bootstrap FAIL**, not a warning — the dependency state must
be in lockstep with homebase's git or the system doesn't run.

## Sync flow (when upstream releases a new version)

1. `brew upgrade xcodebuildmcp` (locally).
2. `homebase deps sync xcodebuildmcp` — copies the new upstream `SKILL.md`
   into `skills/xcodebuildmcp-cli/SKILL.md`. Does **not** bump the version
   pin.
3. `homebase deps bump xcodebuildmcp <new-version>` — bumps the pin in
   `.homebase/dependencies.yml`. Or hand-edit if you prefer.
4. Inspect the diff (`git diff skills/xcodebuildmcp-cli/SKILL.md`).
   Skill content shapes agent behaviour; an automatic upstream merge could
   silently re-steer every agent on every Mac. Review the change.
5. Commit both files under the same `Refs HMB-NNN` trailer, where
   `HMB-NNN` is a chore-kind issue titled
   `Sync xcodebuildmcp skill + pin to vX.Y.Z`.
6. Push and re-run `homebase bootstrap` on every active machine to pick up
   the new pin.

## Why vendor at all?

- **Portability**: a fresh-Mac `homebase bootstrap` lands a known-good
  skill, not whatever `xcodebuildmcp init` drops at the time.
- **Auditability**: every change to the skill content goes through git
  review.
- **Drift control**: bootstrap fails loudly when the installed version
  doesn't match the pin or when the vendored content differs from
  upstream-for-pin.

See `sops/HOMEBASE-SOP-015-APPLE_TOOLCHAIN.md` for the full policy.
