# HOMEBASE-SOP-009: New App Onboarding

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Canonical checklist for adding a new app to any homebase-adopting project (single-app repos or monorepos).

## Purpose

Make new-app creation a deterministic, reviewable process. Without this SOP, new apps ship with inconsistent documentation, missing customer context, undeclared brand identity, and incomplete agent coverage — then everyone pays the tax forever.

## Scope

All agents involved in creating a new product inside a project. The SOP assumes the project has already defined (in its root CLAUDE.md) its brand registry, its customer directory, and its agent roster. If the project doesn't have those yet, bootstrap them before invoking this SOP.

---

## Checklist

### 0. Brand Cluster Identification

- [ ] Determine which brand or product cluster the new app belongs to. For multi-brand projects, consult the project's root CLAUDE.md § Brand Architecture (or equivalent) and choose the applicable cluster.
- [ ] Confirm the brand directory exists (commonly `brands/{brand}/` or equivalent) and contains the project's required brand-identity files (e.g. `BRAND_IDENTITY.md`, `PHILOSOPHY.md`, `CUSTOMER_DEFINITION.md`).
- [ ] Verify the product concept aligns with that brand's philosophy. Where a project maintains a philosophy-check framework (e.g. `Documentation/PHILOSOPHY_CHECK.md` in the project's own docs), apply it now.

### 1. Customer Identification

- [ ] Identify the persona this app is built for. If the project adopts HOMEBASE-SOP-011 Customer Research, this must be a real persona or a documented archetype — not a placeholder.
- [ ] New persona: create `Customers/{name}/` with `PROFILE.md`, `THINKING_PATTERNS.md`, `apps.md`, and `research/` per HOMEBASE-SOP-011.
- [ ] Existing persona: update their `apps.md` with the new app.
- [ ] Update `Customers/README.md` persona-to-app mapping table if the project maintains one.

### 2. Directory Setup

- [ ] Create the app directory at the conventional location for the project (e.g. `apps/{app}/`, or repo root for single-app structures).
- [ ] Create a `CLAUDE.md` inside the app directory with architecture, stack, domain, and development notes. Include a `## Customer` section linking to `Customers/{name}/` when HOMEBASE-SOP-011 is adopted.
- [ ] Create a `Documentation/` subdirectory if the app needs project-specific docs beyond CLAUDE.md.

### 3. Brand Identity

- [ ] Choose a signature colour from the brand's palette (or propose a new one with brand-manager sign-off).
- [ ] Verify the signature colour is not already owned by another app in the project.
- [ ] Verify the signature colour meets WCAG AA contrast on the project's canonical background colours.
- [ ] Create `Documentation/BRAND_ASSETS.md` (or the project's equivalent) with product-specific brand extensions:
  - Signature colour (hex, RGB, CSS custom property)
  - Semantic token overrides (actionPrimary, status colours, etc.)
  - Product tagline
  - Component class mappings (Tailwind for web; SwiftUI theme for iOS; etc.)
- [ ] Define the product wordmark treatment per the brand's typography rules.

### 4. Design System

- [ ] Implement parent-level design tokens from the project's design-rules doc.
- [ ] Map app-level tokens (actionPrimary, etc.) to the signature colour.
- [ ] Use semantic token names — never hardcoded hex values in views.
- [ ] Apply the project's typography system (body, titles, accents).

### 5. Root Documentation Updates

- [ ] Add an entry to the project root `CLAUDE.md` Projects (or Apps) table.
- [ ] Add an entry to the project root `CLAUDE.md` Customer Context table if HOMEBASE-SOP-011 is adopted.
- [ ] Add an entry to the project's `AGENT_GUIDE.md` if new project-scoped agents are needed.
- [ ] Add a downstream reference to the project's `BRAND_GUIDE.md` governance section if relevant.

### 6. Agent Configuration

- [ ] Verify every relevant homebase agent's scope still reads correctly once the new app is included (each agent reads the project's root CLAUDE.md at runtime, so usually no agent edits are required).
- [ ] If the app introduces a new platform (e.g. first Android app in an iOS-only project), evaluate whether a new platform-specific architect agent is needed — add it to homebase's `agents/` if so, not to the project.

### 7. Philosophy / Brand Check

- [ ] Run the project's philosophy check (if one exists) against the product concept.
- [ ] Confirm the product does not conflict with brand-level principles or hard rules.

### 8. Governance Gates

- [ ] If the project adopts HOMEBASE-SOP-010 HIG Compliance and the new app targets an Apple platform: run an initial HIG consultation for major interaction patterns (navigation, menu bar extras, alerts) before implementation begins.
- [ ] If the project adopts HOMEBASE-SOP-007 UI Verification: confirm the app's rendering environment (dev server, simulator, emulator) can be started from a clean checkout — otherwise the verification gate will block every commit.
- [ ] If the project adopts HOMEBASE-SOP-008 Failure State Data Preservation and the app captures user-generated inputs: design the failure-state artifact inventory alongside the first pipeline, not after.
- [ ] If the project adopts HOMEBASE-SOP-013 Roadmap Management: claim a 2–4-char Linear team key, add it to `standards/LINEAR_WORKSPACE.md` and SOP-013 § Teams, then run `homebase roadmap init <app>` (via `technical-project-manager`) to create the team, labels, GitHub integration, and first Planned Project. Follow `templates/linear-team-bootstrap.md`.

### 9. Final Verification

- [ ] All cross-references in the new app's CLAUDE.md resolve to existing files (run `scripts/validate-docs.sh`).
- [ ] The app's CLAUDE.md includes enough context for any homebase agent to understand the project without prior knowledge.
- [ ] `BRAND_ASSETS.md` (or equivalent) references the project's parent brand guide for shared values.

---

## Related

- HOMEBASE-SOP-003 Documentation Governance — file naming and placement rules for the new docs.
- HOMEBASE-SOP-005 Release Process — first release of the new app will follow the universal release SOP.
- HOMEBASE-SOP-011 Customer Research — persona and customer research standards.
- Project-specific thinking frameworks (e.g. `Documentation/PHILOSOPHY_CHECK.md` or `Documentation/Brand/BRAND_CONTEXT.md` in a project's own docs) — philosophy and brand-identity disciplines that run alongside this checklist. These are not SOPs; they are references applied at design/decision time.
