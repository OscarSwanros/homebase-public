---
name: audit-governance
description: "Governance drift audit for agents, SOPs, and skills. Run quarterly or when drift is suspected. Detects inline app lists, boilerplate creep, agent-roster inconsistency, description length violations, and skill/SOP alignment gaps."
---

# Audit Governance — Agent / SOP / Skill Consistency Check

You are running the quarterly governance audit. This checks for drift between the canonical sources of truth and the files that reference them.

**Post-Phase 8 reality**: the canonical sources are now `~/code/homebase/standards/WORKFLOW_CONTRACT.md` + `<project>/.homebase/workflow.yml` (control) + `~/code/homebase/governance/HARD_RULES.yml` (rule data). The 13 SOPs are *explanation* — they explain rationale, not procedure. The Skill / SOP alignment check (Check 5 below) is the place this matters most: skills should wrap CLI verbs (`homebase work *`) and reference SOPs only for *why*, not *how*.

## Arguments

None required. Run: `/audit-governance`

## Procedure

Run each check below. For each, report PASS or FAIL with specifics.

### Check 1: No Inline App Lists in Agents

**Canonical source**: the project's root `CLAUDE.md` (Projects / Active Development Status section).

1. Read the project root `CLAUDE.md` and extract the list of active/paused apps.
2. Read every file in `~/code/homebase/agents/` and look for inline app listings (e.g., hardcoded app names in prose).
3. **PASS** if no agent hardcodes the app list (all defer to CLAUDE.md at runtime).
4. **FAIL** if any agent has an inline list that could go stale. Report file and line.

### Check 2: Agent Boilerplate Check

Search each file in `~/code/homebase/agents/` for patterns that should have been replaced with the compressed governance pointer:

- `"Mandatory SOPs": Follow HOMEBASE-SOP-001` in full paragraph form
- `"GitHub API restriction": You MUST NOT run` in full paragraph form
- Names of products that have been removed from the project

**PASS** if none of these patterns appear in any agent file.
**FAIL** if any agent has boilerplate creep. Report file and pattern.

### Check 3: Agent Roster Consistency

1. List every `.md` file in `~/code/homebase/agents/`.
2. Read the agent roster table in the project's `Documentation/AGENT_GUIDE.md` (or equivalent).
3. Read the agent table in the project root `CLAUDE.md`.
4. **PASS** if the three lists match (accounting for project-scoped agents that live in `<project>/.claude/agents/`).
5. **FAIL** if any agent appears in one but not the others. Report discrepancies.

### Check 4: Agent Description Length

For each file in `~/code/homebase/agents/`:

1. Extract the `description` field from YAML frontmatter.
2. Measure character count.

**PASS** if all descriptions are under 500 characters.
**FAIL** if any exceeds 500. Report file and count.

### Check 5: Skill / SOP Alignment (Policy-Procedure Parity)

For each skill in `~/code/homebase/skills/`:

1. Read the skill's `SKILL.md`.
2. Identify which SOP(s) it enforces.
3. Verify the SOP exists at the referenced path.
4. **Extract every MUST / mandatory / required statement from the SOP** that falls within the skill's scope.
5. For each MUST, verify the skill has a **concrete numbered step** that enforces it — not just a mention in prose, but an action the agent will execute deterministically.
6. Check the reverse: any skill steps that contradict the SOP?

**PASS** if every SOP MUST has a corresponding enforced skill step.
**FAIL** if any SOP requirement is:
- Missing entirely from the skill (policy without procedure)
- Mentioned only in prose/rules but not in a numbered step
- Contradicted by the skill's procedure

Report each gap as: `SOP says: "{requirement}" → Skill gap: {what's missing}`.

**Why this matters**: agents follow skills mechanically. A MUST in an SOP without a corresponding skill step is a suggestion, not a requirement.

### Check 6: No Stray Project SOPs Directory for Process

If the project has a `Documentation/SOPs/` directory (or equivalent), every file in it must be a genuine step-by-step implementation procedure (mandatory, mechanical). Thinking frameworks (philosophy, brand, design-decision guides) belong in `Documentation/` directly — not under SOPs/.

For each file in the project's SOP directory, read the first 20 lines. Flag any that read as decision-framework content (no numbered mandatory steps, no enforcement mechanism referenced) and recommend moving them out.

### Check 7: Project-Specific Canonical Files

Verify that the files the project's CLAUDE.md references actually exist. Pull every `@`-ref and bare path from the project root CLAUDE.md and check each.

**PASS** if all cross-references resolve.
**FAIL** if any points at a missing file. Report each broken ref.

### Check 8: Linear Roadmap Audit (HOMEBASE-SOP-013)

If the project has any app with `roadmap.enabled: true` in `<project>/.homebase/project.yml`:

1. Run `homebase roadmap audit` (read-only; no authorization required).
2. Verify `registry/ROADMAP.md` is present in homebase and was regenerated within the last 48 h.
3. Verify `registry/roadmap-snapshot.yml` is present and matches today's live state (spot-check one team).
4. Verify every `<project>/.homebase/project.yml` `apps[].roadmap.linear_team_key` matches the canon in `@~/code/homebase/standards/LINEAR_WORKSPACE.md`.

**PASS** if audit exits 0, snapshots are fresh, and every key matches the canon.
**FAIL** if audit reports drift, snapshot is stale, or any team key is off-canon.

Remediation: `homebase roadmap render` refreshes snapshots; team-key drift is fixed by updating the project YAML and the canon together (never one without the other).

## Output Format

```
## Governance Audit Report — {YYYY-MM-DD}

### Passed ({N} checks)
- [x] Check 1: No inline app lists
...

### Failed ({N} checks)
- [ ] Check 5: Skill/SOP alignment
  - HOMEBASE-SOP-001 § A4 requires sub-issue linking via GraphQL; /new-issue has no enforced step for it.
...

### Remediation
1. {specific action per failure}
```

## When to Run

- Quarterly (every ~90 days).
- Before major releases.
- When agent behaviour seems inconsistent or outdated.

## After Completion

Update the project's `.claude/recurring-tasks.json`: find the task with `"id": "audit-governance"`, set its `last_run` to today's date, write the file back.
