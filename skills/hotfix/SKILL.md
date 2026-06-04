---
name: hotfix
description: "Wrapper around `homebase work start --hotfix`. Use when a P0 defect (data loss, safety error, crash, security) needs an out-of-band emergency release."
---

# Hotfix — `homebase work start --hotfix` wrapper

The CLI is the contract. This skill is a thin wrapper that adds the decision gate operators need before invoking the hotfix path.

## Decision gate (DO THIS FIRST)

A hotfix is appropriate only when **all four** are true:

1. **P0 severity** — data loss, safety-critical incorrectness, crash on launch, security incident.
2. **Reachable in production** — affects users right now, not a regression on `main` that hasn't shipped.
3. **No safe wait** — cannot wait for the next normal release cycle (typically same week).
4. **Operator confirmed** — Charter red-list. The CLI requires `HOMEBASE_HOTFIX_AUTHORIZED=1`; that env var goes in only after explicit operator say-so.

If any of these is false, **do not hotfix**. Use the normal `homebase work start <KEY>` path.

## Run

```
HOMEBASE_HOTFIX_AUTHORIZED=1 homebase work start --hotfix <ISSUE-KEY>
```

The CLI:
1. Validates the start_gates as usual (issue exists, tree clean, branch base).
2. Records `kind: hotfix` and `override_kind: hotfix` in `.homebase/work-state.json` for audit.
3. Creates a hotfix branch from the latest release tag (not `main`) when the project's release model uses tag-anchored hotfixes.
4. Moves Linear to `in_progress`.

## Finish

```
LINEAR_TPM_AUTHORIZED=1 HOMEBASE_WORK_AUTHORIZED=1 homebase work finish --no-pr
```

The hotfix kind skips three gates that don't apply:
- gate 6 (changelog-current) — the changelog entry lands in the release commit itself.
- gate 7 (linear-in-progress) — the issue may not exist in Linear yet for true emergencies.
- gate 11 (pr-opened-or-updated) — hotfix flow ships direct-to-tag.

All other gates fire normally. The closing keyword is still required (gate 5).

## After it ships

Merge the hotfix branch back into `main`:

```
git checkout main
git merge --no-ff <hotfix-branch>
HOMEBASE_WORK_AUTHORIZED=1 git push origin main
```

If `main` has diverged, this may require a merge commit. That's expected — a hotfix is an out-of-band release.

## Related

- `homebase work ship <APP> <VERSION>` — the normal release path.
- `@~/code/homebase/governance/AUTONOMY_CHARTER.md` § Red-list — why hotfix is operator-confirmed.
- `@~/code/homebase/sops/HOMEBASE-SOP-006-HOTFIX_PROCESS.md` — explanation: branch-from-tag rationale, merge-back semantics.
