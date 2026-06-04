# HOMEBASE-SOP-006: Hotfix Process

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Emergency release procedure for P0 production defects. Abbreviates HOMEBASE-SOP-005 while preserving traceability.

## Purpose

Provide a fast-path for fixing production-breaking issues without the full HOMEBASE-SOP-001 + HOMEBASE-SOP-005 ceremony. Speed matters, but traceability is still mandatory.

## Scope

**Applies to**: All apps, all platforms, every homebase-adopting project.

**When to use**: Only for P0 issues — production broken, data loss risk, safety-calculation error, or security vulnerability. For everything else, use the standard HOMEBASE-SOP-001 workflow and HOMEBASE-SOP-005 release process.

**Agents involved**: `technical-project-manager` (coordination), the relevant language architect (fix), the relevant domain expert (sign-off if the fix touches a safety-critical surface).

---

## Decision Gate: Hotfix vs. Wait

A hotfix is warranted ONLY when one of the following is true:

| Criteria | Hotfix | Normal release |
|---|---|---|
| Data loss or corruption | Yes | — |
| Safety-calculation error | Yes | — |
| Crash on launch or core flow | Yes | — |
| Security vulnerability | Yes | — |
| Visual bug, minor UX issue | — | Yes |
| Feature gap, enhancement | — | Yes |

**If in doubt, wait for the next release.** Hotfixes carry risk proportional to their speed.

---

## Procedure

### Step 1: Create P0 Issue

Create a GitHub issue immediately with `P0` and `bug` labels. Capture the symptom, not the full analysis.

Document:

- Affected app, version, and platform.
- Steps to reproduce.
- Impact scope (how many users affected, data at risk).

An abbreviated issue body is acceptable.

### Step 2: Branch from Release Tag

```bash
# Branch from the exact release that's in production
git checkout -b hotfix/{app}-{new-version} {app}/{platform}/{current-production-version}
```

Example: `git checkout -b hotfix/gascalc-1.0.3 gascalc/ios/1.0.2`.

Branching from the production tag — not from `main` — guarantees the hotfix contains only the fix and the state users are currently running.

### Step 3: Fix and Test

1. Apply the **minimal** fix. Do not include unrelated changes or opportunistic cleanups.
2. Run the project's full CI suite locally.
3. Safety-critical fixes: obtain sign-off from the relevant domain expert before proceeding.

### Step 4: Bump Patch Version

Increment only the PATCH component (e.g., `1.0.2` → `1.0.3`).

### Step 5: Abbreviated Release

Follow HOMEBASE-SOP-005 § "Patch Release Quick-Reference" with these adjustments:

- Changelog: Single entry under the new version, category `### Fixed`.
- Screenshots: Always skip.
- Public-site update: None unless the hotfix is a safety advisory.

### Step 6: Tag and Push

```bash
git tag -a {app}/{platform}/{new-version} -m "$(scripts/extract-changelog.sh {app} {new-version})"
git push origin hotfix/{app}-{new-version} --tags
```

### Step 7: Submit for Expedited Review

- `[iOS]`: In App Store Connect, select **Request Expedited Review** and explain the critical fix.
- `[Android]`: In Google Play Console, use **Release with higher priority**.
- `[Web]`: Deploy immediately via the project's normal deployment process.

### Step 8: Merge Back to Main

After the hotfix is live:

```bash
git checkout main
git merge hotfix/{app}-{new-version}
git push origin main
```

Resolve any conflicts. The hotfix branch can be deleted after the merge.

### Step 9: Close and Document

1. Close the P0 issue with `Fixes #N` on the merge commit.
2. If the root cause suggests a systemic problem, create a follow-up issue for the proper fix in the next scheduled release.

No formal post-mortem document is required — the issue trail plus the follow-up issue are sufficient. Exceptions: safety incidents or outages that warrant a durable write-up should live in the project's `Documentation/Planning/INCIDENTS/` or equivalent.

---

## Quick Reference

| Step | Action | Time target |
|---|---|---|
| 1 | Create P0 issue | Immediately |
| 2 | Branch from release tag | < 10 min |
| 3 | Fix and test | < 4 hours |
| 4 | Bump patch version | < 5 min |
| 5 | Changelog, release notes, localize | < 30 min |
| 6 | Tag and push | < 5 min |
| 7 | Submit for expedited review | < 10 min |
| 8 | Merge back to main | After live |
| 9 | Close and document | After live |

---

## What This SOP Does NOT Cover

- Non-critical bugs — use the standard HOMEBASE-SOP-001 workflow.
- Feature rollbacks — evaluate case-by-case; a rollback that re-releases an old version still follows this SOP if the situation is P0.
- Infrastructure outages handled outside the codebase — runbooks for deploy infrastructure live in the project's ops docs, not here.
