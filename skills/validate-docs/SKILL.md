---
name: validate-docs
description: "HOMEBASE-SOP-003 documentation governance check. Use when creating or modifying documentation to verify correct placement, naming, cross-references, and platform-scope rules."
---

# Validate Docs — HOMEBASE-SOP-003 Wrapper

Verify documentation integrity after any documentation change.

## Canonical Process

Follow **HOMEBASE-SOP-003**:

1. Verify file placement (location rules in § 2).
2. Verify naming convention (§ 1).
3. Check platform-scope rules (§ 3).
4. Verify cross-reference syntax (§ 4).
5. Run the review checklist (§ 5).
6. Verify CLAUDE.md constraints (§ 6).
7. Run automated validation (§ 10).
8. Update documentation in the same commit as any code change it describes (§ 9).

## Arguments

None required. Run after any documentation change.

## Procedure: Additions to the SOP

### Automated Validation

```bash
scripts/validate-docs.sh
```

This is the homebase-canonical validator (symlinked into every project). It runs universal checks plus any project-specific checks from `scripts/validate-docs-project.sh` if the project provides one.

Must report **0 errors**. Warnings are non-blocking but should be reviewed.

### CLAUDE.md Line Limit

The project's root `CLAUDE.md` must stay under **250 lines** (HOMEBASE-SOP-003 § 6). Check before committing any content addition.

### SOP / Skill Alignment Check (on SOP changes)

When a homebase SOP is created or modified, verify skill alignment:

1. Search `~/code/homebase/skills/` for skills that reference this SOP.
2. For each MUST or mandatory statement added or changed in the SOP, verify the skill has a corresponding procedural step.
3. If a new MUST was added but no skill step enforces it, add the step in the same commit.

This prevents policy-without-procedure drift at the source — echoed by the `/audit-governance` Check 5.

## Output

Summarise what was checked and any fixes applied. Report `PASS` / `N errors, M warnings` with the specific failures.

## Related

- `@~/code/homebase/sops/HOMEBASE-SOP-003-DOCUMENTATION_GOVERNANCE.md` — full SOP.
- `~/code/homebase/scripts/validate-docs.sh` — the universal validator (symlinked into each project).
- `scripts/validate-docs-project.sh` (if present in the project) — project-specific checks that the universal validator sources.
