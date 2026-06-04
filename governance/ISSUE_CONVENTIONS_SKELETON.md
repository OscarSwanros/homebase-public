# Issue Conventions Skeleton

Universal form of issue title format, label taxonomy, and triage rules. Each homebase-adopting project extends this skeleton in its own `ISSUE_CONVENTIONS.md` by filling in concrete scope prefixes and project-specific label values.

## Title Format

Every issue title MUST be:

```
{Scope}: {Imperative verb phrase describing the change}
```

### Rules

1. **Always prefix with a scope.** Concrete prefixes are defined by each project. For apps that exist on multiple platforms, always use the platform-qualified prefix (e.g. `GasCalc iOS:`, `GasCalc Android:`, not bare `GasCalc:`).
2. **Use colon-space** (not brackets) as the separator: `ShopOS: Build...` not `[ShopOS] Build...`
3. **Start the description with an imperative verb**: Add, Fix, Remove, Build, Update, Replace, Implement, Gate, Guard, Refactor.
4. **Do NOT put priority, severity, or platform in the title.** That information belongs in labels. Never use `[P0]`, `[iOS]`, `CRITICAL:` etc. as title prefixes.
5. **Do NOT put deprecated app names in titles.** Always use the current canonical name.
6. **For bugs, describe the symptom or fix** — not the word "Bug":
   - Good: `ShopOS: Fix capacity gate inconsistency with spots_remaining`
   - Bad: `ShopOS: Bug — capacity gate issue`
7. **Keep titles under 100 characters** when possible. Use the issue body for detail.

## Label Taxonomy (Universal Shape)

Every project's label taxonomy MUST have the following **categories**, even if the concrete values differ:

### 1. App / Scope label — exactly one

Identifies which app or scope the work belongs to. Each project defines its own set of app labels, plus a small number of cross-cutting scopes (examples: `governance`, `infra`, `docs`, `website`).

### 2. Type label — exactly one

Standard set shared across all projects:

| Label | Description |
|---|---|
| `bug` | Something is broken or wrong |
| `enhancement` | New feature or improvement |
| `documentation` | Documentation-only change |
| `tech-debt` | Code quality without behavior change |
| `refactor` | Architecture improvement without behavior change |

### 3. Priority label — exactly one (unless `backlog` / `parked` / `spike`)

Standard set shared across all projects:

| Label | Description |
|---|---|
| `P0` | Critical — blocks release or causes data loss |
| `P1` | High — fix before next release |
| `P2` | Medium — fix when capacity allows |
| `P3` | Low — nice to have |

### 4. Platform label — exactly one per issue (for multi-platform apps)

Standard set, but used only by projects with multi-platform apps:

| Label | Description |
|---|---|
| `ios` | iOS (iPhone + iPad) |
| `macos` | macOS |
| `android` | Android |
| `kmp` | Kotlin Multiplatform shared code |

Web-only and web-only-project issues do not need a platform label.

## Optional Labels (Recommended Patterns)

Projects may adopt any of these optional categories. Names and values are standardised for portability.

### Effort Estimate

| Label | Description |
|---|---|
| `effort:xsmall` | < 1 hour |
| `effort:small` | 1-2 hours |
| `effort:medium` | 2-6 hours |
| `effort:large` | 6+ hours |

Recommended for all P0/P1 issues and for any issue in an active release.

### Domain / Concern

Use to mark issues that require specialist review.

| Label | When to use |
|---|---|
| `safety` | Affects safety calculations or user safety (projects with safety-critical features) |
| `security` | Security hardening, vulnerability fixes |
| `localization` | Translation or locale-specific work |
| `a11y` | Accessibility improvement |
| `ux` | User experience improvement |
| `onboarding` | User onboarding and guidance |
| `copy` | Copy / terminology changes |
| `testing` | Testing infrastructure and quality |
| `architecture` | Code architecture and structure |
| `performance` | Performance optimisation |
| `governance` | Process and governance work |
| `legal` | Legal review or compliance requirement |

Each project may add its own domain labels (e.g. `dive-science`, `dive-computer`, `branding`).

### Lifecycle Labels

| Label | Description |
|---|---|
| `launch-blocker` | Blocks App Store / Play Store / deployment |
| `backlog` | Future work, no current timeline |
| `parked` | Evaluated and parked — not scheduled |
| `spike` | Time-boxed research or exploration |
| `product-proposal` | Strategic review required |

## Epic Issues

An **epic** is an umbrella issue grouping related work. Epics are not just task lists — they define user-facing behaviour that child issues collectively deliver.

### Title Format

```
{Scope}: {Feature Name} (Epic)
```

Example: `ShopOS: Open Water Enrollment Optimization (Epic)`

### Required Sections

Every epic body MUST contain these sections in order:

1. **Description** — what the epic delivers and why it matters (business impact, user pain points).
2. **User Stories** — behaviour specifications from every relevant user role (see below).
3. **Issue Checklist** — task-list checkboxes (`- [ ] #NNN`) linking all child issues, grouped by phase or layer.
4. **Key Decisions** — resolved architectural or product decisions.
5. **Implementation Order** — dependency graph or suggested sequencing.

### User Stories (Mandatory on Epics)

Epics MUST include user stories covering **every distinct user role** that interacts with the feature.

**Format:**

```
> **US-{role}{number}**: As a {role}, I want {action}, so that {benefit}.
```

- **Role prefix**: `S` for student/customer, `A` for admin/staff, `D` for diver (consumer apps), `I` for instructor, `O` for shop owner. Each project may extend the set with its own role codes.
- **Number**: sequential within each role prefix (`US-S1`, `US-S2`, ..., `US-A1`, `US-A2`).
- **Grouping**: under descriptive subheadings ("Account and Profile", "Reviewing Applications").

**Coverage rules:**
- Every wizard step, form, or multi-step flow needs at least one story per role that interacts with it.
- Error paths and edge cases (e.g. "returning customer with existing data", "upload later") need stories.
- Communication touchpoints (emails, notifications) need stories from the recipient's perspective.

User stories serve as the acceptance criteria for system tests. Each story should be directly translatable into a test scenario.

### User Stories on Non-Epic Issues

**For web projects**: user stories are **mandatory** on any issue that modifies user-facing behaviour (labeled `ux`, `onboarding`, `copy`, `a11y`, or adding / changing forms / views / notifications / workflows). The qa-engineer agent reviews these for completeness before testing begins.

**For iOS and Android issues**: user stories are **recommended** on issues with user-facing behaviour changes.

**Skip user stories for purely technical issues**: model creation, migrations, API endpoints, refactors, CI/tooling, database changes, performance work. These issues use acceptance-criteria checklists only.

### Sub-Issues (Mandatory)

Epics MUST define their child issues as **GitHub sub-issues** (via the `addSubIssue` GraphQL mutation). Task-list checkboxes in the epic body are display-only and do not create a trackable parent-child relationship.

```bash
# Get node IDs
gh api graphql -f query='query { repository(owner:"OWNER", name:"REPO") { issue(number:{N}) { id } } }' --jq '.data.repository.issue.id'

# Link
gh api graphql -f query='mutation { addSubIssue(input: { issueId: "{EPIC_NODE_ID}", subIssueId: "{CHILD_NODE_ID}" }) { subIssue { number } } }'
```

### Epic Lifecycle

- Create the epic BEFORE creating child issues.
- Add child issues as GitHub sub-issues immediately after creation.
- Child issues SHOULD reference the epic in their description.
- Close the epic only when ALL child issues are closed.
- Update the epic's task-list checkboxes as child issues complete.

## Platform Issue Splitting (Mandatory)

When a feature, bug fix, or enhancement applies to an app that exists on multiple platforms, create **one GitHub issue per platform**. Do NOT create a single cross-platform issue. See HOMEBASE-SOP-001 § A3 for the full rule and exceptions.

## Linear-First Tracking

For projects that adopt HOMEBASE-SOP-013, **Linear is the primary tracker** and GitHub issues are mirrored automatically by Linear's GitHub integration.

### Identifiers

| Side | Shape | Example | Where it lives |
|---|---|---|---|
| Linear issue | `KEY-N`, where `KEY` matches `[A-Z]{2,5}` | `TFD-123`, `HMB-7`, `TBL-42` | Linear (primary) |
| GitHub mirror | `#N` | `#412` | GitHub (auto-created) |

Linear team keys map 1-to-1 to monorepos (see `~/code/homebase/standards/LINEAR_WORKSPACE.md`):

| Linear team | Repo |
|---|---|
| `TBL` | `~/code/studio` |
| `TFD` | `~/code/field-suite` |
| `HMB` | `~/code/homebase` |

### Title and Label Parity

The title format and label categories defined in this skeleton apply to **both** sides. When Linear creates the GitHub mirror, it copies the title verbatim — so a malformed title in Linear surfaces in GitHub too. The reverse is also true. Triage in either tool, but treat the two as one record.

The Linear key prefix (e.g. `TFD-123`) is **not** part of the title — Linear renders it as a separate identifier column. Do not write `TFD-123: ShopOS: Build...` in the title; write `ShopOS: Build...` and let Linear show the key beside it. The `{Scope}:` prefix rule (§ Title Format) is unchanged.

### Commit Trailers

Both `Closes #N` and `Closes KEY-N` are accepted by `commit-sop-check.sh`. Use whichever identifier matches the side you opened the issue on. See HOMEBASE-SOP-001 §0 and §B2 for the full trailer rules.

### Projects Without Linear

Projects that have not adopted SOP-013 use only the GitHub `#N` form. The validator does not enforce a project's choice — both shapes always pass. Drop into a project's own `ISSUE_CONVENTIONS.md` if you need to mandate one form for that project.

## Triage Checklist

When creating or reviewing an issue, verify:

- [ ] Title uses `{Scope}: {imperative description}` format
- [ ] Has exactly one app / scope label
- [ ] Has exactly one type label
- [ ] Has a priority label (P0-P3) unless `backlog`, `parked`, or `spike`
- [ ] Has a platform label (`ios`, `android`, `macos`, `kmp`) for multi-platform app issues
- [ ] Has an effort label if it's in an active release / milestone
- [ ] Has domain labels if the work requires specialist review (`safety`, `security`, `legal`, etc.)
- [ ] Has `launch-blocker` if it blocks a store submission or deployment
- [ ] Title does not duplicate information already in labels (no `[P0]`, `CRITICAL:`, `[iOS]` in title)

## Label Color Scheme (Recommended)

For projects creating labels for the first time, a consistent colour scheme helps:

- **Priority**: red gradient (`P0 = #B60205`, `P1 = #D93F0B`, `P2 = #FBCA04`, `P3 = #D4C5F9`)
- **Type**: default GitHub colours
- **Platforms**: `ios = #34C759`, `macos = #8E8E93`, `android = #3DDC84`, `kmp = #7F52FF`
- **Effort**: green gradient (`xsmall = #C2E0C6`, `small = #86CE86`, `medium = #4CAF50`, `large = #2E7D32`)
- **Apps**: project-specific; pick distinct high-contrast colours

## What Belongs in This Skeleton vs. Per-Project File

| Lives here (universal) | Lives in `<project>/ISSUE_CONVENTIONS.md` |
|---|---|
| Title format rule | Concrete scope prefixes (`GasCalc iOS:`, `StudioWeb:`, etc.) |
| Label category shape (App, Type, Priority, Platform) | Concrete app labels (`gascalc`, `logapp`, `studio-web`) |
| Standard Type/Priority/Platform values | Project-specific domain labels (e.g. `dive-science`) |
| Epic required sections | Project-specific role codes beyond the default set |
| Sub-issue linking procedure | Project's GitHub org/repo name |
| Triage checklist | Project-specific exceptions |
| Effort label taxonomy | — |
| Colour scheme recommendation | Final chosen colours |
