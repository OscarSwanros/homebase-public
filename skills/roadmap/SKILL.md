---
name: roadmap
description: "HOMEBASE-SOP-013 roadmap glue — bootstrap the workspace from canon, capture IDs into project.yml, render the registry snapshot, audit canon drift. Individual Linear mutations (Milestones, Initiatives, issue updates) live in the Linear MCP plugin, not here."
---

# Roadmap — HOMEBASE-SOP-013 Wrapper

Orchestrate roadmap operations against the canonical Linear workspace. Linear is the planning layer; GitHub remains the atomic issue tracker; CHANGELOG remains the shipped-history record.

**All mutation sub-verbs MUST be executed by the technical-project-manager agent.** The `linear-cli-guard-hook.sh` PreToolUse hook blocks them otherwise.

## Mental Model

```
Linear Team     = monorepo         (TBL = Studio, TFD = Field Suite, HMB = Homebase)
Linear Project  = app              (long-lived; e.g. Capture, GasCalc, StudioWeb, Homebase)
Linear Milestone = release         (v1.0.0, v1.1.0, v2.0.0 inside a Project)
Linear Initiative = cross-app theme (optional; e.g. "iOS 19 compatibility")
```

A "release" in Linear is a Milestone, not a Project. Projects never "ship" — apps don't have finish lines; releases do.

## Canonical Process

Follow **HOMEBASE-SOP-013**:

- § Workspace Structure — Teams / Projects / Milestones / Initiatives.
- § CLI Surface — verb catalogue and mutation → API mapping.
- § Bootstrap Procedure — one-shot workspace init.
- § Release Integration — Phase C.5 graduation step in SOP-005.
- § Issue Creation Integration — `/new-issue --linear-project <app>` flag.
- § Durability — `render` and `audit` invariants.

## What each tool owns

| Task | Use |
|---|---|
| Snapshot / render / audit / portfolio view | `homebase roadmap …` (read-only) |
| Bootstrap a new monorepo Team + its Projects | `homebase roadmap bootstrap` (mutation; TPM) |
| Write Linear IDs into `<project>/.homebase/project.yml` | `homebase roadmap capture <app>` (mutation; TPM) |
| Create/rename/archive a Team | Linear MCP plugin or Linear web UI |
| Create a release Milestone; attach issues to it | Linear MCP plugin or Linear web UI |
| Create / populate an Initiative | Linear MCP plugin or Linear web UI |
| Set priority / labels / project on individual issues | Linear MCP plugin or Linear web UI |
| Ship a release (mark Milestone done) | Linear MCP plugin during SOP-005 Phase C.5 |

Pattern: homebase owns **canon-driven glue** (bootstrap from canon, write to filesystem, render snapshots, audit). Individual Linear mutations live in the Linear MCP plugin / web UI because they're interactive and scoped to single entities.

## Procedure

### Read-only — run directly

```bash
homebase roadmap portfolio
homebase roadmap render
homebase roadmap audit
homebase roadmap team list
homebase roadmap project list [--team KEY]
homebase roadmap org
```

### `bootstrap` and `capture` — route through technical-project-manager

These two homebase-owned mutations require `LINEAR_TPM_AUTHORIZED=1`:

1. Frame the desired action.
2. Call `technical-project-manager` with a self-contained prompt describing the action.
3. TPM sets `LINEAR_TPM_AUTHORIZED=1`, runs the command, unsets on completion.
4. After execution, run `homebase roadmap render` (read-only) and commit the refreshed `registry/ROADMAP.md` + `roadmap-snapshot.yml`.

### Individual Linear operations — use the MCP plugin

For anything not in the tables above (create a Milestone, move an issue, build an Initiative, change priority, etc.), drive Linear directly via the Linear MCP plugin's tools in this Claude Code session, or by opening the Linear web UI. The homebase CLI intentionally does not wrap these — doing so would duplicate functionality that the MCP plugin already provides natively with better interactive UX.

### Release graduation (SOP-005 Phase C.5)

When a release ships, mark its Milestone done via the Linear MCP plugin (or Linear UI). The Project stays `started`. Re-render the snapshot afterwards with `homebase roadmap render`.

### New app onboarding (SOP-009 integration)

1. Register the app in `registry/PROJECTS.md` and add it to `CANONICAL_PROJECTS` in `scripts/roadmap/linear.rb` (also update `standards/LINEAR_WORKSPACE.md` § Projects in the same commit).
2. Ask TPM to run `homebase roadmap bootstrap` (idempotent — creates only the new Project).
3. Run `homebase roadmap capture <app>` to write IDs into the project's `.homebase/project.yml`.

## Project-Specific Extensions

- **Canonical topology** lives in `@~/code/homebase/standards/LINEAR_WORKSPACE.md` and must be kept in sync with `scripts/roadmap/linear.rb` `CANONICAL_TEAMS` + `CANONICAL_PROJECTS`. Edit both in the same commit.
- **Per-app Linear IDs** live in each project's `<project>/.homebase/project.yml` under `apps[].roadmap`. Populated by `homebase roadmap capture`; never hand-edited.

## Related

- `@~/code/homebase/sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md` — canonical SOP.
- `@~/code/homebase/standards/LINEAR_WORKSPACE.md` — workspace topology.
- `@~/code/homebase/sops/HOMEBASE-SOP-002-GITHUB_API_USAGE.md` — TPM gatekeeper role (same agent covers Linear API).
- `@~/code/homebase/sops/HOMEBASE-SOP-005-RELEASE_PROCESS.md` — graduation in Phase C.5.
- `~/code/homebase/bin/homebase roadmap help` — verb list.
