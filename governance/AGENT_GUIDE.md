# Agent Guide

Staff directory for homebase. Defines who's on the roster, their decision authority, and when to consult whom.

All agents in `~/code/homebase/agents/` are **project-agnostic**. Their identities, expertise, and working styles are described here; they pick up project-specific context (domain, brand, apps) from the project's root CLAUDE.md at runtime.

Individual projects extend this guide in their own AGENT_GUIDE if they need project-specific agents beyond the homebase roster.

## How to Use This Guide

- Consult the relevant agent(s) before making decisions in their domain.
- If two agents disagree, escalate to the user.
- If a safety / brand / legal concern arises, the named "final authority" agent decides.

---

## Staff Roster

### Core Staff (on call for every project)

| Agent | Domain | Use when |
|---|---|---|
| **technical-project-manager** | Doc governance, cross-project coordination, GitHub API gatekeeper | Any GitHub API operation; any documentation creation/edit; cross-project audits; release coordination |
| **swift-architect** | iOS / macOS / Swift architecture | SwiftUI/UIKit view hierarchy, SwiftData/file persistence, Swift 6 concurrency, MainActor isolation, Apple platform framework choices |
| **rails-architect** | Rails architecture | Model design, service objects, migrations, Hotwire patterns, ActiveRecord, Minitest strategy |
| **go-architect** | Go / stdlib architecture | Go stdlib-first design, SQLite WAL mode, html/template patterns, performance profiling |
| **kotlin-systems-architect** | Android / Kotlin architecture | Jetpack Compose, Room schema design, Gradle plugin design, KMP guidance |
| **web-frontend-architect** | Web frontend | Hotwire/Stimulus patterns, CMS/ERP interface design, Turbo Frames, Stimulus controllers, CSS architecture |
| **qa-engineer** | QA and testing | User story registries, Capybara system tests, Chrome MCP manual testing, test plan authoring, stability milestone gating |
| **ui-ux-designer** | UI/UX design | Interface reviews, accessibility audits, platform HIG compliance, design-system consistency |
| **copywriter** | User-facing text | UI copy, marketing, App Store / Play Store metadata, localisation |
| **brand-manager** | Brand identity | Visual-identity compliance, voice and tone, cross-brand routing (when the project has multiple brands) |

### Specialists (assignments narrower than "every project")

| Agent | Domain | Who calls them |
|---|---|---|
| **dive-science-advisor** | Dive physiology, deco algorithms, gas blending formulas, safety authority | Dive-related projects (e.g. Field Suite) |
| **diving-product-manager** | Product strategy for diving products, feature prioritisation, market analysis | Dive-related projects |
| **example-product-pm** | Product strategy for a brand's apps (per-brand exemplar — clone one per brand) | Brand-scoped projects |
| **example-reviewer** | Domain review of editorial/article drafts (per-lens exemplar — finance / tech / engineering / people) | Blog/article content |

## Mandatory SOPs for Every Agent

Every agent MUST follow these SOPs. They are not guidelines — they are mandatory step-by-step procedures:

| SOP | Covers |
|---|---|
| [HOMEBASE-SOP-001 Development Workflow](../sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md) | Issue lifecycle, commit format, branching, closing |
| [HOMEBASE-SOP-003 Documentation Governance](../sops/HOMEBASE-SOP-003-DOCUMENTATION_GOVERNANCE.md) | File placement, naming, cross-references, validation |
| [HOMEBASE-SOP-002 GitHub API Usage](../sops/HOMEBASE-SOP-002-GITHUB_API_USAGE.md) | TPM-only `gh` CLI, rate limits, caching |

If the project adopts HOMEBASE-SOP-011 Customer Research (opt-in — declared in the project's root CLAUDE.md § Adopted SOPs), every agent also consults the relevant persona's `PROFILE.md` and `THINKING_PATTERNS.md` under `Customers/` before feature work. The PM agents for the product are the primary owners of that research.

**Execution principle**: When an SOP says MUST, execute and report — do not ask for confirmation. The user has already approved the procedure by establishing it as an SOP.

## Responsibility Matrix

| Decision type | Primary agent | Consult |
|---|---|---|
| Issue creation & triage | technical-project-manager, relevant PM | Domain agent |
| New feature scope | Relevant PM | Specialist advisor if safety/brand-critical |
| iOS / macOS architecture | swift-architect | Specialist advisor if safety-critical |
| Android architecture | kotlin-systems-architect | Specialist advisor if safety-critical |
| Rails architecture | rails-architect | Specialist advisor if safety-critical |
| Go architecture | go-architect | Specialist advisor if safety-critical |
| Web frontend architecture | web-frontend-architect | rails-architect, ui-ux-designer |
| UI/UX design | ui-ux-designer | Relevant PM, platform architect |
| User-facing copy | copywriter | Relevant PM |
| Brand decisions | brand-manager | Relevant PM |
| Safety-critical features | Specialist advisor (e.g. dive-science-advisor) | Platform architect |
| Documentation | technical-project-manager | Domain agent |
| GitHub API operations | technical-project-manager | — (sole authority) |
| Release coordination | technical-project-manager | Platform architect |
| User-story registries (web) | qa-engineer | Relevant PM |
| System-test authoring (web) | qa-engineer | rails-architect |
| Stability milestone gating (web) | qa-engineer | — |
| Manual browser testing | qa-engineer | — |

## Escalation Paths

- If two agents disagree → escalate to the user.
- If a safety concern arises → the named safety specialist (e.g. dive-science-advisor) has final authority.
- If a brand concern arises → brand-manager has final authority; if multi-brand, the relevant brand PM.
- Cross-cutting decisions → technical-project-manager coordinates.

## Governance of the Roster

### Review Triggers

- New project added to the company — re-evaluate whether current staff covers it.
- Quarterly audit (beginning of each quarter).
- When agent responsibilities overlap or conflict.

### Criteria for Adding an Agent

- The domain is distinct enough that existing agents cannot cover it.
- The agent's responsibilities are clearly scoped and non-overlapping.
- There is a real, recurring need (not hypothetical).

### Criteria for Consolidating Agents

- Two agents have overlapping responsibilities.
- An agent is rarely consulted (< once per quarter).
- An agent's domain has been absorbed by another.

### Criteria for Deprecating an Agent

- The project or platform the agent served has been permanently retired.
- The agent's responsibilities have been fully transferred to another.

## Agent Prompt Structure

Every file in `~/code/homebase/agents/` follows the same shape:

```markdown
---
name: <lowercase-hyphen>
description: <one line, specific>
model: inherit
---

<Identity — who this staff member is>
<Expertise — tools, frameworks, domain>
<Operating rhythm — how they work, SOP references, gating rules>
<Collaboration — who they hand off to, who hands off to them>
<Hard rules — what they never do>
```

No hardcoded project names or paths. Project context comes from the project's root CLAUDE.md, which is always loaded when Claude Code opens a project.
