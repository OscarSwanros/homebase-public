# HOMEBASE-SOP-001: Development Workflow

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Canonical procedure for issue tracking, commit message form, branching, and closing work — across every project that adopts homebase.

## Purpose

Ensure every code change is traceable to a tracked issue, every commit is consistently formatted, and nothing is lost between sessions. Untracked work is invisible to release management, breaks audit trails, and causes duplicate effort.

## Scope

**Applies to**: All agents, all platforms, all projects that adopt this SOP (declared in the project's root CLAUDE.md § Adopted SOPs).

**No exceptions.** Every code change that reaches `main` MUST be linked to a tracked issue (Linear primary, GitHub mirror — see §0 below), except for the four exempt categories described in § Exempt Commits.

## Enforcement

This SOP is enforced by a git `commit-msg` hook that calls `scripts/hooks/commit-sop-check.sh` — a single validator symlinked from homebase into every homebase-adopting project. The same validator backs the Claude Code `PreToolUse` hook via `scripts/hooks/claude-precommit.sh`, so bypassing Claude Code doesn't bypass the rule. Using `--no-verify` or `-n` to skip the hook is forbidden.

---

## §0 — Issue Tracking: Linear Primary, GitHub Mirrored

Homebase tracks product work in **Linear** (see HOMEBASE-SOP-013). Linear's GitHub integration mirrors every Linear issue to a GitHub issue in the matching repo, and vice versa: closing one closes the other.

**Either identifier is canonical for this SOP**:

| Identifier shape | Origin | Example |
|---|---|---|
| `#N` | GitHub issue number | `#412` |
| `KEY-N` | Linear issue identifier (`[A-Z]{2,5}-[0-9]+`) | `TFD-123`, `HMB-7` |

The validator (`commit-sop-check.sh`) accepts either form anywhere a trailer is required. Use the identifier of whichever side you actually opened — if you created the work in Linear, `Closes TFD-123` is correct; if you opened the GitHub issue directly, `Closes #412` is correct. Linear's integration handles the cross-close.

This SOP still governs projects that have not adopted Linear: in those projects, only the `#N` form is used. The validator does not enforce a project's choice — it only enforces shape.

---

## Phase A — Before Starting Work

**MANDATORY GATE**: No code changes may be made until a GitHub issue exists for the work. This is non-negotiable. Issues MUST be created BEFORE implementation begins — not during, not after.

If a plan identifies multiple issues (e.g., a framework change that ripples across multiple apps or platforms), create **all** issues first, then begin implementation. This ensures every piece of work is visible, trackable, and prioritizable before effort is spent.

### A0. cwd-Misroute Pre-flight (Mandatory)

`homebase work start <KEY>` runs a pre-flight check before any side-effects (no worktree, no Linear transition, no `.homebase/work-state.json` write). It reads the issue's Linear project name, looks up the owning project's path via `registry/projects.paths` + each project's `.homebase/project.yml`, and aborts with exit 3 if the cwd isn't an ancestor of the owning project's path.

Why this gate exists: an agent that runs `homebase work start TFD-1393` from `~/code/homebase` (the wrong project for a `shopos` issue) used to silently scaffold a worktree under `~/code/homebase/.worktrees/...`, transition Linear Backlog → In Progress, and leave the actual edits — landing on a different repo's `main` checkout because Bash `cd` doesn't persist across tool calls. Empty-worktree finish + wrong-branch commit + Linear Done with zero shipped code followed. The cascade was the qwen3.5/TFD-1393 incident; HMB-45 captures it as the root cause behind Findings 7/8/9.

**Behaviour:**

- When the issue has a Linear project (the common case): the gate compares the owning project's path against `pwd -P`. Mismatched → abort with the redirect (`cd <owner-path> && homebase work start <KEY>`). All-or-nothing: nothing is written, no transition occurs.
- When the issue has no Linear project (legacy / pre-bootstrap state): the gate falls back to the existing cwd-inference path. The fallback is logged (not silent) and the operator is responsible for verifying the cwd before committing.

**Recovery from a refused start:**

```sh
cd <owner-path>             # the message names this exactly
homebase work start <KEY>   # re-run from the right cwd
```

(HMB-45 Finding 7. Pairs with the `commit-sop-check.sh` wrong-branch gate (Finding 8) and the `commits-present` finish gate (Finding 9) as belt-and-suspenders coverage of the same failure family.)

### A1. Search for an Existing Issue

```bash
gh issue list --search "<keywords>"
gh issue list --label "<app-label>"
```

(All `gh` invocations are executed by the technical-project-manager agent. See HOMEBASE-SOP-002.)

If an issue exists, note its number and proceed to Phase B.

### A2. Create an Issue If None Exists

If no issue tracks the work, **stop and create one now**.

**Who creates issues**: The **technical-project-manager** and the relevant product-manager agent for the project (e.g. `diving-product-manager`, `example-product-pm`, `example-product-pm`) are the primary issue authors. Other agents MAY create an issue if the authors are not available, but SHOULD defer to them for complex or strategic issues.

**Issue creation pattern** (uses `--body-file` to avoid command-substitution prompts):

1. Write the body to a temp file:

   ```markdown
   ## Description

   {What needs to be done and why.}

   ## Acceptance Criteria

   - [ ] {Criterion 1}
   - [ ] {Criterion 2}
   ```

2. Create the issue:

   ```bash
   gh issue create \
     --title "{Scope}: {Imperative verb phrase}" \
     --label "{scope-label},{type-label},{priority-label}" \
     --body-file /tmp/issue-body.md
   ```

3. Clean up: `rm /tmp/issue-body.md`

**Title format**: `{Scope}: {Imperative verb phrase}` — under 100 characters. Concrete scope prefixes (e.g. `StudioWeb:`, `GasCalc iOS:`) are defined in the project's own `ISSUE_CONVENTIONS.md`, which extends the universal skeleton at `~/code/homebase/governance/ISSUE_CONVENTIONS_SKELETON.md`.

**Required labels**: Each project's `ISSUE_CONVENTIONS.md` defines its app, type, priority, and (where relevant) platform label taxonomy.

**Linear roadmap linkage (optional, per SOP-013)**: if the work belongs to a planned release on a Linear Project, invoke `/new-issue --linear-project <vX.Y.Z>` instead. The skill creates the Linear issue first; Linear's GitHub integration auto-creates the mirror GH issue. Both identifiers (the Linear `KEY-N` and the GitHub `#N`) are valid in commit trailers — see §0 and §B2 — so use whichever you actually opened.

### A3. Platform Splitting (Mandatory)

If the work applies to an app that exists on multiple platforms (e.g., iOS + macOS + Android), create **one issue per platform** with platform-specific details. Never create a single cross-platform issue.

- Each issue title uses the platform-qualified prefix (e.g. `GasCalc iOS:`, `GasCalc Android:`).
- Each issue gets **exactly one** platform label.
- Each issue's acceptance criteria references the platform's APIs, frameworks, UI patterns, and test commands — never generic criteria that "should apply to every platform."
- Cross-reference sibling issues in each description ("See also: #501 (iOS), #503 (Android)").
- Platform issues are closed independently. iOS work may ship in a different cycle than Android work.

**Exceptions**:
- KMP shared modules with no platform-specific UI → single issue with the `kmp` label.
- iOS-only shared frameworks → single issue with `ios`.
- Web-only apps → single issue (web is inherently single-platform).

### A4. Epic Issues — User Stories Mandatory

An **epic** is an umbrella issue grouping related work. Epics require:

1. A **Description** section (what the epic delivers, business impact)
2. **User Stories** covering every distinct user role (`As a <role>, I want <action>, so that <benefit>`)
3. **Issue Checklist** linking child issues (task-list format `- [ ] #NNN`)
4. **Key Decisions** — architectural or product decisions already made
5. **Implementation Order** — dependency graph or suggested sequencing

**Create the epic BEFORE creating child issues.** After child issues exist, link them as GitHub sub-issues (not just task-list checkboxes):

```bash
# Get node IDs
gh api graphql -f query='query { repository(owner:"OWNER", name:"REPO") { issue(number:{N}) { id } } }' --jq '.data.repository.issue.id'

# Link
gh api graphql -f query='mutation { addSubIssue(input: { issueId: "{EPIC_NODE_ID}", subIssueId: "{CHILD_NODE_ID}" }) { subIssue { number } } }'
```

Task-list checkboxes in the epic body are display-only and do not create a trackable parent-child relationship.

### A5. Assign to Release (if the project uses GitHub Projects v2)

Projects that use GitHub Projects v2 assign every issue to a Release field on the board. Field IDs live in `<project>/.homebase/project-fields.yml`. Use the project's local `scripts/set-project-fields.sh` rather than raw `gh project item-edit`.

Projects that use Projects V2 MUST also follow HOMEBASE-SOP-012 (GitHub Project Management) for the banned-mutation rules and recovery procedure. Projects that do not use Projects V2 skip this step entirely.

---

## Phase B — During Work

### B0. Worktree Mode (when project.yml opts in)

When the project's `.homebase/project.yml` declares `worktree.enabled: true` (HMB-27), `homebase work start <KEY>` creates a git worktree at `<project>/.worktrees/<branch>/` instead of swapping the main checkout to the new branch. Each worktree carries its own `.homebase/work-state.json`, its own `.homebase/.work-env`, and (for Rails apps that read `WORKTREE_DB_SUFFIX`) its own dev/test database. Multiple agents on the same project can run in parallel without colliding.

After `homebase work start <KEY>`, `cd` into the worktree before doing any work:

```
cd $(homebase work goto <KEY>)
source .homebase/.work-env
```

`homebase work list` shows every active worktree in the current project (KEY → branch → path → Linear state). `homebase work finish` and `homebase work cancel` automatically remove the worktree on success.

When `worktree.enabled` is false or absent, the legacy single-branch flow is preserved — `homebase work start` switches the main checkout in place, exactly as before.

**Auto-trust mise on the new worktree path.** When the project's worktree mode is on and a `.mise.toml` exists at the repo root, `homebase work start` runs `mise trust <worktree_path>` immediately after `git worktree add`. mise refuses to load tools (Ruby, Node, Java, Python pinned via `.mise.toml`) until the path is trusted; without the auto-trust, the next gate that touches a Ruby tool blew up with a misleading downstream error (`ANDROID_HOME unset`, `java not found`, `bundle check` fails) — none of which point at the actual cause. Idempotent; silent no-op when mise isn't installed. Pass `MISE_AUTO_INSTALL=1` to also run `mise install` inside the worktree (off by default because install can be slow on fresh machines). (HMB-45 Finding 6.)

**Stale workflow.yml warning.** After branch creation, `homebase work start` checks whether `origin/main` has commits since the branch base that touched `.homebase/workflow.yml`. If yes, it emits a warning (`[warn] .homebase/workflow.yml on origin/main has changes since branch base (main): …`) listing the offending commits and recommending a rebase. Purely informational — start never blocks on a stale workflow.yml; the operator chooses when to rebase. Skipped silently when origin/main isn't fetched (offline, fresh clone). Catches the failure mode where a branch off stale main inherits old gate definitions (e.g. TFD-843's branch carrying pre-TFD-1425 rubocop scoping that lit up 480 false offenses on auto-generated `db/*_schema.rb` files). (HMB-45 Finding 2.)

### B1. Commit Message Format

```
{Imperative summary, under 72 characters}

{Optional body: explain WHY, not WHAT. Wrap at 72 chars.}

{Issue reference trailer}
```

**Summary rules**: Start with an imperative verb (Add, Fix, Remove, Update, Refactor). Capitalize the first word. No period.

**Body rules**: Separate from summary with one blank line. Wrap at 72 characters. Explain **why**, not **what** — the diff shows what changed.

### B2. Issue Reference Trailers

Both GitHub (`#N`) and Linear (`KEY-N`) identifiers are accepted; see §0. The examples below show the GitHub form on the left and the equivalent Linear form on the right — pick the side that owns the work you opened.

| Situation | GitHub form | Linear form | Effect |
|---|---|---|---|
| Intermediate work | `Refs #N` | `Refs TFD-N` | Links commit; does not auto-close |
| Partial work (prose context, not a trailer) | `(part of #N)` in body | `(part of TFD-N)` in body | Links commit; does not auto-close |
| Final commit (enhancement) | `Closes #N` | `Closes TFD-N` | Auto-closes issue on merge to `main` |
| Final commit (bug fix) | `Fixes #N` | `Fixes TFD-N` | Auto-closes issue on merge to `main` |
| Final commit (alternative keyword) | `Resolves #N` | `Resolves TFD-N` | Auto-closes issue on merge to `main` |

Place the trailer on **its own line** at the end of the commit body.

**Cross-close behaviour**: GitHub auto-closes when its parser sees `Closes #N` on merge to `main`; Linear's GitHub integration mirrors that closure to the linked Linear issue. Conversely, Linear's parser recognises `Closes KEY-N` in a commit message linked to a Linear issue and closes the Linear side, mirroring back to GitHub. Either path works — pick the form that matches the identifier you've been using.

**Closing multiple issues**: Each closing trailer MUST be on its own line. GitHub only processes the first number on a combined line — `Closes #446, #412` only closes #446. The same one-per-line rule applies to Linear keys.

**Anti-patterns (REJECTED by the validator)**: `Part of #N`, `Related to #N`, `See #N`, `References #N`, `Ref #N`, `Relates to #N` — and the same forms with a Linear key (`Part of TFD-9`, `Related to HMB-3`, etc.). These read correctly to a human but are not auto-close keywords on either side, so the issue silently stays open. The prose form `(part of #N)` / `(part of TFD-N)` in parentheses within a body sentence is still fine.

**Branch-match validation.** When an active (non-finished) `.homebase/work-state.json` exists at the repo root, the commit-msg hook also rejects commits whose current branch differs from `work-state.branch`. Catches the failure mode where edits land on `main` (or any branch other than the one the work-state expects) while a worktree-style work-state is active. The error message names the expected branch, the current branch, and the recovery path (`cd $(homebase work goto KEY)`). Skipped when `HOMEBASE_OFF_CONTRACT=1` is set, when the work-state is `finished`, or when the work-state is malformed/missing. Pairs with the cwd-misroute pre-flight gate at `homebase work start` time and the `commits-present` finish gate as belt-and-suspenders coverage of the same root cause. (HMB-45 Finding 8.)

**Warning**: Parenthetical `(#N)` or `(TFD-N)` in the summary line does NOT auto-close issues. Always use a keyword trailer on its own line.

### B3. UI Verification Trailer (if the project adopts HOMEBASE-SOP-007)

Any commit that touches a rendered surface (HTML/ERB, SwiftUI/UIKit views, Compose, Jekyll templates, CSS/SCSS, etc.) MUST include a verification trailer before the issue reference:

```
Verified in browser: <one-sentence observation>
```

or, for Apple platforms:

```
Verified on simulator: <one-sentence observation>
Verified on device: <one-sentence observation>
```

The observation describes **what was checked**, not just that it was checked. `Verified in browser: looks good` is a skip — rewrite it. `Verified in browser: /portal/123 retry row renders inline without layout shift; flash dismisses on click` is an observation.

The trailer `UI verification skipped: <reason>` is permitted only for changes with no rendered surface.

Full procedure: `~/code/homebase/sops/HOMEBASE-SOP-007-UI_VERIFICATION.md`.

### B4. CHANGELOG Discipline

Commits that change user-visible behavior on a released app MUST update that app's `CHANGELOG.md` under `## [Unreleased]` in the **same commit**.

**Triggered by subject prefix.** `feat(<app>):` and `fix(<app>):` require a CHANGELOG update when `<app>` resolves to an app with a `CHANGELOG.md`. Breaking-change markers (`feat(<app>)!:`) are included. Other Conventional Commits prefixes (`refactor:`, `test:`, `chore:`, `docs:`, `style:`, `perf:`, `build:`, `ci:`) skip this rule. Scopes that don't resolve to an app (e.g. `feat(cli):` in homebase) are skipped.

**App + changelog resolution.** The hook looks up `<scope>` against the project's `.homebase/project.yml` `apps:` array first (HMB-26). Each app declares a `path` (repo-relative app root) and may declare a `changelog` override; when no override is set the changelog defaults to `<path>/CHANGELOG.md`. This is what lets monorepo-root apps like ShopOS (path = `ShopOS`, changelog = `ShopOS/Documentation/Release/CHANGELOG.md`) get enforced just like the `apps/studio-web/` shape. When `project.yml` is absent the hook falls back to the legacy `apps/<scope>/CHANGELOG.md` lookup so older studio-style monorepos still work without configuration.

**Multi-platform apps with one CHANGELOG per side.** Apps split across multiple repo roots (e.g. GasCalc living at `iOS/Apps/GasCalc` AND `Android/apps/gascalc`, each with its own CHANGELOG) declare the additional roots under `extra_paths: [{path, changelog?}]`. The hook treats each entry as a sibling app root: a commit whose source files all live under one entry's `path` is enforced against that entry's `changelog`. CHANGELOG files themselves are excluded from path-matching so staging the wrong-side CHANGELOG cannot accidentally turn a single-platform commit into an exempt cross-platform commit.

**Entry placement.** Inside `## [Unreleased]`, under one of the Keep-a-Changelog sections:

| Section | Use for |
|---|---|
| `### Added` | New capabilities |
| `### Changed` | Modifications to existing behavior |
| `### Fixed` | Bug fixes |
| `### Removed` | Dropped capabilities |
| `### Deprecated` | Soon-to-be-removed capabilities |
| `### Security` | Vulnerability fixes |

Reference the issue number(s) at the end of the bullet — `(#N)` is fine in prose.

**Why same commit.** `homebase deploy <app> production` refuses to tag a release if `## [Unreleased]` is empty (HOMEBASE-SOP-005 Step 1 — the safety net). Keeping `[Unreleased]` current commit-by-commit means the deploy tool is a tripwire, not the prompt to write one. Populating the changelog "later" invariably means writing it the instant deploy blocks — at which point the context for several commits has to be reconstructed from git log.

**Enforcement.** `scripts/hooks/commit-changelog-check.sh`, chained after `commit-sop-check.sh` from `.githooks/commit-msg`. The validator fails the commit if the subject is `feat(<app>):` / `fix(<app>):` for an app with a `CHANGELOG.md` but the CHANGELOG is not in the staged diff.

**Escape hatch.** If a commit genuinely does not change user-visible behavior, use a non-feat/fix prefix — `refactor(<app>):`, `test(<app>):`, `chore(<app>):`. The rule then does not apply. Do not dress an internal-only change as `feat:` or `fix:` to match the diff shape.

Example — a `feat(studio-web):` commit staged with its CHANGELOG line in the same diff:

```
apps/studio-web/CHANGELOG.md                             |  3 +++
apps/studio-web/app/controllers/admin/invoices_ctrl.rb   | 12 ++++++++++++
```

### B5. Inherited Test Failures — `known_main_failures.yml` Allowlist

A pre-existing test failure on `main` shouldn't block every `homebase work finish` for branches that didn't introduce it. Each project may declare an allowlist at `<project>/.homebase/known_main_failures.yml` that demotes specific failures from hard-fail to warning at finish-time.

**Schema** (full reference: `~/code/homebase/schemas/known-main-failures.schema.json`):

```yaml
failures:
  - check_name: rails_test                        # required_check name from workflow.yml
    test_id: "Foo::VersionTest#test_VERSION"      # literal substring searched in the log
    tracking_issue: TFD-1407                      # Linear KEY-N or GitHub #N — must exist
    expires_at: 2026-06-30                        # ISO date; expired entries hard-fail
    reason: "Hardcoded VERSION assertion; …"      # one-sentence audit trail
```

**Behaviour:**

- When a `validate-passes` check fails, `gate_validate_passes` reads `<project>/.homebase/known_main_failures.yml` (if present) and scans entries with the matching `check_name`. If any entry's `test_id` is found as a substring in the failing check's log AND `expires_at` is in the future, the failure is demoted to a `[warn]` line and the gate continues.
- If a matching entry exists but `expires_at` is in the past, the gate hard-fails with a "renew or remove" message naming the tracking issue. Forces periodic review; prevents indefinite lingering.
- Entries with an unparseable `expires_at` are treated as expired (fail-safe).

**CI on main MUST ignore the allowlist.** Each project's CI runner is responsible for running its test suite on `main` without the allowlist applied — that's how new failures get discovered and how cavalier additions are caught. The allowlist is a tactical bridge for *finishing branches that don't touch the failing test*, not a permanent silencer.

**When NOT to use the allowlist:**

- The failure is on YOUR branch (introduced by your changes). Fix it; the allowlist isn't a way to defer triage.
- The fix is one commit away. Just fix it on `main` first, then rebase.
- The expiry is unbounded ("we'll fix this someday"). Set ~3 months out by default; renew explicitly if the tracking issue genuinely needs more time.

(HMB-45 Finding 3. Cost on TFD-843: `ShopOS::VersionTest#test_VERSION_is_1.0.0` was failing on main; the version-test issue (TFD-1407) blocked the dashboard outstanding-balances work-finish even though TFD-843 didn't touch the version test — required a defensive fix on TFD-843's branch just to clear the gate.)

### B6. Commit Cadence

- **Commit at each stability milestone.** A milestone is reached when a discrete, self-contained unit of work is complete and the codebase builds successfully. Examples: a new model/migration, a new view/component, a service object, a refactoring step, a config change.
- **Test**: "If I stopped working right now, would this commit make sense on its own?" If yes, commit.
- **Push after each commit.** Keep the remote current.
- **Each commit must leave the codebase buildable** (compiles/boots without errors; existing tests pass).
- **Do not batch.** When resolving multiple issues in a session, commit and push after each issue before starting the next. HOMEBASE-SOP-001 is a real-time discipline, not a post-hoc checklist.

### B7. Branching

| Scenario | Branch | Naming |
|---|---|---|
| Single-commit fix, trivial change | Direct to `main` | — |
| Multi-commit work | Feature branch | `{scope}/{issue}-{slug}` |

Examples: `logapp/502-import-uddf`, `studio-web/12-calendar-sync`, `gascalc/610-gas-density-warning`.

PRs are not required for solo work, but recommended for cross-app or safety-critical changes.

### B8. Operator Ergonomics — Foreground Only for Long-Running Work Verbs

`homebase work finish`, `homebase work checkpoint`, `homebase work ship`, and `homebase roadmap bootstrap` invoke gate flows that can take several minutes (validate-passes runs each project's required-checks suite). Always invoke them **foreground** from Claude Code's Bash tool with the maximum harness timeout (`timeout: 600000`).

Backgrounded Bash invocations (`run_in_background: true`) of these verbs are reaped silently mid-suite by the Claude Code harness when their stdout idles past an internal threshold. The visible failure mode: the validate-passes child gets ~50 % through the project's test suite, output truncates without an `[fail]` line, no `finish_outcome` is written to `.homebase/work-state.json`, and `pgrep` confirms the process is dead. The same invocation foreground completes cleanly in 2–3 minutes. (HMB-45 Finding 1.)

This is a harness-level constraint outside homebase's reach — the recommendation here is the only viable workaround until upstream Claude Code addresses the reaping behaviour. Phase C's `homebase work finish` invocation must be foreground; if you find yourself reaching for `run_in_background`, stop and re-issue the call foreground.

---

## Phase C — Closing Out

### C1. Verify Acceptance Criteria

Before writing the final commit, verify the implementation against the issue's acceptance criteria and update the checkboxes in the issue body. **This is a quality gate, not just bookkeeping.**

1. Fetch the issue body: `gh issue view N --json body -q .body > /tmp/issue-body.md`
2. For each `- [ ]` criterion, **actively verify** against the code — read files, check behavior, confirm test coverage. Do not blindly check boxes.
3. If a criterion IS met: mark `- [x]`.
4. If a criterion is NOT met, determine whether it was descoped, deferred, or missed:
   - **Missed**: Fix it before closing.
   - **Deferred**: Add a note, reference a follow-up issue, get user approval.
5. Update the issue: `gh issue edit N --body-file /tmp/issue-body.md`.

Auto-closing via a commit keyword marks an issue "done" but does not confirm each criterion was verified. Unchecked boxes on closed issues make delivery impossible to audit.

### C2. Final Commit With Closing Keyword

The **final commit** for a resolved issue MUST use `Closes #N` (enhancements) or `Fixes #N` (bugs) on its own line. `Refs #N` on the final commit leaves the issue open.

```bash
git commit -m "$(cat <<'EOF'
{Imperative summary of the change}

{Optional body explaining WHY.}

Closes #N

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

### C3. Session-End Checklist (Mandatory)

Before returning control to the user, verify **all** of the following:

- [ ] All changes committed (`git status` clean)
- [ ] All commits pushed to the remote
- [ ] Every feature/bug commit references a tracked issue (`#N` or `KEY-N`)
- [ ] Every `feat(<app>):` / `fix(<app>):` commit on an app with a `CHANGELOG.md` staged that CHANGELOG in the same commit (B4)
- [ ] Acceptance-criteria checkboxes updated for resolved issues (C1)
- [ ] Final commit contains `Closes #N` / `Fixes #N` (or `Closes KEY-N` / `Fixes KEY-N`), NOT `Refs …`. Confirm with `git log --oneline -1`.
- [ ] Incomplete issues have `(part of #N)` or `(part of KEY-N)` in the most recent commit
- [ ] Tests pass for affected code
- [ ] If HOMEBASE-SOP-007 is adopted: every UI-touching commit carries a `Verified …` trailer

If a closing keyword is missing, create a follow-up commit:

```bash
git commit --allow-empty -m "$(cat <<'EOF'
Closes #N

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
EOF
)"
```

**Failure to complete this checklist is a critical SOP violation.**

---

## Exempt Commits

Four categories of commits do not require an issue reference. They are recognised by the validator by subject-line prefix, case-sensitive unless noted:

| Prefix | Used for |
|---|---|
| `Release {AppName} {version}` | Tag-cut release commits |
| `Post-release: ...` | Housekeeping after a release (opening an Unreleased section, etc.) |
| `Merge ...` | Merge commits |
| `chore:` or `chore(scope):` (case-insensitive) | Governance, tooling, CI config, dependency updates, doc typos. Conventional Commits scope syntax is accepted — e.g. `chore(website):`, `chore(ShopOS):`. |

**When `chore:` qualifies**: The commit must have **no user-facing behavior change**. Anything that alters UI, data, or customer behavior is feature or bug work and requires an issue.

Examples of valid chore commits:
```
chore: bump modernc.org/sqlite to v1.40.0
chore: pin CI runner to ubuntu-24.04
chore: correct typo in HOMEBASE-SOP-005 changelog section
```

A `chore:` commit that *does* reference an issue must still use a valid trailer (the exemption is from needing a reference, not from using a valid form when one is present).

**Issue-bearing chores transition Linear like any other work** (HMB-103). `homebase work start KEY --kind chore` moves the issue Backlog → In Progress, and `homebase work finish` moves it In Progress → Done — the chore fast-path only skips the Linear gates for *issue-less* chores (`homebase work chore "<desc>"`). If a finished chore-with-issue is ever left stranded "In Progress" (the pre-HMB-103 bug), `homebase work rescue` reports stuck issues across all projects and `homebase work rescue <KEY>… --apply` (or `--all --apply`) transitions them to Done.

---

## Appendix

### Prohibited Practices

| Practice | Why |
|---|---|
| `git push --force` to `main` | Destroys history |
| `git commit --amend` on published commits | Rewrites shared history |
| Feature/bug commits without issue references | Breaks traceability |
| `feat(<app>):` / `fix(<app>):` commits that don't update the app CHANGELOG | Defers the work to release time, by which point the context is gone (B4) |
| Parenthetical `(#N)` in summary as "closing keyword" | Does NOT auto-close |
| Giant commits mixing unrelated changes | Blocks review and bisect |
| `WIP` commits on `main` | `main` is the release branch |
| Writing code before creating the issue | Breaks traceability; work becomes invisible |
| `--no-verify` / `-n` to skip commit-msg hook | Bypasses the validator that enforces this SOP |

### Co-Authored-By Convention

When a Claude agent and a human collaborate, include:

```
Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>
```

(Update the model name if the project uses a different Claude model.)

### Why `--body-file` for Issue Creation

| Pattern | Problem |
|---|---|
| `--body "$(cat <<'EOF' ... EOF)"` | `$()` triggers security prompts in Claude Code |
| `--body "inline text"` | Breaks on multi-line bodies |
| **`--body-file /tmp/issue-body.md`** | No command substitution; works with any body length |
