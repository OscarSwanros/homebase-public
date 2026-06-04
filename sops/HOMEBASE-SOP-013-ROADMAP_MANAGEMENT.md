# HOMEBASE-SOP-013: Roadmap Management

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Canonical procedure for building, maintaining, and shipping roadmaps across every homebase-adopting app. **Linear** is the canonical roadmap substrate; **GitHub** remains the canonical atomic issue tracker; **`CHANGELOG.md`** remains the canonical shipped-history record.

## Purpose

Establish one reliable, standard way to plan forward work across every app so the operator can:

1. See what is shipping next across all 10 apps in a single view ("portfolio").
2. Know which apps block which (cross-app dependencies).
3. Graduate planned work → shipped work through a mechanical, repeatable flow instead of per-app ad-hoc ROADMAP.md files with divergent shapes.

CHANGELOG discipline already answers *what shipped*. This SOP answers *what is planned*.

## Scope

**Applies to**: every app in `registry/PROJECTS.md`. Default is adopted; opt-out is explicit (`roadmap.enabled: false` in the app's `project.yml` entry).

**Agents involved**:

- `technical-project-manager` — sole executor of Linear API mutations (analogous to the `gh` CLI gatekeeper role from SOP-002). Holds `LINEAR_API_KEY`.
- `example-product-pm`, `example-product-pm`, `example-product-pm`, `diving-product-manager` — own Project scope, priority, cancellations, and Initiative assignment for the apps in their brand.
- All other agents — read-only via `bin/homebase roadmap portfolio`; no direct Linear API access.

**Per-project specifics.** Each project declares its apps' Linear team keys and team IDs in `<project>/.homebase/project.yml` under `apps[].roadmap`. Projects that retain a GitHub Projects V2 board continue to observe **SOP-012** (legacy); new work goes through SOP-013.

---

## Relationship to Other SOPs

| SOP | Interaction |
|---|---|
| **SOP-001** Development Workflow | Issue-first rule unchanged. Commit trailers accept either GitHub `#N` or Linear `KEY-N` (see SOP-001 §0); both auto-close their respective sides via Linear's GitHub integration. `/new-issue` skill gains `--linear-project <X.Y.Z>` flag to also create (or link) a Linear issue that lands on the appropriate roadmap Project. CHANGELOG per-commit discipline (§ B4) is unchanged. |
| **SOP-002** GitHub API Usage | TPM is also the Linear API gatekeeper. One agent, two APIs. No other agent may call Linear API directly; the `scripts/hooks/linear-cli-guard-hook.sh` PreToolUse hook enforces this unless `LINEAR_TPM_AUTHORIZED=1`. |
| **SOP-005** Release Process | New final step — "Roadmap graduation" — calls `homebase roadmap project ship <app> <version>`, transitioning the Linear Project from `In Progress` to `Completed`. Blocks the release from being marked closed until the Project transition succeeds. |
| **SOP-009** New App Onboarding | New apps create their Linear team as part of onboarding via `homebase roadmap init <app>`. |
| **SOP-012** GitHub Project Management | **Legacy**. SOP-013 supersedes it for all new roadmap work. SOP-012 remains in force for any project that retains a GitHub Projects V2 board. |

---

## Workspace Structure

Canonical topology — Teams (`TBL`, `TFD`, `HMB`), Projects (one per app), Milestones (= releases, SemVer), Initiatives (optional cross-app themes), and the canonical label set — lives in `@~/code/homebase/standards/LINEAR_WORKSPACE.md`. Read that standard for the tables and the audit invariants enforced by `homebase roadmap audit`. This SOP governs the **operational rules** that apply on top of that topology:

- **Issue-ID prefixes are immutable.** Once a Team key exists (e.g. `TBL-42`), it never renames — historical issue IDs outlive any rename. Canon changes are handled as new-Team + migration, never in-place. (Linear additionally reserves the identifier `Studio` against a pre-existing rename, which is why "Studio" uses `TBL`.)
- **Project state stays `started` while the app is active.** Apps have no finish line; releases do. Projects move to `canceled` only when an app is retired (per SOP-009).
- **Shipping a release marks its Milestone Done** via SOP-005 Phase C.5 (`homebase roadmap project ship <app> <version>`). The parent Project never transitions on a release.
- **Adding a new app**: register it in `registry/PROJECTS.md` and `CANONICAL_PROJECTS` in `scripts/roadmap/linear.rb`, then re-run `homebase roadmap bootstrap` — idempotent, only the new Project is created.
- **Adding a new Team** is rare (only when spinning off a new monorepo). Update the table in `standards/LINEAR_WORKSPACE.md` AND `scripts/roadmap/linear.rb` in the same commit, then re-run `homebase roadmap bootstrap`.
- **Initiative ownership.** Each Initiative is owned by the PM agent most relevant to its primary theme; cross-app themes (e.g. `Decompression overhaul`, `iOS 19 compatibility`) and quarterly portfolio views (`Q2 2026 — Portfolio`) are both valid uses.

---

## GitHub ↔ Linear Sync Contract

**Principle**: GitHub is atomic. Linear is structural. Commits and PRs stay on GitHub; Linear wraps them for planning.

### The native integration

Linear's GitHub integration is enabled per team. Once enabled:

- Creating a Linear issue (e.g. `TBL-42`, `TFD-17`, `HMB-3`) auto-creates a mirror GitHub issue in the repo declared against the Project.
- Mentioning the Linear ID in a PR title, branch name, or commit body Magic-Links the two sides.
- Merging a PR that references the Linear ID auto-closes the Linear issue.
- Closing the GitHub mirror also closes Linear (bidirectional, barring webhook flakes).

### What stays exactly the same

- **Commit-trailer keywords** — `Closes` / `Fixes` / `Refs` / `Resolves` unchanged; either GitHub `#N` or Linear `KEY-N` is accepted (SOP-001 §0 and §B2). Linear's GitHub integration mirrors closure both ways.
- **CHANGELOG per-commit discipline** — SOP-001 § B4 unchanged.
- **Issue labels / milestones / assignees on GitHub** — unchanged.
- **`gh` CLI gatekeeper** — TPM still sole authority for GitHub operations, per SOP-002.

### What's new

- **Issue creation** may originate from either side:
  - GitHub-first (default, backward compatible) — agent creates a GitHub issue; PM can later associate it with an app's Linear Project manually, or it stays on GitHub only.
  - Linear-first — `/new-issue --linear-project <app>` creates on Linear under the app's Project; Linear's integration creates the GitHub mirror.
- **Release ship** — SOP-005 gains a roadmap-graduation step that marks the release Milestone Done inside the app's Linear Project. The Project itself stays `started`.

### Sync failure handling

Linear's GitHub integration occasionally misses webhooks. Symptom: a GitHub issue closes but the mirror Linear issue stays open (or vice versa). `homebase roadmap audit` detects and reports these. `homebase roadmap reconcile` (deferred to a later SOP revision once shown necessary) manually resolves them.

---

## CLI Surface — `homebase roadmap`

The homebase CLI owns only the canon-driven glue operations (bootstrap, capture, render, audit) plus read-only diagnostics. Individual Linear entity mutations (team/project/label/milestone/initiative CRUD, issue updates) live in the **Linear MCP plugin** (for Claude-driven interactive work) and the **Linear web UI** (for direct human edits).

```
# Mutations (LINEAR_TPM_AUTHORIZED=1 required; blocked by linear-cli-guard-hook):
homebase roadmap bootstrap [--dry-run]           # idempotent workspace setup from canon
homebase roadmap capture <app>                   # refresh Linear IDs into <project>/.homebase/project.yml

# Read-only:
homebase roadmap render                          # writes registry/ROADMAP.md + roadmap-snapshot.yml
homebase roadmap audit                           # verifies live state matches canon
homebase roadmap portfolio [--json]              # terminal summary of every Project + Milestones
homebase roadmap org                             # sanity check; prints workspace + viewer
homebase roadmap team list                       # list Teams
homebase roadmap project list [--team KEY]      # list Projects (apps)
```

### What lives where

| Operation | Do it via |
|---|---|
| Initial workspace creation (Teams + canonical labels + Projects) | `homebase roadmap bootstrap` |
| Adopt a new app into an existing Team | edit `CANONICAL_PROJECTS` in `linear.rb` → re-run `bootstrap` |
| Write Linear IDs into `<project>/.homebase/project.yml` | `homebase roadmap capture <app>` |
| Update `registry/ROADMAP.md` + `roadmap-snapshot.yml` | `homebase roadmap render` |
| Check canon drift | `homebase roadmap audit` |
| Create/rename/archive a Team | Linear MCP (`mcp__plugin_linear_linear__*`) or Linear web UI |
| Create/rename a Project | Linear MCP or Linear UI (bootstrap handles canonical ones) |
| Create a release Milestone inside a Project | Linear MCP or Linear UI |
| Attach an issue to a Project / Milestone | Linear MCP or Linear UI |
| Create / populate an Initiative | Linear MCP or Linear UI |
| Set priority / labels on an issue | Linear MCP or Linear UI |

### Mutation → API operation mapping

| Verb | Linear API call |
|---|---|
| `bootstrap` | sequenced `teamCreate` + `issueLabelCreate` + `projectCreate` per canon; idempotent — skips what already exists |
| `capture` | read-only against Linear + surgical text insert into the project's `.homebase/project.yml` |

### Batching and rate limits

The `linear.rb` client enforces ≥ 1 second between mutations and retries with exponential backoff on HTTP 429 and GraphQL `RATELIMITED` errors. The Linear MCP plugin manages its own rate limiting via Linear's SDK.

---

## Linear API Gatekeeper

TPM is the sole authorized executor of every *ad-hoc* Linear mutation. Enforcement:

1. `scripts/hooks/linear-cli-guard-hook.sh` — PreToolUse hook on `Bash`. Detects any invocation of `scripts/lib/linear-api-helper.sh`, any `curl` to `api.linear.app`, or any `linear-cli` call. If `LINEAR_TPM_AUTHORIZED` is not `1`, returns `{"decision":"block","reason":"…"}` and blocks the call.
2. TPM sets `LINEAR_TPM_AUTHORIZED=1` only for the duration of a batch, unsets on completion.
3. Read-only verbs (`render`, `audit`) are permitted without authorization; they query Linear but do not mutate.

TPM's Linear authority is documented in `agents/technical-project-manager.md § Linear API Gatekeeper`.

### Self-authorization within work-state lifecycle scripts

Two scripts are exempt from the TPM-only rule for the narrow Linear state transitions they're designed to perform: `scripts/work/start.sh` (Backlog → In Progress) and `scripts/work/finish.sh` (In Progress → Done). Both export `LINEAR_TPM_AUTHORIZED=1` internally, scoped to their own subprocess.

**Why this is safe.** The TPM-only rule exists to prevent unaudited Linear mutations from arbitrary agents. start.sh and finish.sh are *not* arbitrary agents — they are homebase canon, governed by the same regime as the gatekeeper itself, and the mutations they perform are tightly bounded:

- The issue key and target state-kind come from the work-state file (`.homebase/work-state.json`), not external arguments. A malicious caller cannot use them to mutate an arbitrary issue.
- finish.sh's gate 12 only runs after gates 0-11 pass. If any of tree-clean, commits-trailered, closing-keyword-present, changelog-current, validate-passes, ui-verified, or landed-to-main fail, the Linear move never occurs.
- The transitions are exactly two — start: `Backlog → state_kinds.in_progress[*]`; finish: `state_kinds.in_progress[*] → state_kinds.done[*]` — both resolved against the team's `workflow.yml`. No path to arbitrary state mutation.
- The export is scoped to the script's process: `export LINEAR_TPM_AUTHORIZED=1` inside the `if [[ -n "$ISSUE_JSON" ]]` block (start.sh) and immediately before `run_gate 12` (finish.sh). It does not leak into the calling Claude session env.

**Why `cancel.sh` and `checkpoint.sh` are NOT self-authorizing.** Both are non-default operator paths. `cancel` reverts state and may unwind work mid-flight; `checkpoint --state` is a discretionary mid-work transition. Both keep TPM gating intact — operator must run them from a TPM-authorised shell, or route the Linear move through the technical-project-manager agent.

**Origin**: HMB-28 (closed 2026-04-29) — surfaced after recurring `LINEAR_TPM_AUTHORIZED=1 not set` failures on the final gate of every `homebase work finish` invocation in non-TPM sessions, requiring manual TPM rescue (Linear move + work-state file cleanup) on each ship.

---

## Credential Handling

**API key**: stored in `~/.config/homebase/env` as a shell-env line (`LINEAR_API_KEY=lin_api_...`). File MUST be `chmod 600` — never world-readable, never committed. The file is a per-machine resource; it holds multiple homebase secrets and is not part of any repo.

**Runtime read**: both `scripts/lib/linear-api-helper.sh` and `scripts/roadmap/linear.rb` resolve the key via this order:

1. `$LINEAR_API_KEY` in the current process environment (if TPM has exported it for a batch).
2. `LINEAR_API_KEY=...` line in `~/.config/homebase/env`.

If neither is present, Linear calls fail loud with the file path and expected line format.

**Rotation**: when you rotate the Linear key, edit `~/.config/homebase/env` in place. No other config changes needed because no file references the key directly.

**Scope**: the API key grants workspace-wide write access. This is the blast radius we mitigate with TPM gatekeeping, the `chmod 600` requirement, and the snapshot/restore durability layer below.

> **Historical note**: Earlier drafts of this SOP stored the key in 1Password (`op://Homebase/Linear/credential`). That approach was replaced during initial adoption with the file-based mechanism above for operational simplicity. 1Password can still be used as the upstream source — a user can `op read ... > ~/.config/homebase/env` — but the homebase tools only know about the file.

---

## Durability Layer

The file system is the backup. Two artifacts are committed to homebase:

- `registry/ROADMAP.md` — human-readable portfolio snapshot (one section per app, current Project + Shipped summary). Regenerated by `homebase roadmap render`.
- `registry/roadmap-snapshot.yml` — machine-readable state dump: every team, Project, Initiative, and the Linear issue IDs linked to each Project.

**Cadence**:

- On every release ship — run by SOP-005 integration.
- Nightly — via a scheduled `/schedule` agent that runs `homebase roadmap render && git commit`.
- On demand — anyone can run `homebase roadmap render`.

**Recovery**: if a team's data is corrupted (workspace-wide wipe, accidental team deletion, API key misuse), run `homebase roadmap restore <app>`. It reads `registry/roadmap-snapshot.yml`, recreates the team/Projects/Initiative links, and re-attaches issues. Nothing can bring back genuinely destroyed data — but the structure rebuilds in minutes.

---

## Release Integration (SOP-005)

The release skill (`skills/release/SKILL.md`) gains a new step between Phase C (distribution) and Phase D (post-release):

> **Phase C.5 — Roadmap Graduation**
>
> Mark the release Milestone as done inside the app's Linear Project. A forthcoming wrapper (`homebase roadmap release ship <app> <version>`) will automate this; in the meantime, TPM can do it via `homebase roadmap milestone update <milestone-id> --done` or directly in Linear. Either way, the parent Project stays `started` — only the Milestone transitions. Re-render the snapshot after the update.

If the transition fails (Linear unreachable, auth error), log the failure, continue Phase D, and schedule a retry within 24 h — the release itself is not blocked.

---

## Issue Creation Integration (SOP-001)

The `/new-issue` skill gains an optional `--linear-project <app>` flag:

- **Without the flag** — behaviour is unchanged. GitHub issue created; can be associated with a Linear Project later.
- **With the flag** — `/new-issue` creates the Linear issue inside the named app's Project (priority label, milestone optional). Linear's GitHub integration creates the mirror GH issue automatically.

Both flows produce paired identifiers (GitHub `#N` and Linear `KEY-N`, e.g. `TBL-42`). Either is valid in commit trailers per SOP-001 §0 — pick the side you actually opened. Linear's GitHub integration mirrors closure both ways.

---

## Bootstrap Procedure

Run once when adopting this SOP. Prerequisites:

- [ ] Linear workspace exists.
- [ ] API key generated in Linear settings and stored as `LINEAR_API_KEY=lin_api_...` in `~/.config/homebase/env` (`chmod 600`).
- [ ] Homebase repo has SOP-013 merged (i.e. this SOP, the CLI verb, the helper scripts, and schemas are live).

Bootstrap is **idempotent**: re-running skips existing Teams, labels, and Projects by name match. Safe to resume mid-run.

### Step 1: Dry-run the plan

```bash
homebase roadmap bootstrap --dry-run
```

Reads the canonical Teams and Projects tables from `scripts/roadmap/linear.rb` and emits the mutation plan without calling Linear.

### Step 2: Execute

```bash
LINEAR_TPM_AUTHORIZED=1 homebase roadmap bootstrap
```

The script:

1. Creates the 3 Teams in canonical-key order (`TBL`, `TFD`, `HMB`), skipping any that already exist.
2. Sets labels (`roadmap`, `p0`–`p3`, `blocked`) on each Team.
3. Creates the canonical Projects (one per app) inside each Team.

### Step 3: Capture Linear IDs into each project.yml

For each registered app:

```bash
LINEAR_TPM_AUTHORIZED=1 homebase roadmap capture <app>
```

Writes the Team ID + Project ID into `<project>/.homebase/project.yml` under `apps[].roadmap`. Surgical text edit — preserves the file's formatting and comments.

### Step 4: Snapshot

```bash
homebase roadmap render
```

Produces `registry/ROADMAP.md` + `registry/roadmap-snapshot.yml`.

### Step 5: Verify

```bash
homebase roadmap audit       # exits 0 on clean state
homebase roadmap portfolio   # lists all 11 Projects across 3 Teams
```

---

## Enforcement

- **`bin/homebase status <project>`** gains a `--roadmap` flag that checks every app in the project has a live Linear team and up-to-date `roadmap_fields` in its `project.yml`.
- **`homebase roadmap audit`** runs in CI via `.github/workflows/roadmap-audit.yml` (reusable workflow called by each project). Fails the build on schema drift (a team missing canonical labels, an Initiative named off-format, a Project without a SemVer title).
- **`scripts/validate-docs.sh`** checks that `registry/ROADMAP.md` is fresh (< 24 h since last `render`), mirroring the freshness check already applied to `registry/PROJECTS.md`.
- **Nightly scheduled agent**: `homebase roadmap render && git commit -m "chore(registry): nightly roadmap snapshot"`. Documented in the homebase root CLAUDE.md.

---

## Recovery

Recovery follows the SOP-012 § Recovery Procedure shape, adapted for Linear.

### Prerequisites

- `registry/roadmap-snapshot.yml` committed at some point before the incident (checked in automatically by nightly render).
- API key still works in `~/.config/homebase/env` (or has been rotated).

### Procedure

1. Identify the corrupted or missing entity — a team, Project, or Initiative.
2. Confirm the expected state in `registry/roadmap-snapshot.yml`.
3. Run `homebase roadmap restore <app>` (for team-scoped recovery) or `homebase roadmap restore --all` (for workspace-wide recovery).
4. Run `homebase roadmap audit` → must exit 0.
5. Run `homebase roadmap render` to update the snapshot with the rebuilt state.
6. Record the incident in `registry/INCIDENTS.md` (if it exists) or open a governance issue describing cause and remediation.

**What restore does NOT recover**: Linear issue content (descriptions, comments, history). Only structural metadata (team, project, issue→project links, initiative→project links) is rebuildable.

---

## Migration from Existing `ROADMAP.md`

Three apps currently have a `ROADMAP.md` in a non-standard shape. Each migrates into its Linear Project's Milestones (one Milestone per release), with the source file retained as historical context:

| File | Post-migration outcome |
|---|---|
| `~/code/studio/apps/capture/ROADMAP.md` | v1.0 shipped items → issues attached to a `v1.0.0` Milestone (marked done) on the Capture Project. v1.1 planned items → a `v1.1.0` Milestone. File retained with a banner: "Canonical roadmap is now Linear." |
| `~/code/field-suite/ShopOS/Documentation/Planning/ROADMAP.md` | Phase 0–3 → `v0.1.0`–`v0.3.0` Milestones (done). Phase 4–5 → `v1.0.0`, `v2.0.0` Milestones (planned). File retained with banner. |
| `~/code/field-suite/Documentation/Planning/ROADMAP.md` | Content split per-app (LogApp, GasCalc, PhotoFix, LinkCompanion). Each app's items land as Milestones inside its Linear Project. File becomes a redirect stub. |

Migration is performed after bootstrap completes. TPM executes the Linear mutations; the relevant PM agent reviews Project scope first.

---

## Subscription & Cost

The Teams-as-monorepo + Projects-as-apps topology is designed to fit inside Linear's free tier for a solo workspace (3 teams, 11 projects, unlimited Milestones). No subscription is required at this scale. Upgrade only becomes necessary if the workspace adds more teams (e.g. spinning off a new monorepo) or approaches the free-tier issue cap.

---

## Related

- `@~/code/homebase/standards/LINEAR_WORKSPACE.md` — canonical workspace topology reference (team keys, naming conventions, state machines). Short, frequently re-read.
- `@~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` — issue-first rule, commit trailers, CHANGELOG discipline.
- `@~/code/homebase/sops/HOMEBASE-SOP-002-GITHUB_API_USAGE.md` — TPM gatekeeper role; SOP-013 extends the same agent to Linear.
- `@~/code/homebase/sops/HOMEBASE-SOP-005-RELEASE_PROCESS.md` — release pipeline; now includes Phase C.5 roadmap graduation.
- `@~/code/homebase/sops/HOMEBASE-SOP-009-NEW_APP_ONBOARDING.md` — new-app onboarding; now includes Linear team creation.
- `@~/code/homebase/sops/HOMEBASE-SOP-012-GITHUB_PROJECT_MANAGEMENT.md` — legacy; retained for any project still operating a GitHub Projects V2 board.
- `~/code/homebase/schemas/linear-workspace.schema.json` — machine-readable spec of a conforming workspace.
- `~/code/homebase/schemas/project.schema.json` — per-app `roadmap:` block schema.
- `~/code/homebase/scripts/lib/linear-api-helper.sh` — single chokepoint for Linear API calls.
- `~/code/homebase/scripts/hooks/linear-cli-guard-hook.sh` — PreToolUse hook enforcing TPM gatekeeping.
- `~/code/homebase/scripts/roadmap/*.sh` — per-verb implementations.
- `~/code/homebase/skills/roadmap/SKILL.md` — runtime skill surface.
