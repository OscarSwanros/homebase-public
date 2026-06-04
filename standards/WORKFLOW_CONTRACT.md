# Workflow Contract

**Status**: canonical control flow (Phase 0)
**Owner**: `technical-project-manager`
**Replaces (as control)**: HOMEBASE-SOP-001 §A–C, HOMEBASE-SOP-005 §gates, HOMEBASE-SOP-006 (collapsed), HOMEBASE-SOP-013 §homebase-roadmap-CLI surface
**Pairs with**: `@~/code/homebase/governance/AGENT_OPERATING_CONTRACT.md`, `@~/code/homebase/governance/AUTONOMY_CHARTER.md`

This document is reference for the workflow control plane. The control itself lives in two places:

1. `<project>/.homebase/workflow.yml` — the per-project declarative contract.
2. `bin/homebase work …` — the CLI that enforces the contract.

SOPs explain *why* the rules in the contract exist; this document explains *how* the contract works mechanically. Read this once per machine; consult the schema (`@~/code/homebase/schemas/workflow.schema.json`) for field-level reference.

---

## Substrates

| Substrate | Lives at | Role |
|---|---|---|
| Contract | `<project>/.homebase/workflow.yml` (validated by `schemas/workflow.schema.json`) | Declares what the workflow requires for this project: tracker, gates, agents, checks, hard rules. |
| CLI | `bin/homebase work {start, checkpoint, finish, status, cancel, resume, init, ship}` | The only legal mutation surface. Reads the contract; enforces the gates; mutates Linear and git. |
| Generation | `bin/homebase render-claudemd` | Renders marker-delimited regions of each project's root `CLAUDE.md` from `workflow.yml` + `governance/HARD_RULES.yml`. |
| Gates | five layers (see below) | Composable enforcement. The CLI is the legal path; the gates make it the only path. |

---

## Five-layer enforcement

Each layer closes a different deviation surface. The contract is enforceable iff every layer is in place; deviation requires bypassing all five.

### Layer 1 — `PreToolUse(Bash)`

Hooks installed in `.claude/settings.json`. Run before every Bash invocation; block by emitting `{"decision":"block","reason":"…"}` JSON.

| Hook | Blocks |
|---|---|
| `claude-precommit.sh` | `git commit --no-verify` / `-n` bypass; self-heals `core.hooksPath=.githooks` |
| `gh-cli-guard-hook.sh` | `gh` CLI unless `TPM_AUTHORIZED=1` |
| `linear-cli-guard-hook.sh` | Linear API access unless `LINEAR_TPM_AUTHORIZED=1`; also blocks `homebase {roadmap bootstrap, roadmap capture, work start, work checkpoint, work finish}` without the env var |
| `work-cli-guard-hook.sh` (added in Phase 3) | Manual `git commit` / `git push` / branch ops when work-state exists, unless `HOMEBASE_WORK_AUTHORIZED=1` (set only by `homebase work` internals) OR `HOMEBASE_OFF_CONTRACT=1` (operator opt-out for chore / governance work — HMB-18); force-push to protected refs always requires `HOMEBASE_FORCE_PUSH_CONFIRMED=1` regardless; `homebase deploy` / `kamal deploy` require `HOMEBASE_DEPLOY_CONFIRMED=1` |

Allow-list (always permitted regardless of work-state): `git status|diff|log|show|blame|branch (-l)|remote -v|rev-parse|ls-files|stash list`, `git add`, `git fetch`, `git pull --ff-only`, `git config --get`, `homebase work *`, `homebase status|list|index`.

### Layer 2 — Local git hooks

Live in `.githooks/`. Invariant to caller process — `python3 -c "subprocess.run(['git', ...])"` does not bypass them.

| Hook | Validates |
|---|---|
| `commit-msg` → `commit-sop-check.sh` + `commit-changelog-check.sh` | Trailer regex per `scripts/lib/issue-trailer.sh`; per-app CHANGELOG presence |
| `pre-commit` | Universal: registry drift in homebase + work-state coherence (staged paths inside `apps/<state.app>/`, branch matches `state.branch`, "looks like product work but no work-state" check escapable via `chore:` prefix or `HOMEBASE_OFF_CONTRACT=1`) |
| `pre-push` (added in Phase 3) | Refuses push unless `HOMEBASE_WORK_AUTHORIZED=1`; on `HOMEBASE_WORK_PHASE=finish` requires closing keyword on HEAD; blocks force-push to protected refs |

The trailer regex is single-sourced in `scripts/lib/issue-trailer.sh`. Every consumer (commit-sop-check, task-completed, work finish gate 4) sources from there — no regex duplication.

### Layer 3 — Session lifecycle hooks

Bracket the agent's session. Catch deviation that spans tool-call gaps.

| Hook | Behaviour |
|---|---|
| `session-start.sh` | Warns of uncommitted changes from a prior session; surfaces active work-state; prints a Charter red-list banner if `HOMEBASE_UI_VERIFICATION=off` |
| `task-created.sh` | Warn-only `#N` nudge; blocks creation if task subject matches workflow keywords but no work-state exists (escapable via `HOMEBASE_OFF_CONTRACT=1`) |
| `task-completed.sh` | Blocks completion on dirty tree, unpushed commits, missing trailer, OR when work-state exists with `finished_at` unset (gated by `workflow.yml.session_end.require_homebase_work_finish`, default true) |
| `teammate-idle.sh` | Blocks idle with uncommitted changes |
| `ui-verification-check.sh` (Stop hook) | Blocks UI commits without `Verified-*:` trailer in strict mode; short-circuits when `HOMEBASE_WORK_PHASE=finish`. UI detection (per HMB-19) matches template extensions (`.erb`/`.html`/`.scss`/etc.), UI-shaped paths (`/Views/`, `/Screens/`, `/Components/`, `/UI/`), or UI-shaped Swift / TSX filenames (`*View.swift`, `*Screen.swift`, `*Sheet.swift`, `*Cell.swift`, `*Layout.swift`). Non-UI Swift / TSX changes don't auto-trigger. |

### Layer 4 — `homebase work finish` itself

The load-bearing gate. Deterministic 13-step sequence (see § Finish gates). Each gate calls into existing single-source validators; the CLI never duplicates regex or check logic.

### Layer 5 — CI reusable workflows

Clean-logapp replay; agent cannot tamper.

| Workflow (in `.github/workflows/`) | Purpose |
|---|---|
| `commit-sop-check.yml` | Re-runs commit-msg validation against every commit in the push/PR range |
| `validate-docs.yml` | Re-runs HOMEBASE-SOP-003 validation |
| `extract-changelog.yml` | Used by release flow |
| `validate-workflow-yml.yml` | Schema-validates `.homebase/workflow.yml` |
| `work-finish-validate.yml` (Phase 3) | Re-runs gates 4, 5, 6, 8, 9 against the PR HEAD in a clean runner |
| `work-linear-state.yml` (Phase 3) | Asserts the issue referenced by the PR is in the team's `in_review` Linear state (not `backlog`/`done`/`cancelled`) |
| `work-state-integrity.yml` (Phase 3) | Schema-validates the PR-branch `.homebase/work-state.json`; asserts referenced issue matches PR title + closing trailer; asserts `finished_at` is recent |
| `render-claudemd-drift.yml` (Phase 2) | Asserts no drift between `workflow.yml` and the rendered CLAUDE.md regions |

Operator-level branch protection (required status checks on `main`) is a documented prerequisite. Without it, no in-repo layer can prevent a manual merge with red CI.

---

## The contract — fields at a glance

Full schema: `@~/code/homebase/schemas/workflow.schema.json`. The fields the CLI cares about most:

| Field | Purpose |
|---|---|
| `version` | Schema version (const 1). The CLI refuses unknown versions. |
| `primary_tracker` | `linear` (default) or `github`. Determines issue-key shape and which API the CLI calls. |
| `linear.state_kinds` | Maps four canonical kinds (`backlog`, `in_progress`, `in_review`, `done`) to Linear team-state names. Read live; first match wins. |
| `linear.required_labels_at_start` | Labels the issue must have before `work start` accepts it (typically `["roadmap"]`). |
| `start_gates.*` | Booleans the CLI evaluates at `work start`. Defaults conservative. |
| `finish_gates.*` | Booleans the CLI evaluates at `work finish`. Defaults conservative. |
| `release_gates.*` | SOP-005 phases as gates for `work ship`. |
| `required_agents.by_platform` | Per-platform mandatory consultations (e.g. `ios: [swift-architect, ui-ux-designer]`). |
| `required_agents.by_change_kind` | Per-kind mandatory consultations (e.g. `safety_critical: [dive-science-advisor]`). |
| `required_agents.path_scoped` | Path-glob → required-agents map. Walked top-to-bottom; first match wins. Used for content-vs-code splits. |
| `required_checks[]` | Named commands run as gates (`{ name, command, when, blocking, min_interval, paths }`). The optional `paths` glob array path-scopes a check: it runs only when at least one path in the diff (`state.base_sha..HEAD`) matches at least one glob. Use for platform-scoped validation in monorepos. |
| `branch.naming_pattern` | Branch-name template, tokens `{scope}/{issue}-{slug}`. |
| `hard_rules[]` | Slugs from `governance/HARD_RULES.yml` adopted by this project. Render-claudemd joins them. |
| `session_end.require_homebase_work_finish` | When true, `task-completed.sh` blocks Claude Code task completion until `work finish` ran for the active issue. |
| `apps[<slug>]` | Per-app overrides. Same shape as top-level minus `version` and `apps`. |

### Per-app override semantics

Per-app overrides under `apps[<slug>]` deep-merge for objects, replace for arrays. So:

- `apps[gascalc].finish_gates.apple_ui_xcuitest_required: true` overrides only that one boolean; the rest of `finish_gates` inherits from the project default.
- `apps[gascalc].required_checks: [...]` REPLACES the project-level `required_checks` array entirely. Per-app checks must list everything the app needs; they do not concatenate.
- `apps[gascalc].hard_rules: [...]` REPLACES the project-level array. Apps that need a superset of project rules list both.

Justification: arrays-as-replace mirrors how operators think about "this app needs its own list", and avoids ordering/dedup ambiguity.

---

## Work-state lifecycle

`<project>/.homebase/work-state.json` is the runtime state file. Gitignored. One per worktree.

```json
{
  "schema_version": 1,
  "issue": "HMB-8",
  "issue_url": "https://linear.app/your-workspace/issue/HMB-8/...",
  "github_mirror": "acme-co/homebase#42",
  "app": "homebase",
  "platforms": ["cli"],
  "branch": "phase-0/hmb-8-foundation",
  "base_sha": "...",
  "started_at": "2026-04-28T...",
  "linear_state_at_start": "Backlog",
  "linear_state_now": "In Progress",
  "kind": "feature",
  "override_kind": null,
  "checkpoints": [{ "at": "...", "note": "...", "commit_sha": "..." }],
  "finished": false,
  "finished_at": null,
  "finish_outcome": null,
  "last_gate_passed": 0
}
```

State transitions:

- `homebase work start <KEY>` creates the file, sets `kind`, transitions Linear `backlog → in_progress`.
- `homebase work checkpoint` appends to `checkpoints[]`, optionally moves Linear state.
- `homebase work finish` runs gates; on success, lands work directly on `main` (rebase + FF + branch cleanup), transitions Linear `in_progress → done`, sets `finished: true`, `finished_at`, `finish_outcome=done`. The file is NOT deleted (`task-completed.sh` reads it). (HMB-22)
- `homebase work cancel` removes the file (after writing an audit-log line); Linear stays in current state unless `--reset-linear`.
- `homebase work resume <KEY>` rebuilds the file from observed reality (current branch + Linear read) for crash recovery.

---

## Start gates (`homebase work start`)

Evaluated in order; first failure aborts (exit 2).

1. **No active work-state.** Refuses if `.homebase/work-state.json` exists with `finished:false`. Suggest `cancel` or `finish` for the prior issue.
2. **Issue resolves.** Linear: `mcp__plugin_linear_linear__get_issue` returns non-null. GitHub: TPM-mediated `gh issue view`.
3. **App resolves.** `--app` flag wins; otherwise inferred from `issue.project.id` matched against `apps[].roadmap.linear_project_id`. Ambiguity is fatal.
4. **`start_gates.tree_must_be_clean`.** `git status --porcelain` empty.
5. **`start_gates.branch_must_be_main_or_clean`.** Current HEAD is `branch.base`, OR a clean feature branch with no diverged history.
6. **`start_gates.issue_must_be_in_correct_project`.** `issue.project.id == apps[<slug>].roadmap.linear_project_id`.
7. **`start_gates.issue_must_have_acceptance_criteria`.** Issue body contains a `## Acceptance Criteria` section with at least one `- [ ]`.
8. **`start_gates.issue_must_have_required_labels`.** Intersection of issue labels and `linear.required_labels_at_start` is non-empty.
9. **`start_gates.plan_approval_required`.** When true, requires a recent plan-approval marker. Default off (Plan-mode approval is implicit per AUTONOMY_CHARTER §5).

On success: Linear state moves to first matching `in_progress` kind; branch created if `branch.auto_create`; work-state file written; `WORK_KEY` and `HOMEBASE_WORK_AUTHORIZED=1` exported via the calling shell.

---

## Finish gates (`homebase work finish`)

Evaluated in order; first failure aborts (exit 2). Idempotent: re-runs after partial failure pick up at `state.last_gate_passed + 1`. Speed budget: < 30 s for typical apps (gate 8 — validate — is the only slow gate).

| # | Gate | Validator |
|---|---|---|
| 0 | `preflight` | Toolchain + env prerequisites per the project's `domains:` (ios/macos → `xcode-select` resolves to `Xcode.app`; android → `ANDROID_HOME` + JDK via `mise exec`; web → `bundle check`). Re-evaluates every run; not memoized. Fast-fails in <1s. Bypass: `HOMEBASE_SKIP_PREFLIGHT=1` (Charter override). |
| 1 | `state-loaded` | Read & schema-validate `work-state.json` |
| 2 | `branch-on-track` | `git rev-parse HEAD` matches `state.branch` |
| 3 | `tree-clean` | `git status --porcelain` empty |
| 4 | `commits-trailered` | Calls `commit-sop-check.sh` per commit `state.base_sha..HEAD` |
| 5 | `closing-keyword-present` | Uses `TRAILER_LINE_RE` from `scripts/lib/issue-trailer.sh` (closing-only subset) |
| 6 | `changelog-current` | Calls `commit-changelog-check.sh` per commit |
| 7 | `linear-in-progress` | Linear read-only; issue state matches `in_progress` or `in_review` kind |
| 8 | `validate-passes` | Runs each `required_checks[].command` where `when=on_finish && blocking=true`; honors `min_interval` throttle |
| 9 | `ui-verified` | Calls `ui-verification-check.sh` (sets `HOMEBASE_WORK_PHASE=finish`). When `finish_gates.apple_ui_xcuitest_required` is set, additionally rejects bare `Verified on simulator:` on Apple-shaped paths (HMB-21). |
| 10 | `landed-to-main` | Rebase work branch onto `origin/main`, FF-push `HEAD:main`, delete branch (origin + local), switch local back to `main`, FF. When the work-state branch IS `main`, just FF-push origin. (HMB-22) |
| 11 | _retired_ | Reserved slot — was `pr-opened-or-updated`. Direct-to-main flow has no PR step (HMB-22). |
| 12 | `linear-transitioned` | Linear mutation to first matching `done` kind. (HMB-22 — was `in_review`.) |
| 13 | `state-finalised` | Sets `finished_at`, `last_commit_sha`. Does NOT delete state. |

The legacy `--no-pr` and `--ship` flags are accepted as deprecated no-ops for back-compat; finish always lands directly on main and transitions Linear to `done`. If gate 10 hits a rebase conflict it auto-aborts and instructs the operator to resolve manually before re-running.

---

## Kind overrides

The `kind` field in work-state.json (set by `homebase work start --kind <kind>`) selects a subset of finish gates. The default is `feature` (all gates apply).

| Kind | Gates skipped | Required env |
|---|---|---|
| `feature` (default) | none | none |
| `chore` | 6 (changelog), 8 (validate), 9 (UI verification) | none — green-list |
| `hotfix` | 6 (changelog — added in release commit), 7 (linear state — issue may not exist yet), 11 (PR optional) | `HOMEBASE_HOTFIX_AUTHORIZED=1` (Charter red-list) |
| `release` | 6 (release commits don't need per-app changelog), 11 (release flow uses tags) | `HOMEBASE_DEPLOY_CONFIRMED=1` if shipping |

Kind is recorded in work-state and replayed by CI's `work-state-integrity.yml`.

---

## Required-agents resolution

When `homebase work finish` evaluates gate 9 (UI), 8 (validate), or any custom advisory check, it computes the list of "required agents for this work":

1. Walk `state.platforms`; for each, union `required_agents.by_platform[<platform>]`.
2. Determine `change_kind`s: `ui` if any commit touched UI files (per `ui-verification-check.sh`'s `UI_PATTERN`); `safety_critical` if `apps[<slug>].safety_critical: true` AND any commit touched safety paths; `copy` if any commit touched content/copy paths (declared in workflow.yml); `architecture` if any commit added a new top-level module; etc.
3. For each `change_kind`, union `required_agents.by_change_kind[<kind>]`.
4. Walk `required_agents.path_scoped[]` top-to-bottom; for each entry whose `paths` glob matches at least one staged path, union the entry's `by_change_kind[<kind>]`. **First match per path wins** — subsequent entries do not contribute for that path.
5. Deduplicate.

The resulting list is **advisory** at the CLI level — `work finish` prints it but does not block on the agent having been consulted (agent attribution lives in commit trailers and PR review). Future v2 may add a `Reviewed-by:` trailer requirement.

---

## Generation pipeline

`bin/homebase render-claudemd <project>` rewrites marker-delimited regions of `<project>/CLAUDE.md` from data:

| Marker pair | Source |
|---|---|
| `<!-- BEGIN homebase:adopted-sops -->` … | `hard_rules[]` joined against `governance/HARD_RULES.yml` `sop:` fields |
| `<!-- BEGIN homebase:hard-rules -->` … | `hard_rules[]` joined against `governance/HARD_RULES.yml` `number/short/body/enforced_by` fields, sorted by number |
| `<!-- BEGIN homebase:required-checks -->` … | Per-app table: `apps[<slug>].required_checks[]` |
| `<!-- BEGIN homebase:required-agents -->` … | `required_agents.by_platform` + `by_change_kind` flattened |

**Operator prose outside markers is sacred.** The renderer never edits non-marker text.

Triggers:

1. Manual: `bin/homebase render-claudemd <project>`.
2. Wired into `bin/homebase index` (regenerates registry AND each project's CLAUDE.md regions).
3. CI: `render-claudemd-drift.yml` runs `--check`; non-zero on drift; never auto-commits.

---

## Authorization model

The CLI never invents authorization. It composes existing gatekeepers:

- **GitHub mutations** (gates 11, parts of 13) — require `TPM_AUTHORIZED=1` in the calling shell. The `technical-project-manager` agent sets it for a batch and unsets it.
- **Linear mutations** (gates 7-read, 12-mutate) — require `LINEAR_TPM_AUTHORIZED=1`. Same pattern.
- **`HOMEBASE_WORK_AUTHORIZED=1`** — set by `homebase work` internals for the duration of a CLI invocation. The pre-tool and pre-push hooks honour it. Only `homebase work` verbs set it.
- **`HOMEBASE_OFF_CONTRACT=1`** — operator opt-in for genuinely off-contract work (typo fixes, governance-only edits, README updates). Layer 2 pre-commit and Layer 3 task-created surface this in their failure messages.
- **Charter red-list env vars** — `HOMEBASE_DEPLOY_CONFIRMED=1`, `HOMEBASE_FORCE_PUSH_CONFIRMED=1`, `HOMEBASE_HOTFIX_AUTHORIZED=1`. Set only after explicit operator confirmation per AUTONOMY_CHARTER red-list.

Plan-mode approval is the implicit confirmation for everything green and yellow that follows from the plan, including every `homebase work` call. Re-confirming individual mechanical steps is a deferral defect (see AUTONOMY_CHARTER §"Required follow-ups").

---

## When the contract and a hand-written doc disagree

The contract wins. Specifically:

- If `<project>/CLAUDE.md` (a hand-written section outside markers) and `.homebase/workflow.yml` disagree on a hard rule or required check, the workflow.yml is operative. Edit the CLAUDE.md.
- If an SOP (`sops/HOMEBASE-SOP-*.md`) and `.homebase/workflow.yml` disagree on a procedure, the workflow.yml is operative. The SOP needs an update so the explanation matches.
- If an agent prompt (`agents/*.md`) and the AGENT_OPERATING_CONTRACT disagree on what an agent should do for workflow, the operating contract wins. The agent prompt needs trimming.

---

## Cross-references

- `@~/code/homebase/governance/AGENT_OPERATING_CONTRACT.md` — the 10-line agent-side contract.
- `@~/code/homebase/governance/AUTONOMY_CHARTER.md` — when to act vs. confirm; complements this contract.
- `@~/code/homebase/governance/HARD_RULES.yml` — slug → display data registry.
- `@~/code/homebase/schemas/workflow.schema.json` — full schema for `.homebase/workflow.yml`.
- `@~/code/homebase/templates/workflow.yml.tmpl` — annotated template; used by `homebase work init`.
- `@~/code/homebase/scripts/lib/issue-trailer.sh` — single source for trailer regex.
- `@~/code/homebase/standards/LINEAR_WORKSPACE.md` — Teams, Projects, Milestones, canonical labels.
- `@~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` — explanation: issue-first, commit format, trailers.
- `@~/code/homebase/sops/HOMEBASE-SOP-005-RELEASE_PROCESS.md` — explanation: release semantics for the `release_gates` block.
- `@~/code/homebase/sops/HOMEBASE-SOP-007-UI_VERIFICATION.md` — explanation: render-and-observe rationale for gate 9.
- `@~/code/homebase/sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md` — explanation: Linear topology and the gatekeeper rule.
