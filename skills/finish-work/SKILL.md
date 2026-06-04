---
name: finish-work
description: "Wrapper around `homebase work finish`. Use when finishing work on an issue — runs the 13-step finish-gate sequence (tree clean, trailers, closing keyword, validate, UI verification, push, PR, Linear transition)."
---

# Finish Work — `homebase work finish` wrapper

The CLI is the contract. This skill is a thin wrapper.

## Run

```
homebase work finish [--no-pr] [--ship] [--allow-empty] [--append-closing]
```

`--no-pr` for direct-to-main projects (most solo flows). `--ship` to transition Linear directly to Done (chore / docs cycles). `--append-closing` always re-evaluates gate 5 (closing-keyword-present) and auto-creates the empty `Closes <KEY>` commit when HEAD lacks one — safe to leave on across iterative finish attempts even when amended commits on the branch dropped the closing keyword.

## What it does

Runs the 14-step finish-gate sequence in order, idempotent on re-runs:

0. preflight — toolchain + env per project `domains:` (xcode-select / ANDROID_HOME / JDK / bundle check). Re-evaluates every run; not memoized. Fast-fails in <1s.
1. state-loaded — reads `.homebase/work-state.json`.
2. branch-on-track — HEAD matches `state.branch`.
3. tree-clean — `git status --porcelain` empty.
4. commits-trailered — every commit on the branch has a valid trailer.
5. closing-keyword-present — HEAD has `Closes` / `Fixes` / `Resolves`.
6. changelog-current — `feat(scope)` / `fix(scope)` commits stage their CHANGELOG.
7. linear-in-progress — Linear says the issue is `in_progress` / `in_review`.
8. validate-passes — runs each `apps[<slug>].workflow.required_checks` entry.
9. ui-verified — UI commits carry the `Verified ...` trailer.
10. branch-pushed — `git push -u origin <branch>` (fast-forward only).
11. pr-opened-or-updated — creates / updates the PR with `Closes <KEY>`.
12. linear-transitioned — moves the issue to `in_review` (or `done` for `--ship`).
13. state-finalised — writes `finished_at`, `pr_number`, last commit SHA.

If any gate fails, the CLI prints the gate name and a one-block remediation. Apply the fix, rerun.

## Gate-failure recovery

The most common gate failure is **gate 5 (closing-keyword-present)** — the work was committed with `Refs <KEY>` but never given a closing trailer.

The simplest fix is to just rerun finish with `--append-closing`:

```
homebase work finish --append-closing --no-pr
```

That creates the empty `Closes <KEY>` commit automatically and re-evaluates gate 5. If you'd rather write the commit yourself first:

```
HOMEBASE_WORK_AUTHORIZED=1 git commit --allow-empty -m "$(cat <<'EOF'
Closes <KEY>

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

Then rerun `homebase work finish` (no flag needed).

## Closure audit

Before posting your completion summary, scan it for "Required follow-ups", "Things to do next", "Pending", or numbered chore lists. For each item, take one of rule **14**'s three paths (`AGENT_OPERATING_CONTRACT.md`):

- **(a)** in-scope green → do it now in the current worktree, then re-run finish.
- **(b)** out-of-scope governance / canon / SOP edit that has no Linear issue → `homebase work chore "<desc>"` in a fresh worktree (HMB-86 chore-fast-path) **after** this finish lands.
- **(c)** out-of-scope OR red-list code work → delegate to TPM to file a Linear issue with `## Acceptance Criteria` **after** this finish lands.

Do not post a summary that contains an unactioned item. "Required follow-ups" is the deferral defect rule 14 closes — every follow-up is either done, filed, or scoped out with a one-line note explaining why it can't follow paths (a)–(c).

## Authorisation

`homebase work finish` mutates Linear (gate 12) and creates / edits a PR (gate 11). Both require:

- `LINEAR_TPM_AUTHORIZED=1` for the Linear move.
- `TPM_AUTHORIZED=1` for the PR create / edit.

In agent context, the `technical-project-manager` agent sets these for the duration of the batch and unsets them.

## Related

- `homebase work start <KEY>` — opens the work-state.
- `homebase work checkpoint` — mid-flight signal; optional state move + push.
- `homebase work cancel` — abandons the work-state.
- `@~/code/homebase/standards/WORKFLOW_CONTRACT.md` § Finish gates — full contract.
- `@~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` — explanation: why issue-first, why these trailer keywords.
