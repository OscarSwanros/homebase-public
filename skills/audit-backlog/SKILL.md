---
name: audit-backlog
description: "Backlog review and cleanup for an app's open issues. Detects staleness, missing labels, already-addressed-in-git commits, and potential duplicates. Consults the relevant product manager before recommending closures."
---

# Audit Backlog — Issue Staleness and Cleanup Review

Fetch all open issues for a given app, analyse them for staleness and hygiene problems, consult the relevant product manager for product relevance, and produce a structured report with actionable recommendations.

**All `gh` CLI commands MUST go through the technical-project-manager agent (HOMEBASE-SOP-002).**

## Arguments

`/audit-backlog {app} {platform}`.

- **app** (required): the app slug used as the GitHub label for issues.
- **platform** (optional): `ios`, `macos`, `android` — only meaningful for multi-platform apps.

If app is missing, ask the user. If platform is provided for a single-platform app, ignore it with a note.

## Project-Specific Configuration

Projects with monorepo concerns (cross-platform sibling tracking, shared-framework dependency cascades) typically need an extension to this skill that knows the project's app list, platforms, dependencies, and board IDs. Such projects ship:

- `.homebase/audit-backlog.conf` — optional bash config defining apps, platforms, dependencies.
- A project-local skill (or extension script) that wraps this one with the project-specific checks.

When no such configuration is present, this skill performs the universal audit only (below).

## Procedure (Universal)

### Step 1: Fetch Open Issues

**Linear path (preferred when the app uses SOP-013).** Resolve the app's Linear Project from `<project>/.homebase/project.yml` `apps[].roadmap.linear_project_id` (or use the human-readable Project name). Then via the Linear MCP, fan out across the open state types:

- `mcp__plugin_linear_linear__list_issues({project: "<App>", state: "backlog", limit: 100})`
- `mcp__plugin_linear_linear__list_issues({project: "<App>", state: "unstarted", limit: 100})`
- `mcp__plugin_linear_linear__list_issues({project: "<App>", state: "started", limit: 100})`

When the result exceeds the response-size cap, the MCP saves the payload to a temp file and returns the path; slice it with `python3 -c "print(open('<path>').read()[A:B])"` in ~80,000-char spans and parse client-side. Linear MCP returns issues with `id` set to the human key (e.g. `"TFD-1234"`) and `parentId` likewise — see `@~/code/homebase/standards/LINEAR_WORKSPACE.md § MCP response field semantics` for the field-shape contract.

If a milestone is named (e.g. `/audit-backlog ShopOS v0.2.0`), filter the result client-side to issues whose `projectMilestone.name` matches; `list_issues` does not accept a milestone filter directly. Also pull `state: "completed"` once and filter by milestone to learn what already shipped — milestone progress reported by Linear can lag, and "shipped on this milestone" is needed for the epic child-walk in Step 2e.

**GitHub path (fallback, for projects not yet on SOP-013).** Present this command for TPM to execute:

```bash
gh issue list --state open --label "{app-label}" --limit 200 --json number,title,labels,createdAt,updatedAt,body
```

If a platform is specified:

```bash
gh issue list --state open --label "{app-label},{platform}" --limit 200 --json number,title,labels,createdAt,updatedAt,body
```

If TPM returns zero issues (or Linear returns none on the preferred path), report "No open issues found" and stop. If the `--limit 200` cap is reached on the GitHub path, note it in the report and recommend running with a tighter filter.

### Step 2: Check Staleness Signals

For each issue:

**2a. Age check.** Calculate days since `updatedAt`. Flag issues with **90+ days** of inactivity.

**2b. Git-log cross-reference.** For each flagged issue, search the local git history:

```bash
git log --all --oneline --grep="#{issue_number}"
```

This is a local command — safe to run directly (no API hit). Look for:

- `Closes #N` or `Fixes #N` — the issue was likely addressed but not closed on GitHub.
- `Refs #N` or `(part of #N)` — partial work was done.

**2c. Duplicate detection.** Group issues with similar titles (after stripping scope/platform prefix) or overlapping descriptions. Flag potential duplicates for **human review** — do NOT auto-determine.

**2d. Missing-labels check.** For each issue, verify the required label categories per the project's `ISSUE_CONVENTIONS.md`:

- App / scope label (exactly one).
- Type label (`bug`, `enhancement`, `documentation`, `tech-debt`, `refactor`).
- Priority label (`P0`–`P3`) unless the issue is `backlog`, `parked`, or `spike`.
- Platform label for multi-platform apps.

Flag any missing category.

**2e. Epic child-walk (Linear path only).** For every issue in the audit set whose `labels` contain `epic`, enumerate its children:

- `mcp__plugin_linear_linear__list_issues({parentId: "<EPIC-KEY>"})`

For each child, classify by milestone-membership relative to the epic's milestone (or to the audit's named milestone, if one was passed):

| Child state | Child's `projectMilestone` | Audit verdict |
|---|---|---|
| `Done` | any value, including null | OK — already shipped |
| Open | matches epic's milestone | OK |
| Open | matches a *different* real milestone | OK — explicit defer |
| Open | `null` | **DEFECT — orphaned epic child** |

Orphaned epic children silently fall out of their epic's milestone unless surfaced. List them in the report under "Orphaned epic children" with the suggested cleanup (attach to milestone, or move parent's milestone assignment to match, or move the child to a later real milestone with explicit intent).

**Also check epic completeness.** If every child of an epic is `Done` while the epic itself is still in Backlog/Open, surface the epic for human review under "Epics with all children shipped" — the epic may want closing, re-scoping, or repurposing as a planning anchor. Do NOT auto-close.

This sub-step closes a procedural gap surfaced during the 2026-04-29 SHOPOS v0.2.0 audit, where TFD-846 and TFD-848 — both children of the in-flight TFD-841 Payment Visibility epic — had `null` `projectMilestone` and would have silently slipped past v0.2.0.

### Step 3: Consult the Product Manager

Engage the relevant product-manager agent (the project's CLAUDE.md names them per brand / product). Provide a batch summary grouped by type (bugs, enhancements, tech-debt).

For each group, ask for:

- **Keep** — still aligns with product direction.
- **Close** — no longer relevant; superseded; product direction shifted.
- **Reclassify** — wrong type / priority; should be parked; should change scope.

### Step 4: Produce the Audit Report

See the Output Format below.

### Step 5: Present Commands for Approval

For issues recommended for closure:

```bash
gh issue close {N} --comment "Closed during backlog audit ({YYYY-MM-DD}): {reason}"
```

For missing-label fixes:

```bash
gh issue edit {N} --add-label "{missing-label}"
```

Group commands by action (close, relabel) so the user can approve in batches. Route every command through TPM.

## Output Format

```
## Backlog Audit Report — {App} {Milestone or Platform} — {YYYY-MM-DD}

### Summary
- **Total open issues**: {N}
- **Active (P0–P3)**: {N}
- **Backlog / Parked**: {N}
- **Incomplete labels**: {N}
- **Stale (90+ days)**: {N}
- **Potential duplicates**: {N} pairs
- **Already addressed in git**: {N}
- **Orphaned epic children**: {N}
- **Epics with all children shipped**: {N}

### Recommendations

#### Close ({N})
| ID | Title | Reason | Age |
|---|---|---|---|
| {KEY-N or #N} | {title} | {reason} | {N} days |

#### Reclassify ({N})
| ID | Title | Current | Recommended | Reason |

#### Fix Labels ({N})
| ID | Title | Missing |

#### Orphaned epic children ({N})
| ID | Title | Parent epic | Suggested milestone | Reason |

#### Epics with all children shipped ({N})
| ID | Title | Children | Suggested action |

#### Keep ({N})
| ID | Title | Notes |

### Commands for Approval

#### Linear path (after user approval, present to TPM with LINEAR_TPM_AUTHORIZED=1)
- Attach orphan to milestone: route via Linear MCP `save_issue` with `projectMilestone` set, or update in Linear web UI.
- Re-scope or close epic: TPM only; Linear MCP `save_issue`.

#### GitHub path (after user approval, present to TPM)
gh issue close {N} --comment "Closed during backlog audit ({YYYY-MM-DD}): {reason}"
gh issue edit {N} --add-label "{label}"
…
```

## Critical Rules

- **NEVER run `gh` directly** — all GitHub operations go through TPM (HOMEBASE-SOP-002).
- **NEVER mutate Linear directly** — all Linear writes go through TPM (HOMEBASE-SOP-013). Read-only Linear MCP verbs (`list_issues`, `get_issue`, `list_milestones`) are permitted for any agent.
- **NEVER auto-close** — present closure / milestone-attach / re-scope commands for user approval, then route through TPM.
- **Product relevance decisions go through the relevant product-manager** — do not make product judgment calls independently.
- **One app per invocation** — do not batch multiple apps.
- **Update the recurring-task manifest after completion**: find the matching task in `.claude/recurring-tasks.json` (commonly `audit-backlog-{app}-{platform}` or `audit-backlog-{app}`) and set `last_run` to today's date.

## Related

- `@~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` — issue lifecycle and closing keywords.
- `@~/code/homebase/sops/HOMEBASE-SOP-002-GITHUB_API_USAGE.md` — TPM as `gh` CLI gatekeeper.
- `@~/code/homebase/sops/HOMEBASE-SOP-012-GITHUB_PROJECT_MANAGEMENT.md` — safe Projects V2 mutations (for projects using Projects V2).
- `@~/code/homebase/sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md` — TPM as Linear API gatekeeper, roadmap topology, milestone semantics.
- `@~/code/homebase/standards/LINEAR_WORKSPACE.md` — Linear workspace topology and MCP response field semantics (the `id`-as-human-key convention used by Step 1 and Step 2e).
- The project's `Documentation/ISSUE_CONVENTIONS.md` — concrete label taxonomy.
