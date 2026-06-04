# HOMEBASE-SOP-003: Documentation Governance

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Canonical procedure for creating, naming, placing, cross-referencing, and maintaining documentation across every project that adopts homebase.

## Purpose

Keep documentation consistently named, correctly placed, properly cross-referenced, and current. Documentation is the connective tissue that enables agents and engineers to collaborate across multiple apps, brands, and projects. Inconsistent docs waste agent context, produce contradictory guidance, and make institutional knowledge undiscoverable.

## Scope

**Applies to**: All agents, all documentation files in every homebase-adopting project.

**Enforced by**: The technical-project-manager agent during audits, plus `scripts/validate-docs.sh` (symlinked from homebase into each project).

---

## 1. File Naming

| File type | Convention | Examples |
|---|---|---|
| Documentation | `UPPER_SNAKE_CASE.md` | `SWIFT_STYLEGUIDE.md`, `DESIGN_RULES.md`, `BRAND_GUIDE.md` |
| Homebase SOPs | `HOMEBASE-SOP-NNN-UPPER_SNAKE_CASE.md` | `HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` |
| Project SOPs | `{PREFIX}-SOP-NNN-UPPER_SNAKE_CASE.md` | `TFD-SOP-001-SHARED_FRAMEWORK_CHANGES.md` (reserve for genuine step-by-step procedures; thinking frameworks go in `Documentation/` instead) |
| Index / orientation | `README.md` or `CLAUDE.md` | `Documentation/SOPs/README.md` |
| Agent configs | `lowercase-with-hyphens.md` | `swift-architect.md`, `technical-project-manager.md` |
| Scripts | `lowercase-with-hyphens.sh` | `validate-docs.sh`, `commit-sop-check.sh` |

## 2. File Placement

### Suite-level vs project-level

- **Universal docs** (apply to every project) live in homebase:
  - `~/code/homebase/sops/` — SOPs
  - `~/code/homebase/governance/` — agent guide, issue conventions skeleton, doc standards
  - `~/code/homebase/standards/` — changelog format, testing conventions, CLAUDE.md skeleton, release tag convention
- **Project-level docs** live in the project:
  - `<project>/CLAUDE.md` — root orientation (stays under 250 lines)
  - `<project>/Documentation/` — project-specific architecture, design, planning, customer research
  - `<project>/ISSUE_CONVENTIONS.md` — concrete scope prefixes, label taxonomy for that project
- **App-level docs** live inside each app (for monorepos):
  - `<project>/<app>/CLAUDE.md`
  - `<project>/<app>/Documentation/`

### Prohibited placements

- No `.md` files at a project's repository root except `CLAUDE.md` and `README.md`.
- No project-specific code examples in universal docs (no Swift in cross-platform docs, no Rails in cross-platform docs).
- No duplication of homebase SOPs inside a project. Reference via `@~/code/homebase/sops/...`.

## 3. Platform Scope Rules

1. Files in non-platform-qualified paths MUST NOT contain platform-specific code examples.
2. Platform-specific content MUST be in platform-qualified paths (e.g. `Architecture/iOS/`, `Architecture/Android/`).
3. If a doc contains `.swift` code, it MUST be in an iOS-qualified location. If `.kt`, Android-qualified. If `.rb`, Rails-qualified.
4. When a platform-specific doc exists for one platform, a corresponding doc SHOULD exist for the other when the topic applies.

## 4. Cross-References

- **`@` prefix** = auto-loaded into every Claude Code conversation. Reserve for files that are **small (<10K chars) and universally relevant** to the project.
- **Bare path** = referenced but loaded on-demand. Use for large or situational files.
- **Absolute path** (`@~/code/homebase/sops/...` or `~/code/homebase/governance/...`) = references a homebase canonical document. The runtime resolves this on the developer's machine; CI does not read these (it runs scripts, not SOPs).
- Every path reference (with or without `@`) MUST point to an existing file.
- Verify references before committing. `scripts/validate-docs.sh` checks them.

## 5. Review Checklist

Before committing any documentation change, verify:

- [ ] File is in the correct location per § 2
- [ ] Filename follows the convention in § 1
- [ ] All cross-references resolve to existing files
- [ ] Content is not duplicated from another canonical document
- [ ] Platform-specific content is in a platform-qualified path
- [ ] No project-specific code examples in universal docs
- [ ] If the doc is suite-wide, it is referenced from the appropriate index
- [ ] If CLAUDE.md references change, the validator still passes

## 6. CLAUDE.md Constraints

The project's root `CLAUDE.md` MUST:

- Stay under **250 lines**
- Carry the project's own identity (name, brand list, app inventory, customer context) — **not** content that belongs in homebase
- Declare an explicit **Adopted SOPs** table (§ 7)
- Reference homebase SOPs and governance via `@~/code/homebase/...` paths
- Have every `@`-reference pointing to an existing file
- Not inline content that belongs in separate documents
- Not override or contradict homebase SOPs

Sub-project `CLAUDE.md` files (e.g. `<monorepo>/<app>/CLAUDE.md`) MUST only add app-specific context and defer to the root and homebase for shared conventions.

## 7. The "Adopted SOPs" Declaration

Each project's root CLAUDE.md carries an explicit "Adopted SOPs" table that names every SOP the project follows — including optional ones. Example:

```markdown
## Adopted SOPs

### Universal (from homebase)

- HOMEBASE-SOP-001 Development Workflow
- HOMEBASE-SOP-002 GitHub API Usage
- HOMEBASE-SOP-003 Documentation Governance
- HOMEBASE-SOP-005 Release Process
- HOMEBASE-SOP-006 Hotfix Process
- HOMEBASE-SOP-007 UI Verification — warn mode
- HOMEBASE-SOP-008 Failure State Data Preservation
- HOMEBASE-SOP-009 New App Onboarding
- HOMEBASE-SOP-010 HIG Compliance — Apple platforms only
- HOMEBASE-SOP-011 Customer Research — opt-in per persona
- HOMEBASE-SOP-012 GitHub Project Management — opt-in (Projects V2 users only)

### Project-specific

- {PREFIX}-SOP-001 {Name}
- {PREFIX}-SOP-002 {Name}
```

This replaces implicit adoption. Answering "is this rule in effect here?" should require reading only the project's CLAUDE.md, never cross-referencing homebase defaults plus per-project opt-outs.

## 8. Update Propagation

When updating a canonical document (homebase SOPs, governance, standards), the technical-project-manager agent:

1. Identifies all downstream references (project CLAUDE.md files, agents that depend on the doc).
2. Verifies downstream references are still accurate after the update.
3. Flags any downstream documents that need their own updates.
4. Appends a short entry to `~/code/homebase/CHANGELOG.md` describing what changed and the migration, if any.

## 9. Update Documentation After Code Changes

Documentation MUST be updated in the same commit or session as the code change in these situations:

| Trigger | What to update |
|---|---|
| New feature implemented | Feature documentation or CHANGELOG entry |
| Architecture decision made | ADR in the project's Planning/Decisions doc |
| New app or framework added | Project CLAUDE.md folder structure |
| Shared framework API changed | Framework CLAUDE.md and README.md |
| Release shipped | CHANGELOG, store metadata, site content (per HOMEBASE-SOP-005) |
| Agent added/removed/changed | Homebase `agents/` + `governance/AGENT_GUIDE.md` |
| SOP created or modified | `~/code/homebase/sops/README.md` + homebase CHANGELOG |

## 10. Validation

After any documentation change, run the vendored validator:

```bash
scripts/validate-docs.sh
```

The script MUST report **0 errors** before committing. Warnings should be reviewed but are not blocking.

---

## Appendix: Required Files Per Component

| Component | Required files |
|---|---|
| Project root | `CLAUDE.md` + `README.md` |
| App inside a monorepo | `CLAUDE.md` |
| Shared framework / module | `CLAUDE.md` + `README.md` |
| KMP module | `CLAUDE.md` + `README.md` |

Each CLAUDE.md must declare its scope (universal? project-wide? app-scoped?), its adopted SOPs (if at project root), and its agent roster (if at project root).
