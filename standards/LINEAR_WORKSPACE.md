# Linear Workspace Topology

Canonical structure of the shared Linear workspace that backs every homebase-adopting app's roadmap. Governed by `HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md`.

## Workspace

**Single workspace** (`Studio + TFD`) hosts every Team, Project, Milestone, and Initiative. One API key; one gatekeeper (`technical-project-manager`); one snapshot file (`registry/roadmap-snapshot.yml`).

## Teams (= monorepos / execution containers)

**Three Teams**, keyed by monorepo. Team keys are **immutable** once created — they become issue-ID prefixes and Linear reserves the key forever even after a team is archived.

| Team | Key | Purpose |
|---|---|---|
| Studio | `TBL` | Example brand-apps monorepo: `studio-web`, `bookshelf`, `capture`, `blog` |
| Field Suite | `TFD` | Example domain-apps monorepo: `gascalc`, `logapp`, `link-companion`, `photofix`, `shopos`, `sitedb` |
| Homebase | `HMB` | The company itself — CLI, SOPs, standards, governance, agents, skills |

Issue IDs prefix with the Team key (e.g. `TBL-42`, `TFD-17`, `HMB-3`) regardless of which app the issue concerns — the app is expressed by the Project the issue belongs to.

Adding a new Team should be rare (only when spinning off a new monorepo). When it happens:

1. Claim a 2–4-char uppercase key not already reserved in the workspace's history.
2. Add a row to this table AND to SOP-013 § Teams in the same commit.
3. Run `homebase roadmap bootstrap` (idempotent — creates only the new Team + its labels + its canonical Projects).

## Projects (= apps, long-lived)

**One Linear Project per app**, inside its monorepo's Team. Canonical Projects:

| Team | Projects |
|---|---|
| `TBL` | StudioWeb · Bookshelf · Capture · Operator Name · Briefing · Authoring |
| `TFD` | GasCalc · LogApp · Link Companion · PhotoFix · ShopOS · SiteDB |
| `HMB` | Homebase |

- **State**: stays `started` while the app is active. Moves to `canceled` only if the app is retired.
- **Target date**: not used on Projects (apps don't have a finish line — releases do).
- **Naming**: exactly the app's display name. No version suffix.

Adding a new app: during SOP-009 onboarding, run `homebase roadmap bootstrap` after registering the app in `registry/PROJECTS.md` and CANONICAL_PROJECTS in `scripts/roadmap/linear.rb`. The new Project appears under the app's monorepo Team automatically.

## Milestones (= releases)

Every release is a Linear Milestone inside the app's Project. Naming is strict SemVer:

| Convention | Value |
|---|---|
| Name | `v<MAJOR>.<MINOR>.<PATCH>` (e.g. `v1.1.0`) |
| Target date | Optional. Use as aspirational quarter anchor. |
| Description | Scope in 1–3 sentences. |

Shipping a release marks the Milestone done (via SOP-005 Phase C.5). The parent Project never transitions.

## Initiatives (= cross-app themes, optional)

Group Projects across Teams for cross-cutting work:

- Format: `<Theme or Quarter> — <Scope>` (e.g. `iOS 19 compatibility`, `Decompression overhaul`).
- Membership: zero or more Projects.
- Created ad-hoc as themes emerge; no initiatives are created by the bootstrap.

## Canonical labels (per-Team)

Every Team bootstraps with these labels:

| Label | Meaning |
|---|---|
| `roadmap` | Issue surfaces on the Project's roadmap view (vs. raw backlog). |
| `p0`, `p1`, `p2`, `p3` | Priority; mirrors GitHub label taxonomy. |
| `blocked` | Externally blocked; cross-Project blockers use Linear's linked-issue relation. |

Per-Project (per-app) labels can be added freely but MUST NOT collide with these canonical names.

## Commit trailers

Commit trailers accept either form: GitHub `#N` (`Closes #412`) or Linear `KEY-N` (`Closes TBL-42`). See SOP-001 §0 and §B2 for the canonical rule. Linear's GitHub integration mirrors closure both ways, so either identifier auto-closes both records. Linear Magic-Linking additionally picks up the Linear ID from branch names and PR titles when only the GitHub `#N` appears in the commit.

## MCP response field semantics

When parsing Linear MCP responses (`mcp__plugin_linear_linear__list_issues`, `mcp__plugin_linear_linear__get_issue`, etc.), the `id` field has type-dependent semantics:

- **On directly-returned issue objects, `id` is the human key** (e.g. `"id":"TFD-1370"`). There is **no separate `identifier` field**. Code scanning a dump for issue keys must match `"id":"<TEAM-KEY>-\d+"` — not `"identifier":...`.
- **`parentId` follows the same convention** — the parent issue's human key (e.g. `"parentId":"TFD-841"`), matching the parent's own `id`.
- **Inside issue description prose, embedded `<issue id="UUID">DISPLAY-KEY</issue>` references DO use the Linear GraphQL UUID** in the attribute, with the human key as the element body. Do not confuse these with the issue-object `id`.
- **Other object types (attachments, comments, projects, milestones)** carry GraphQL UUIDs in their own `id` fields. The "human key in `id`" rule is specific to issue objects.

The Linear GraphQL UUID for an issue exists internally but is not surfaced on the MCP issue payload. Use the human key for cross-referencing, parent linkage, and trailer matching; use UUIDs only when chasing an embedded prose reference back to its source issue.

## Invariants the audit enforces

`homebase roadmap audit` exits non-zero if any of the following holds:

- A Team with a key outside the canonical table exists (or a canonical Team is missing).
- A Project name inside a canonical Team isn't in `CANONICAL_PROJECTS` for that Team.
- A canonical label is missing from any Team.
- An Initiative name doesn't match `<Theme or Quarter> — <Scope>`.
- A `<project>/.homebase/project.yml` `apps[].roadmap.linear_team_key` doesn't match the Team that actually holds that app's Project.
- `registry/roadmap-snapshot.yml` is older than 48 h.

## Related

- `@~/code/homebase/sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md` — canonical SOP.
- `~/code/homebase/schemas/linear-workspace.schema.json` — machine-readable spec of this topology.
- `~/code/homebase/schemas/project.schema.json` — per-app `roadmap:` block.
- `~/code/homebase/scripts/roadmap/linear.rb` — implementation (CANONICAL_TEAMS + CANONICAL_PROJECTS live here; edit together with this doc).
