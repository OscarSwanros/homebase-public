---
name: new-issue
description: "Wrapper around `homebase work start`. Use when starting new tracked work — validates start_gates, creates branch, transitions Linear backlog → in_progress."
---

# New Issue — `homebase work start` wrapper

The CLI is the contract. This skill is a thin wrapper.

## Run

```
homebase work start <ISSUE-KEY> [--app <slug>] [--branch <name>] [--no-branch] [--kind feature|chore|hotfix|release]
```

## What it does

1. Resolves the issue (`KEY-N` from Linear; `#N` from GitHub when `primary_tracker == github`).
2. Resolves the app (`--app` flag wins; otherwise inferred from the issue's Linear Project).
3. Evaluates `start_gates` from the project's `.homebase/workflow.yml`:
   - tree clean
   - issue exists in correct project
   - issue has `## Acceptance Criteria` with at least one `- [ ]`
   - issue has the required labels (typically `roadmap`)
   - branch is base (`main`) or a clean feature branch
4. Creates the work branch (default pattern `{scope}/{issue}-{slug}`).
5. Moves Linear from `backlog` → `in_progress`.
6. Writes `.homebase/work-state.json` and `.homebase/.work-env`.

**Source the env file** to authorise commits and pushes for the duration of the work-state without per-command env prefixes:

```
source .homebase/.work-env
```

The env file exports `HOMEBASE_WORK_AUTHORIZED=1`, `WORK_KEY`, `WORK_APP`, `WORK_BRANCH`. `homebase work finish` and `homebase work cancel` delete it.

**Operator vs agent**: sourcing works for an operator typing commands in a shared terminal — every command runs in that one shell. Agents that spawn one process per command (Claude Code's Bash tool, CI runners) get a fresh shell per invocation; for those, prefix the relevant call with `env HOMEBASE_WORK_AUTHORIZED=1 <cmd>`.

## When the issue doesn't exist yet

Create it first, then run start. The TPM agent is the gatekeeper for both:

```
# Linear (preferred — primary tracker per HOMEBASE-SOP-013)
mcp__plugin_linear_linear__save_issue \
  --teamId <TBL|TFD|HMB-team-id> \
  --projectId <project-id> \
  --title "..." \
  --description "...## Acceptance Criteria\n- [ ] ...\n" \
  --labelIds <roadmap-label-id>

# Or GitHub when the project still uses #N tracking
gh issue create --title "..." --body "..." --label roadmap
```

Then `homebase work start <KEY>`.

## Authorisation

`homebase work start` moves Linear state, which requires `LINEAR_TPM_AUTHORIZED=1`. The `technical-project-manager` agent sets it for the start batch and unsets it after.

## Kind overrides

- `--kind feature` (default) — full gate set.
- `--kind chore` — skips gates 6 (changelog), 8 (validate), 9 (UI). For typo fixes, governance edits, README updates.
- `--kind hotfix` — Charter red-list; requires `HOMEBASE_HOTFIX_AUTHORIZED=1`. See `/hotfix`.
- `--kind release` — for release-flow commits.

## Related

- `homebase work checkpoint` — mid-flight signal.
- `homebase work finish` — close out.
- `@~/code/homebase/standards/WORKFLOW_CONTRACT.md` § Start gates — full contract.
- `@~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` — why issue-first.
- `@~/code/homebase/sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md` — Linear topology.
