# Homebase

The single source of truth for how the operator operates across every coding project. Your staff roster, standard operating procedures, shared scripts, and governance templates live here.

## Mental Model — CEO + Staff

- **Homebase is the company.** HQ + staff + handbook.
- **Agents are staff** (`agents/`). They travel between projects. Their identities and working styles live here; they pick up project-specific context by reading each project's root `CLAUDE.md` at runtime.
- **Projects are engagements** (`~/code/field-suite`, `~/code/studio`, future). Each has its own product, brand, customers, domain — but the operating rhythm is company-wide.
- **SOPs are the handbook** (`sops/`). Written once, read by agents and humans in every project.

## How Homebase Distributes Its Contents

Two modes, chosen per asset type based on how it needs to be invoked at runtime. There is no "copy" mode — homebase owns every shared asset and projects consume them by reference or symlink.

### Mode A — Symlinked (auto-applies everywhere)

**User-level symlinks** (one-time per machine, via `bin/homebase link`):

| Asset | Source | Target |
|---|---|---|
| Agents | `homebase/agents/` | `~/.claude/agents/` |
| Skills | `homebase/skills/` | `~/.claude/skills/` |
| Statusline script | `homebase/scripts/statusline-command.sh` | `~/.claude/statusline-command.sh` |
| Agent progress signaller | `homebase/scripts/agent-signal.sh` | `~/.claude/agent-signal.sh` |
| User-level Claude Code settings | `homebase/.claude/user-settings.json` | `~/.claude/settings.json` |

`~/.claude/settings.json` is a symlink so permissions, plugin toggles, and operator preferences port across Macs (HMB-50). On first run on a machine the pre-existing real file is moved aside to `~/.claude/settings.json.bak-<timestamp>` before the symlink replaces it. Use `homebase settings doctor` to verify the symlink and recover if Claude Code ever atomic-replaces it with a regular file.

**Project-level symlinks** (per project, via `bin/homebase link-project <path>`):

| Asset | Source | Target in project |
|---|---|---|
| Git hook entry | `homebase/.githooks/commit-msg` | `<project>/.githooks/commit-msg` |
| Hook scripts | `homebase/scripts/hooks/*.sh` | `<project>/scripts/hooks/*.sh` (each a symlink) |
| Shared libs | `homebase/scripts/lib/*.sh` | `<project>/scripts/lib/*.sh` (each a symlink) |
| Universal scripts | `homebase/scripts/validate-docs.sh`, `extract-changelog.sh` | `<project>/scripts/validate-docs.sh`, `extract-changelog.sh` |
| Android UI verification helper | `homebase/scripts/android/screencap-verify.sh` | `<project>/scripts/android/screencap-verify.sh` |
| Canonical Claude settings | `homebase/.claude/settings.json` | `<project>/.claude/settings.json` |

Project-specific overlays live in `<project>/.claude/settings.local.json` (checked into git, not gitignored). Claude Code merges them natively.

### Mode B — Referenced via absolute `@`-paths (no copies, no symlinks)

| Asset | Source | Referenced from |
|---|---|---|
| Homebase SOPs | `homebase/sops/HOMEBASE-SOP-00N-*.md` | Each project's root CLAUDE.md: `@~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` |
| Governance docs | `homebase/governance/*.md` | Each project's CLAUDE.md via `@~/code/homebase/governance/...` |
| Standards | `homebase/standards/*.md` | Each project's CLAUDE.md via `@~/code/homebase/standards/...` |

One canonical doc, no drift. `@`-refs are resolved by Claude Code at session time on the developer's machine; CI does not read SOPs.

### CI consumes homebase via reusable workflows

Project `.github/workflows/*.yml` call reusable workflows hosted in homebase:

```yaml
jobs:
  validate-docs:
    uses: acme-co/homebase/.github/workflows/validate-docs.yml@<sha>
```

This keeps enforcement scripts in homebase without vendoring them into every project.

## Three-Level Governance

A single "what goes where" rule keeps things from getting muddled:

| Level | Owner | Examples |
|---|---|---|
| **1. Homebase (universal)** | This repo | Agent identities, core SOPs, governance skeletons, generic scripts, standards |
| **2. Project / monorepo** | Project's root CLAUDE.md | Project name, brand list, app inventory, project-scoped agents, `recurring-tasks.json`, `.homebase/project-fields.yml`, `.homebase/project.yml` |
| **3. App (inside a monorepo)** | App's CLAUDE.md | Domain model, stack details, app-specific agents |

## Projects

Homebase maintains a compact map of every project it's used in and the apps each one contains. Each project declares itself in `<project>/.homebase/project.yml`; `bin/homebase index` aggregates those declarations into the registry below and commits it. Every homebase Claude Code session loads the map automatically via the `@`-ref.

@registry/PROJECTS.md

When the operator names an app — "GasCalc", "StudioWeb", "SHOPOS", "Bookshelf", "Link Companion" — consult the registry's Alias Index first. It resolves name / alias → absolute path without a search. For deeper context, open that path's own `CLAUDE.md`.

Adding or updating a project:

1. `bin/homebase register <path>` (or `link-project` / `migrate` — they call `register` automatically).
2. Fill in `<path>/.homebase/project.yml` (scaffolded from `templates/project.yml.tmpl`).
3. `bin/homebase index` to regenerate the registry.
4. Commit the per-project YAML (in its own repo) and `registry/PROJECTS.md` + `registry/projects.paths` (in homebase).

Use `bin/homebase list` to print the registry to the terminal.

## SOP Index

Homebase owns 14 SOPs. As of Phase 8 of the workflow-contract migration, **every SOP carries a "Status: explanation, not control flow" header**. Control flow lives in `standards/WORKFLOW_CONTRACT.md` + each project's `.homebase/workflow.yml`; the SOPs explain the *why* behind contract clauses. Adoption is declared in each project's `.homebase/workflow.yml`. Project-specific SOPs use a project prefix (e.g. `TFD-SOP-…`) and are reserved for genuine step-by-step implementation procedures unique to that project. Thinking frameworks (philosophy, brand-identity discipline, design-system reference) are **not SOPs** — they live in the project's own `Documentation/`.

| # | File | Scope |
|---|---|---|
| 001 | `sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` | Issue-first rule, commit format, trailer keywords, branching, closing |
| 002 | `sops/HOMEBASE-SOP-002-GITHUB_API_USAGE.md` | TPM as `gh` CLI gatekeeper, rate limits, caching |
| 003 | `sops/HOMEBASE-SOP-003-DOCUMENTATION_GOVERNANCE.md` | File placement, naming, `@`-refs, CLAUDE.md line budget |
| 005 | `sops/HOMEBASE-SOP-005-RELEASE_PROCESS.md` | Multi-platform changelog, version bump, metadata, tagging, distribution |
| 006 | `sops/HOMEBASE-SOP-006-HOTFIX_PROCESS.md` | P0 emergency release path, branch-from-tag, merge-back |
| 007 | `sops/HOMEBASE-SOP-007-UI_VERIFICATION.md` | Render-and-observe gate, verification trailer, Stop-hook |
| 008 | `sops/HOMEBASE-SOP-008-FAILURE_STATE_DATA_PRESERVATION.md` | Save-before-retry rule for pipeline failure states |
| 009 | `sops/HOMEBASE-SOP-009-NEW_APP_ONBOARDING.md` | Brand, customer, docs, design-system checklist for a new app |
| 010 | `sops/HOMEBASE-SOP-010-HIG_COMPLIANCE.md` | Apple HIG consultation for iOS/macOS work (Apple-platform projects only) |
| 011 | `sops/HOMEBASE-SOP-011-CUSTOMER_RESEARCH.md` | `Customers/` directory, research artifacts, 6-category THINKING_PATTERNS (opt-in) |
| 012 | `sops/HOMEBASE-SOP-012-GITHUB_PROJECT_MANAGEMENT.md` | Projects V2 banned mutations, safe operations, recovery procedure (legacy; superseded by SOP-013 for new work) |
| 013 | `sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md` | Linear roadmap substrate, workspace topology, Linear API gatekeeper, release/issue integration |
| 014 | `sops/HOMEBASE-SOP-014-MACHINE_MIGRATION.md` | New-machine setup: Migration Assistant runbook, `homebase bootstrap` verification, fallback bundle path |
| 015 | `sops/HOMEBASE-SOP-015-APPLE_TOOLCHAIN.md` | `xcodebuildmcp` is the canonical Apple toolchain wrapper; raw `xcodebuild` / `xcrun simctl` are gated. Version-pinned + drift-detected via `.homebase/dependencies.yml`. |

## Adopted Workflow (this project)

The four blocks below are generated from `.homebase/workflow.yml` by
`bin/homebase render-claudemd ~/code/homebase`. Edit the YAML, run the
command, commit the diff. Operator prose outside the markers is sacred.

### Adopted SOPs

<!-- BEGIN homebase:adopted-sops -->
- [HOMEBASE-SOP-001 Development Workflow](@~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md)
- [HOMEBASE-SOP-002 GitHub API Usage](@~/code/homebase/sops/HOMEBASE-SOP-002-GITHUB_API_USAGE.md)
- [HOMEBASE-SOP-013 Roadmap Management](@~/code/homebase/sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md)
- [HOMEBASE-SOP-015 Apple Toolchain Usage](@~/code/homebase/sops/HOMEBASE-SOP-015-APPLE_TOOLCHAIN.md)
<!-- END homebase:adopted-sops -->

### Hard Rules

<!-- BEGIN homebase:hard-rules -->
1. **GitHub API gatekeeper** — Only `technical-project-manager` runs `gh` CLI commands. All other agents return structured GitHub requests for TPM to execute. (Enforced by `scripts/hooks/gh-cli-guard-hook.sh`; rationale in HOMEBASE-SOP-002)
2. **Linear API gatekeeper** — Only `technical-project-manager` mutates Linear (issues, projects, milestones). Read-only verbs (`homebase roadmap render|audit|portfolio`) are allowed for any agent. (Enforced by `scripts/hooks/linear-cli-guard-hook.sh`; rationale in HOMEBASE-SOP-013)
2.1. **New Linear issues require Acceptance Criteria** — Every issue created via `mcp__plugin_linear_linear__save_issue` (calls without `id`) must carry a `## Acceptance Criteria` section with at least one `- [ ]` checkbox before the create-gate accepts it. Updates (`id` present) pass through so backfill into existing issues remains possible. The create-gate reuses the same regex pair as the `homebase work start` start-gate (`scripts/lib/ac-regex.sh`), so the two gates can never drift. (Enforced by `scripts/hooks/linear-cli-guard-hook.sh, scripts/lib/ac-regex.sh`; rationale in HOMEBASE-SOP-001)
3. **No commit-bypass flags** — `git commit --no-verify` and `-n` are forbidden. The commit-msg hook is the canonical commit-policy gate; bypassing it is a violation. (Enforced by `scripts/hooks/claude-precommit.sh`; rationale in HOMEBASE-SOP-001)
4. **Issue-first workflow** — Every code change starts with a tracked issue (Linear `KEY-N` or GitHub `#N`). `homebase work start <KEY>` is the only legal start path; commits without an issue trailer are rejected by the commit-msg hook. (Enforced by `scripts/hooks/work-cli-guard-hook.sh, scripts/hooks/commit-sop-check.sh`; rationale in HOMEBASE-SOP-001)
5. **One issue per commit scope** — Each commit references exactly one tracked issue in its trailer. Cross-issue work splits across commits; mixed-issue commits are rejected at finish-time. (Enforced by `scripts/work/finish.sh (gate 4)`; rationale in HOMEBASE-SOP-001)
6. **Canonical trailer keywords** — Issue-reference trailers use only `Refs`, `Closes`, `Fixes`, `Resolves` (and case variants). Anti-patterns like `Part of`, `Related to`, `See`, `References` read correctly to humans but do not trigger auto-close — they are rejected. (Enforced by `scripts/lib/issue-trailer.sh, scripts/hooks/commit-sop-check.sh`; rationale in HOMEBASE-SOP-001)
7. **Closing keyword on the final commit** — The last commit on a work branch carries `Closes` / `Fixes` / `Resolves` (not `Refs`). `homebase work finish` validates this before pushing. (Enforced by `scripts/work/finish.sh (gate 5), scripts/hooks/pre-push.sh`; rationale in HOMEBASE-SOP-001)
8. **No uncommitted work at session end** — A Claude Code session may not end with uncommitted changes or unpushed commits. `task-completed.sh` blocks completion until the working tree is clean and pushed. (Enforced by `scripts/hooks/task-completed.sh, scripts/hooks/teammate-idle.sh`; rationale in HOMEBASE-SOP-001)
17. **Apple toolchain wrapper** — Raw `xcodebuild`, `xcrun simctl`, and bare `simctl` invocations are prohibited. All Apple-platform build/test/run/sim/UI-automation goes through the `xcodebuildmcp` CLI (vendored skill at `skills/xcodebuildmcp-cli/`, pinned in `.homebase/dependencies.yml`). Escape hatch: `XCODEBUILDMCP_AUTHORIZED=1` for one-off cases xcodebuildmcp doesn't cover, captured at Claude fork time (set via .claude/settings.local.json `env` block + relaunch; inline env-var prefix and mid-session `export` do NOT work). (Enforced by `scripts/hooks/xcodebuild-cli-guard-hook.sh`; rationale in HOMEBASE-SOP-015)
<!-- END homebase:hard-rules -->

### Required Checks

<!-- BEGIN homebase:required-checks -->
| App | Check | Command | When | Blocking |
|---|---|---|---|---|
| homebase | validate_docs | `scripts/validate-docs.sh` | on_finish | true |
| homebase | workflow_schema_check | `python3 -c "
import json, sys
sys.path.insert(0, '$HOME/Library/Python/3.9/lib/python/site-packages')
import jsonschema, yaml
jsonschema.Draft202012Validator(json.load(open('schemas/workflow.schema.json'))).validate(yaml.safe_load(open('.homebase/workflow.yml')))
jsonschema.Draft202012Validator(json.load(open('schemas/workflow.schema.json'))).validate(yaml.safe_load(open('templates/workflow.yml.tmpl')))
print('OK')
"
` | on_finish | true |
| homebase | work_cli_tests | `bash scripts/work/_test_work.sh` | on_finish | true |
| homebase | settings_doctor_tests | `bash scripts/settings/_test_settings.sh` | on_finish | true |
| homebase | ui_pattern_tests | `bash scripts/hooks/_test_ui_pattern.sh` | on_finish | true |
| homebase | xcodebuild_guard_tests | `bash scripts/hooks/_test_xcodebuild_guard.sh` | on_finish | true |
| homebase | dependencies_schema_check | `python3 -c "
import json, sys
sys.path.insert(0, '$HOME/Library/Python/3.9/lib/python/site-packages')
import jsonschema, yaml
jsonschema.Draft202012Validator(json.load(open('schemas/dependencies.schema.json'))).validate(yaml.safe_load(open('.homebase/dependencies.yml')))
print('OK')
"
` | on_finish | true |
| homebase | bootstrap_helpers_tests | `bash scripts/_test_bootstrap_helpers.sh` | on_finish | true |
| homebase | plan_approval_reminder_tests | `bash scripts/hooks/_test_plan_approval_reminder.sh` | on_finish | true |
| homebase | push_recovery_tests | `bash scripts/deploy/_test_push_recovery.sh` | on_finish | true |
<!-- END homebase:required-checks -->

### Required Agents

<!-- BEGIN homebase:required-agents -->
**By change kind**

| Change kind | Required agents |
|---|---|
| `architecture` | `technical-project-manager` |
| `governance` | `technical-project-manager` |
<!-- END homebase:required-agents -->

## Governance Index

- `governance/AGENT_OPERATING_CONTRACT.md` — Ten-rule contract every agent inherits via the prompt footer. Auto-loaded with `WORKFLOW_QUICKREF.md`. `@~/code/homebase/governance/AGENT_OPERATING_CONTRACT.md`
- `governance/WORKFLOW_QUICKREF.md` — Practical agent recipe for the common workflow scenarios (start / checkpoint / finish, off-contract, release, hotfix, recovery), gate-failure fixes, and authorisation matrix. Auto-loaded via `AGENT_OPERATING_CONTRACT.md`. `@~/code/homebase/governance/WORKFLOW_QUICKREF.md`
- `governance/AUTONOMY_CHARTER.md` — When Claude acts vs. confirms. Green / yellow / red lists; codifies the "Required follow-ups" deferral antipattern. Narrows Claude Code's generic "confirm anything destructive / shared / third-party" rule for this single-operator workspace. `@~/code/homebase/governance/AUTONOMY_CHARTER.md`
- `governance/HARD_RULES.yml` — Slug → display data registry rendered into each project's CLAUDE.md by `bin/homebase render-claudemd`. Source of truth for the hard-rule wording. `@~/code/homebase/governance/HARD_RULES.yml`
- `governance/AGENT_GUIDE.md` — Staff directory, decision authority, collaboration matrix
- `governance/ISSUE_CONVENTIONS_SKELETON.md` — Universal form of issue title/label taxonomy; projects name concrete scopes
- `governance/RESEARCH_STANDARDS.md` — Artifact standards for `Customers/` (paired with HOMEBASE-SOP-011)
- `governance/RISK_MANAGEMENT.md` — Inverted Swiss cheese: why homebase is default-deny across six layers, what each slice catches, and how the doorways stay synchronised. Reference material — read when you want to understand *why* the contract is structured the way it is. Includes a track-of-record table mapping each slice to the HMB issue that materialised it. `@~/code/homebase/governance/RISK_MANAGEMENT.md`

## Standards Index

Cross-project technical facts. One canonical doc per topic, referenced by each project's CLAUDE.md via `@`-ref.

- `standards/SENTRY.md` — canonical Sentry organization is `studio` (`https://acme-co.sentry.io/`). All Sentry issue short-IDs, web URLs, CLI invocations, and API calls route to this org. `@~/code/homebase/standards/SENTRY.md`
- `standards/LOGGING.md` — four-signal model (errors / spans / metrics / logs), purpose-built telemetry not a firehose, and per-platform rules (Rails, Swift, Go, Kotlin, web). Read by the architect agents. `@~/code/homebase/standards/LOGGING.md`
- `standards/LINEAR_WORKSPACE.md` — canonical Linear workspace topology: 3 Teams (monorepos), Projects = apps (long-lived), Milestones = releases, optional cross-app Initiatives, canonical label set, and audit invariants. Paired with HOMEBASE-SOP-013. `@~/code/homebase/standards/LINEAR_WORKSPACE.md`
- `standards/RAILS_PLAYBOOK.md` — canonical Rails 8 + SQLite + Kamal stack reference: deployment topology, the 12-phase deploy pipeline, secrets layout, version-file convention, and rollback procedure. Read by the `rails-architect` agent. `@~/code/homebase/standards/RAILS_PLAYBOOK.md`

## Dependencies Index

Pinned third-party CLIs that homebase governs. `bin/homebase bootstrap` installs and verifies each one against the recorded version; drift (in installed version or vendored content) FAILs the bootstrap, forcing a sync commit before any session proceeds.

- `.homebase/dependencies.yml` — pin manifest. Per-dependency: version, install command (brew tap + formula), vendored content paths, enforced-by references. `@~/code/homebase/.homebase/dependencies.yml`
- `schemas/dependencies.schema.json` — JSON-Schema 2020-12 validator for the manifest. Validated by the `dependencies_schema_check` required-check.
- `bin/homebase deps {verify|sync|bump}` — operator-facing surface. `verify` runs the drift checks without installing (CI + session-start use); `sync <name>` copies upstream-for-pinned-version into the vendored copy; `bump <name> <version>` updates the pin.

Current dependencies:

| Name | Pinned | Rationale |
|---|---|---|
| `xcodebuildmcp` | see manifest | Canonical Apple toolchain wrapper. Paired with HOMEBASE-SOP-015 and `scripts/hooks/xcodebuild-cli-guard-hook.sh`. |

## Staff Roster (Agents)

Every agent in `agents/` is **project-agnostic**. Their prompts describe identity, expertise, and working style. They read project-specific context (domain, brand, app inventory) from each project's root CLAUDE.md at runtime — never hardcoded.

Core staff (on call in every project):
- `technical-project-manager` — doc governance, cross-project coordination, `gh` CLI gatekeeper (SOP-002), Linear API gatekeeper (SOP-013)
- `swift-architect`, `rails-architect`, `go-architect`, `kotlin-systems-architect`, `web-frontend-architect`
- `qa-engineer`, `ui-ux-designer`, `copywriter`, `brand-manager`

Specialists (narrower assignments but still staff):
- `dive-science-advisor`, `diving-product-manager` (dive-related projects)
- `example-product-pm` (per-brand product-manager exemplar — clone one per brand)
- `example-reviewer` (per-lens editorial-reviewer exemplar — e.g. finance / tech / engineering / people)

## Using Homebase in a New Project

1. `bin/homebase link` — one-time per machine (symlinks `agents/`, `skills/`, `statusline-command.sh`, and `agent-signal.sh` into `~/.claude/`).
2. `bin/homebase link-project <project-path>` — creates project-level symlinks for `.githooks/commit-msg`, `scripts/hooks/*`, `scripts/lib/*`, universal `scripts/*`, and `.claude/settings.json`. Also registers the project and scaffolds `.homebase/project.yml`. Idempotent.
3. `bin/homebase migrate <project-path>` — one-shot: un-gitignores `.claude/settings.local.json`, replaces vendored copies with symlinks, updates project CLAUDE.md `@`-refs to the current HOMEBASE-SOP names. Use once per project when promoting an older vendored setup.
4. `bin/homebase status <project-path>` — verifies every expected symlink exists and points to homebase.
5. Fill in `<project>/.homebase/project.yml` (scaffolded by `link-project`) so the project shows up in the registry, then run `bin/homebase index` and commit `registry/PROJECTS.md` + `registry/projects.paths`. Projects that shouldn't be symlink-linked can use `bin/homebase register <path>` instead of `link-project`.

## Using Homebase on a New Machine

First-run setup after macOS Migration Assistant (or a fresh clone) is a single command:

```sh
homebase bootstrap
```

`bootstrap` is idempotent. It runs `link`, walks every path in `registry/projects.paths` to apply `link-project` + `status`, validates `~/.config/homebase/env` (Linear API key, mode 600), confirms `gh` auth and SSH connectivity to GitHub, and prints a per-step `[OK]` / `[WARN]` / `[FAIL]` summary. Exits non-zero if any check fails so it can be wired into other tooling.

Drive the full Phase 0 → Phase 3 procedure (pre-migration prep on the OLD Mac, Migration Assistant transfer, bootstrap, MCP verification) via the `/migrate-machine` skill or read `@~/code/homebase/sops/HOMEBASE-SOP-014-MACHINE_MIGRATION.md` directly.

## Canonical Files — Never Edit Without Impact Analysis

Edits to any of the following propagate to every project that uses homebase (either via symlink or `@`-ref):

- Any file under `sops/`
- Any file under `governance/`
- Any file under `standards/`
- Any file under `agents/`
- Any file under `skills/`
- Any file under `scripts/hooks/` (commit-sop-check, commit-changelog-check, claude-precommit, gh-cli-guard, linear-cli-guard, xcodebuild-cli-guard, ui-verification-check, session-start, task-created, task-completed, teammate-idle)
- Any file under `scripts/lib/`
- Any file under `scripts/roadmap/` (per-verb SOP-013 implementations)
- `scripts/validate-docs.sh`
- `scripts/extract-changelog.sh`
- `scripts/agent-signal.sh`
- `scripts/statusline-command.sh`
- `scripts/lib/render-registry.rb`
- `.githooks/commit-msg`
- `.claude/settings.json`
- `.claude/user-settings.json` (HMB-50: canonical user-level Claude Code settings; symlinked into `~/.claude/settings.json` on every Mac via `bin/homebase link`)
- `.github/workflows/*.yml` (reusable workflows called by project CI)
- `templates/CLAUDE.md.tmpl`
- `templates/project.yml.tmpl`
- `templates/linear-team-bootstrap.md`
- `templates/linear-bootstrap-plan.md`
- `schemas/project.schema.json`
- `schemas/linear-workspace.schema.json`
- `schemas/dependencies.schema.json` (HMB-60: validates `.homebase/dependencies.yml`)
- `.homebase/dependencies.yml` (HMB-60: pinned third-party CLI versions; bootstrap fails on drift)
- `registry/PROJECTS.md` (generated; never hand-edit)
- `registry/projects.paths`
- `registry/ROADMAP.md` (generated; never hand-edit)
- `registry/roadmap-snapshot.yml` (generated; never hand-edit)

Run `bin/homebase status` on each active project after any change to confirm every symlink still resolves.
