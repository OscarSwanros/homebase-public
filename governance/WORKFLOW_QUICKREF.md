# Workflow Quick Reference (agents)

**Audience**: every agent in `~/code/homebase/agents/`. Auto-loaded via the `@`-ref chain through `AGENT_OPERATING_CONTRACT.md`.

This is the *practical* recipe for participating in the workflow. The 10 rules in the operating contract tell you **what** to do; this doc tells you **how** to do it for the common scenarios. For mechanical depth, read `@~/code/homebase/standards/WORKFLOW_CONTRACT.md`.

---

## The 30-second model

| Substrate | Where | Your interaction |
|---|---|---|
| Contract | `<project>/.homebase/workflow.yml` | Read it; it declares which gates apply to which app. |
| CLI | `homebase work {start, checkpoint, finish, status, cancel, resume, init, ship}` | The only legal mutation surface. Use it. |
| Generation | `homebase render-claudemd <project>` | Run after editing workflow.yml. CI's drift check fails the PR otherwise. |
| Gates | 5 layers (PreToolUse / git hooks / session lifecycle / `finish` itself / CI) | Block deviation. When one fires, its message names the fix — apply the fix; do not work around it. |

---

## Standard agent flow — operator asks you to do work

When the operator says "let's work on issue X" / "fix bug Y" / "add feature Z":

```
# 1. See if a work-state already exists from a prior session.
homebase work status

# 2. If none, resolve the issue.
#    - If the operator named a key (TBL-42, TFD-99, HMB-12), use that.
#    - If the work needs an issue and none exists, file it: use
#      `homebase work chore "<desc>"` for governance / canon / SOP edits
#      that don't need a Linear issue (HMB-86), OR delegate to
#      technical-project-manager to create a Linear issue with
#      `## Acceptance Criteria` for tracked product work.
#      Don't ask the operator — see AGENT_OPERATING_CONTRACT.md rule 14
#      ("File it, don't list it").

# 3. Start the work-state. Linear mutation needs LINEAR_TPM_AUTHORIZED=1
#    (TPM agent's authority). Per Charter §Yellow-list, this is implicit
#    confirmation under an approved plan.
env LINEAR_TPM_AUTHORIZED=1 homebase work start TBL-42

# 4. If the project opts into worktree mode (project.yml has
#    `worktree.enabled: true`, e.g. field-suite + homebase as of
#    HMB-27 / contract rule 11), cd into the worktree before any
#    edit. `homebase work start` prints the cd hint at the bottom of
#    its output; this is the equivalent shell-friendly form:
cd "$(homebase work goto TBL-42)"

# 5. Authorise this shell for git commits/pushes.
#    For an operator at a terminal: just `source .homebase/.work-env`.
#    For an agent (per-process Bash tool): use `env HOMEBASE_WORK_AUTHORIZED=1` 
#    prefix on each git command, since env doesn't propagate between calls.

# 6. Make changes. Commit normally:
git add path/to/changes
env HOMEBASE_WORK_AUTHORIZED=1 git commit -m "feat(scope): subject

body explaining the change.

Refs TBL-42

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
"

# 7. Optional mid-flight signal (records progress; doesn't end work).
homebase work checkpoint --note "data model done"

# 8. Close out — rebases onto main, FF-pushes HEAD:main, deletes branch
#    (origin + local), Linear → Done. No PR. (HMB-22)
#    When run from a worktree, this also runs the project's
#    teardown_command (e.g. bin/rails db:drop) and removes the worktree
#    on success — cd back to the project root after.
#
#    *** Always invoke finish foreground with the harness's max Bash
#        timeout (timeout: 600000). The validate-passes child can run
#        for several minutes; background-mode bashes get reaped silently
#        by the harness and the gate flow dies mid-suite without an
#        exit line. Same rule for `work checkpoint`, `work ship`, and
#        `roadmap bootstrap`. (Finding 1, HMB-45)
env LINEAR_TPM_AUTHORIZED=1 HOMEBASE_WORK_AUTHORIZED=1 \
  homebase work finish --append-closing
```

`--append-closing` auto-creates the empty `Closes <KEY>` commit if HEAD lacks the closing keyword. It also re-evaluates gate 5 every run (regardless of memoised state), so it's safe to leave on across iterative finish attempts — even when an amended commit on the branch has dropped the closing keyword from HEAD after a prior partial finish.

Direct-to-main is the only finish path (HMB-22); the legacy `--no-pr` and `--ship` flags are deprecated no-ops kept for back-compat. If the rebase onto `origin/main` conflicts, finish aborts cleanly: resolve manually with `git rebase origin/main`, then rerun.

---

## Common scenarios

### Standard feature work (Linear-tracked)

The flow above. Five commands; `homebase work` does the rest.

### Off-contract work (typo, governance edit, README)

When the change genuinely doesn't need a Linear issue, the canonical path is the chore-verb (HMB-86). It mints a chore-flavoured worktree, writes a `kind: chore` work-state with `issue: null`, and lets `homebase work finish` tear down the worktree on success without a Linear move:

```
homebase work chore "fix typo in SOP-001"
cd $(homebase work goto chore/fix-typo-in-sop-001)   # or follow the cd hint
source .homebase/.work-env
git add path/...
git commit -m "chore: fix typo in SOP-001"
homebase work finish
```

The verb derives a kebab-case slug from `"<desc>"` (40-char cap), creates branch `chore/<slug>` and worktree `.worktrees/chore-<slug>/` from the project's base branch.

#### Direct-to-main chore fallback (`HOMEBASE_OFF_CONTRACT=1`)

The escape hatch from `AGENT_OPERATING_CONTRACT.md` rule 6 — reserved for the **unfixable cases** (debugging the chore verb itself, fixing a worktree-creation bug, post-incident hot patches). For everyday governance edits, use the verb above:

```
env HOMEBASE_OFF_CONTRACT=1 git add path/...
env HOMEBASE_OFF_CONTRACT=1 git commit -m "chore: fix typo in SOP-001"
env HOMEBASE_OFF_CONTRACT=1 git push origin main
```

`HOMEBASE_OFF_CONTRACT=1` authorises both the commits *and* the push — set it once and carry it through every step; don't swap to `HOMEBASE_WORK_AUTHORIZED` for the push (that env var is the work-flow's own, written by `homebase work start`).

`work-cli-guard-hook.sh` (HMB-86 B.4) denies bare-chore direct-to-main commits in worktree-enabled projects when `HOMEBASE_OFF_CONTRACT=1` is unset — the deny message names the chore-verb as the intended path. The `chore:` subject prefix remains the conventional-commit type exempt from the issue-trailer requirement (matches `commit-sop-check.sh` exempt set: `chore:`, `Release `, `Post-release:`, `Merge `). `docs:` and `style:` still need an issue.

### SSH push fails with banner timeout / connection-reset (transport fallback)

If `git push` to `origin` fails with `Connection closed by <ip> port 22`, `kex_exchange_identification: read: Connection reset by peer`, `Connection timed out during banner exchange`, or any banner-stage SSH error, the operator's current network is blocking egress to `ssh.github.com` (port 22 *and* often port 443). HTTPS to `api.github.com` and `github.com` is almost always still reachable on the same network.

**Switch transport for the one-shot push without asking** — this is Charter green-list. Use the HTTPS URL form per-invocation; don't rewrite `remote.origin.url`, because SSH works on every other network and `git@github.com:...` is the steady-state.

```
env HOMEBASE_OFF_CONTRACT=1 git push https://github.com/<owner>/<repo>.git <branch>
```

osxkeychain (the default credential helper on macOS) usually has a cached GitHub token from a prior `gh auth login`, so this push will not prompt. If it *does* prompt for a username/password (no cached token), **then** stop and ask — HTTPS credential setup is operator territory.

This is the ad-hoc-push analog of the HMB-54 finish-gate fallback in `scripts/work/lib/gates.sh` (gate 11 automatically switches `git` → `gh api` when transport breaks). For pushes outside `homebase work finish`, the HTTPS-URL form above is the manual equivalent.

### Release

```
env LINEAR_TPM_AUTHORIZED=1 homebase work ship studio-web 1.4.2
```

For a web app with a `deploy:` block: dispatches to `homebase deploy` (Charter red-list — needs `HOMEBASE_DEPLOY_CONFIRMED=1`). For mobile apps: prints the SOP-005 phase guide. Always closes the matching Linear Milestone.

### Hotfix (P0 only)

Confirm the four-point gate first (P0 severity, reachable in production, no safe wait, operator confirmed). Then:

```
env HOMEBASE_HOTFIX_AUTHORIZED=1 LINEAR_TPM_AUTHORIZED=1 \
  homebase work start --hotfix TBL-99
```

Skips three gates that don't apply (changelog, in-progress check, PR). Branches from the latest tag instead of `main`. Otherwise normal finish.

### Recovery (start was skipped, or session crashed)

If you find yourself with commits referencing an issue but no `.homebase/work-state.json`:

```
env LINEAR_TPM_AUTHORIZED=1 homebase work resume TBL-42
```

Rebuilds work-state from observed reality (current branch + Linear read + commits referencing the key). Then you can `finish` normally.

### Workflow contract evolution (changing gates / agents / checks)

```
$EDITOR <project>/.homebase/workflow.yml
homebase render-claudemd <project>
```

Then commit both `workflow.yml` and the rendered `CLAUDE.md`. The drift CI fails the PR if you commit one without the other.

---

## Common gate failures and fixes

| Gate | When it fails | Fix |
|---|---|---|
| `preflight` (gate 0) | A toolchain prerequisite is missing for one of the project's `domains:` (xcode-select pointing at CLT instead of Xcode.app, ANDROID_HOME unset, JDK missing, bundle install pending) | The gate's failure message names each missing prereq + the exact remediation. Apply, rerun. Bypass with `HOMEBASE_SKIP_PREFLIGHT=1` (Charter operator-override only — finishes still walk gate 8 which will catch the same gap, just slower). |
| `state-loaded` | No `.homebase/work-state.json` | Run `homebase work start <KEY>` first, or `homebase work resume <KEY>` to rebuild |
| `tree-clean` | Uncommitted changes | Stage and commit (with `Refs <KEY>` trailer), or `git stash` deferral work |
| `commits-present` | Empty commit range — base SHA == HEAD; `git rev-list <base>..HEAD --count` returned 0 | You committed on a different branch (probably main, or a different repo entirely). `git log --all --oneline <base>..` finds the orphaned commits. Cherry-pick onto the active branch, then re-run finish. The wrong-branch commit-policy gate (HMB-45 F8) prevents this prospectively; finishing without it relies on this gate as the safety net. (HMB-45 Finding 9.) |
| `commits-trailered` | A commit on the branch lacks a trailer | `git rebase -i origin/main` (with `HOMEBASE_WORK_AUTHORIZED=1`) to amend the commit |
| `closing-keyword-present` | HEAD has `Refs` not `Closes`/`Fixes` | Re-run `finish --append-closing`, or manually `git commit --allow-empty -m "Closes <KEY>"` |
| `changelog-current` | `feat(app):` / `fix(app):` commit didn't stage `apps/<app>/CHANGELOG.md` | Edit the changelog, `git add`, amend (or follow-up commit) |
| `linear-in-progress` | Linear says the issue is in `Backlog` / `Done` / etc. | Check the issue manually; may have been moved out-of-band by the integration |
| `validate-passes` | A required check failed | Look at `.homebase/work-finish-*.log` for the actual test failure; fix and re-run. If the failure exists on `main` and your branch didn't introduce it, see SOP-001 §B5 — `<project>/.homebase/known_main_failures.yml` allowlist with tracking issue + expiry can demote it to a warning. (HMB-45 F3.) |
| `validate-passes` (silent death — no `[fail]` line, no `finish_outcome` written) | Backgrounded `homebase work finish` invocation; harness reaped the long-running child mid-suite | Re-invoke `homebase work finish` **foreground** with `timeout: 600000`. Never run `work finish | checkpoint | ship` or `roadmap bootstrap` via background-mode Bash. (Finding 1, HMB-45) |
| `ui-verified` | A UI commit lacks the `Verified ...` trailer | Render the change in browser/simulator, capture observation, amend with the trailer |
| `ui-verified` (you swear the trailer is there) | Misspelt prefix, missing colon, leading whitespace / quote, or amended SHA dropped the trailer | The hook is line-anchored (`^Verified in browser:` / `^Verified by XCUITest:` etc., case-insensitive). Body-line placement and trailer-block placement BOTH pass — placement is not the bug. Re-check the prefix spelling, the colon, that the line isn't indented or quoted, and that the SHA being checked actually carries the trailer (`git log -1 --format=%B HEAD`). (HMB-45 Finding 5 reproduction.) |
| `landed-to-main` | Rebase onto `origin/main` failed (conflict) | Finish auto-aborts the rebase. Resolve manually with `git rebase origin/main`, leave the branch where it is, rerun finish. |
| `landed-to-main` | FF push to `main` failed | `origin/main` moved during the rebase. `git fetch origin main` then rerun finish. |
| `linear-transitioned` | Linear move failed | Verify `LINEAR_TPM_AUTHORIZED=1` is set; check the state-name configured in workflow.yml exists in the team |

The gate's failure message names the exact remediation. **Apply the named fix; do not bypass the gate.**

---

## Authorization quick reference

These env vars unlock different surfaces. Each has one source of truth:

| Env var | Set by | Unlocks |
|---|---|---|
| `HOMEBASE_WORK_AUTHORIZED=1` | `homebase work start` (writes `.homebase/.work-env`) | `git commit` / `git push` for the active work-state |
| `HOMEBASE_OFF_CONTRACT=1` | Operator (in shell, on demand) | Off-contract chore work without `chore:` prefix; also authorises `git push` for the same off-contract commits (HMB-18). Force-push to protected refs still requires `HOMEBASE_FORCE_PUSH_CONFIRMED=1` regardless. |
| `TPM_AUTHORIZED=1` | TPM agent (sole authority for `gh` CLI) | Direct `gh api` access |
| `LINEAR_TPM_AUTHORIZED=1` | TPM agent (sole authority for Linear API) | Linear mutations + `homebase work {start, checkpoint, finish, ship}` |
| `HOMEBASE_{DEPLOY,FORCE_PUSH,HOTFIX}_CONFIRMED=1` | Operator after explicit confirmation | Charter red-list operations |
| `HOMEBASE_SHIP_CONFIRMED=1` | Operator at terminal only (HMB-69) — **NOT** capturable in `.claude/settings.local.json`'s `env` block | Red-tier `homebase work ship` targets (`appstore`, `playstore-prod`, `mac-appstore`). Yellow-tier targets (`testflight`, `playstore-internal`, `playstore-alpha`) do not require it. Operator-only-at-terminal so the gate forces a deliberate "I am about to submit this to Apple/Google" step each time. `--dry-run` bypasses the gate (preview has no side effects). |
| `XCODEBUILDMCP_AUTHORIZED=1` | Operator (in `.claude/settings.local.json` `env` block + Claude relaunch) | One-off raw `xcodebuild` / `xcrun simctl` / bare `simctl` for cases `xcodebuildmcp` doesn't cover. SOP-015 escape hatch; inline env-var prefix and mid-session `export` do NOT work — must be captured at Claude fork time. |
| `--allow-on-main` (CLI flag, not env) | Operator on the `homebase roadmap render` command line | Override the on-main guard that would otherwise refuse to dirty `registry/ROADMAP.md` + `registry/roadmap-snapshot.yml` while on `main`. Use sparingly; the dirtied files still need a chore commit or `git restore`. (HMB-45 Finding 4) |

If you're not the TPM agent and you need a Linear or `gh` mutation, **delegate to TPM**. Don't try to set the env var yourself.

### Mid-session env-var grant — NOT POSSIBLE

`LINEAR_TPM_AUTHORIZED`, `HOMEBASE_*_AUTHORIZED`, `HOMEBASE_OFF_CONTRACT`, `HOMEBASE_SHIP_CONFIRMED`, and `XCODEBUILDMCP_AUTHORIZED` (when consulted by hooks) are read by the Claude Code parent process at fork time. They cannot be granted mid-session. The following will NOT work:

- `LINEAR_TPM_AUTHORIZED=1 homebase work start KEY-N` (inline prefix on a Bash tool call) — the hook fires *before* the bash subprocess runs.
- `export LINEAR_TPM_AUTHORIZED=1` in a Bash tool call — the export only affects that subshell; it does not propagate up to Claude.
- Editing `.claude/settings.local.json`'s `env` block during the session — Claude reads it at launch.

Two viable fixes (pick one):

- **Relaunch Claude with the var**: `LINEAR_TPM_AUTHORIZED=1 claude` from a terminal where the var is exported. Resume your conversation.
- **Add to `.claude/settings.local.json`'s `env` block, then relaunch**:
  ```json
  { "env": { "LINEAR_TPM_AUTHORIZED": "1" } }
  ```

**Exception**: `HOMEBASE_SHIP_CONFIRMED` (HMB-69) is operator-only at the terminal — only the **Relaunch Claude with the var** path works. It is deliberately NOT honoured when set via `.claude/settings.local.json`'s `env` block, so each store submission requires a fresh terminal confirmation. Use `--dry-run` on `homebase work ship` to preview red-tier ships without setting the var.

The Linear MCP plugin path (`mcp__plugin_linear_linear__*`) is *not* env-var-gated — its create-gate (HMB hard rule 2.1) checks for `## Acceptance Criteria` instead. Routing Linear-touching work through MCP is the most reliable mid-session escape.

(HMB-45 Finding 11. Run `homebase auth status` for self-diagnosis — see below.)

### Self-diagnosis: `homebase auth status`

Read-only verb that prints which auth env vars are visible to the hook process itself, plus whether the Linear MCP plugin is permissioned in this session's settings. No auth required; safe to run anywhere.

```sh
homebase auth status
```

Sample output (LINEAR_TPM_AUTHORIZED unset, MCP enabled):

```
homebase auth status
====================

Env vars visible to this process (= what the hook sees at PreToolUse time):

  LINEAR_TPM_AUTHORIZED            = unset
  TPM_AUTHORIZED                   = unset
  HOMEBASE_WORK_AUTHORIZED         = unset
  HOMEBASE_OFF_CONTRACT            = unset
  …
  LINEAR_MCP_PLUGIN                = permissioned in config (~/.claude/settings.json)

Note: LINEAR_TPM_AUTHORIZED is unset. CLI verbs that mutate Linear …
```

When the var is set, the Note section is suppressed. Use the verb whenever a hook denies an operation despite your intuition that the var "should be set" — the hook's view of the env is the only one that matters.

---

## Linear access patterns

The Linear MCP plugin is **deferred-loaded**. `claude mcp list` showing `plugin:linear:linear ✓ Connected` proves the server is reachable; it does *not* mean the tools (`mcp__plugin_linear_linear__get_issue`, etc.) are pre-surfaced into the agent's tool inventory. A fresh session that reads "no Linear tools available" and gives up has misdiagnosed — the tools just need loading.

Two paths, in order of preference:

**1. ToolSearch (preferred for any non-trivial Linear work).**

```
ToolSearch query="select:mcp__plugin_linear_linear__get_issue,mcp__plugin_linear_linear__list_issues,mcp__plugin_linear_linear__list_issue_statuses"
```

After the call returns, those tools are callable like any other. Read-only verbs (`get_issue`, `list_issues`, `list_projects`, etc.) need no authorization; mutations (`save_issue`, `save_project`) still go through TPM with `LINEAR_TPM_AUTHORIZED=1`.

**2. In-tree Ruby script (read-only quick lookups).**

```sh
# Get one issue (no auth needed)
ruby ~/code/homebase/scripts/roadmap/linear.rb issue get TBL-157

# List the team's state names + ids (no auth needed)
ruby ~/code/homebase/scripts/roadmap/linear.rb issue states TBL

# Move issue state (TPM-only)
LINEAR_TPM_AUTHORIZED=1 ruby ~/code/homebase/scripts/roadmap/linear.rb issue move TBL-157 Done
```

The Ruby fallback is faster than ToolSearch for one-off lookups (no schema-loading round trip) and works without surfacing tools into the agent's inventory. Use it for "fetch this issue's title/state/labels and decide" loops; switch to ToolSearch when you need richer data (comments, attachments, child issues) or batch operations.

`homebase roadmap render|audit|portfolio|org|team|project` are also read-only and work without authorization — use those for workspace-wide queries instead of one-issue-at-a-time loops.

### Linear state-name footguns

The Linear MCP plugin (`mcp__plugin_linear_linear__save_issue`) resolves the `state:` field by name across the full set of workflow states for the issue's team. **Resolution is order-sensitive within a single `statusType`**: when a team defines two states sharing the same `statusType` (e.g. HMB has both `Canceled` *and* `Duplicate`, both `statusType: canceled`), `save_issue` with `state: "Canceled"` may silently land on `Duplicate` instead. The API returns 200 and the response payload reports `status: "Duplicate"` — the only signal is reading the response carefully.

**Workaround**: when transitioning to a state that shares a `statusType` with another state on the same team, pass the state UUID directly instead of the literal name string. For HMB, the canonical IDs are:

| State | UUID |
|---|---|
| `Canceled` (HMB) | `00000000-0000-0000-0000-000000000000` _(replace with your workspace's state UUID)_ |

Other teams (TBL, TFD) currently have only one state per `statusType` and aren't exposed to this footgun. The workaround applies team-by-team: list states with `ruby ~/code/homebase/scripts/roadmap/linear.rb issue states <KEY>` (read-only, no auth) before a `Canceled` transition on a new team.

**Homebase's own resolver is not vulnerable.** `scripts/roadmap/linear.rb cmd_issue_move` and `scripts/work/lib/linear-bridge.sh linear_resolve_state_for_kind` perform exact-name matching against the live team states (`die`s if no match), so `homebase work cancel` and `homebase roadmap` verbs land on the correct state regardless of order. Only the MCP plugin's `save_issue` is affected. (HMB-45 Finding 10; reproduced live during the HMB-47/48/49 consolidation cycle.)

---

## Per-process shell (agents only)

When you spawn one process per Bash invocation (Claude Code's Bash tool, CI runners), the environment doesn't propagate across calls. Sourcing `.homebase/.work-env` in one Bash call doesn't survive to the next.

**Use `env VAR=1 cmd` per command instead:**

```
env LINEAR_TPM_AUTHORIZED=1 homebase work start TBL-42
env HOMEBASE_WORK_AUTHORIZED=1 git commit -m "..."
env LINEAR_TPM_AUTHORIZED=1 HOMEBASE_WORK_AUTHORIZED=1 homebase work finish --append-closing
```

The env-file is for operators at a terminal (one shell, source once).

### Foreground only for long-running work verbs

`homebase work finish`, `homebase work checkpoint`, `homebase work ship`, and `homebase roadmap bootstrap` invoke gate flows that can take several minutes (validate-passes runs the project's full test suite). **Always invoke them foreground** with the harness's max Bash timeout (`timeout: 600000`). Background-mode Bash invocations (`run_in_background: true`) get reaped silently by the Claude Code harness when their stdout idles past an internal threshold — the validate-passes child dies mid-suite, no `[fail]` line is written to the gate log, no `finish_outcome` is recorded in `.homebase/work-state.json`. The foreground 10-minute invocation completes cleanly; the backgrounded one disappears. (Finding 1, HMB-45)

---

## Parallel work — multiple agents in different terminals

The contract supports three concurrency patterns. Work-state files are stored at the **main checkout's `.homebase/`** keyed by sha1 of the current worktree's realpath (`work-state.<sha8>.json`, HMB-87 B.11), so per-worktree states coexist without collision and survive `git worktree remove`.

### Mode 1 — Different repos (always safe)

Open one terminal per project, run `homebase work start <KEY>` in each. Work-state, env file, branch, gates: all isolated. No setup. Use this whenever the parallel work is across `~/code/studio`, `~/code/field-suite`, and `~/code/homebase`.

### Mode 2 — Same repo, parallel via per-task worktrees (HMB-27)

Sessions launch in the project's **main checkout** and read freely. The moment you write, `homebase work start <KEY>` (worktree-enabled projects) creates a fresh worktree at `<project>/.worktrees/<branch>/`, symlinks the configured `worktree.share` paths (e.g. `vendor/bundle`, `node_modules`), runs the optional `worktree.setup_command` (e.g. `bin/rails db:create db:migrate db:seed`) against a per-worktree DB suffix (`WORKTREE_DB_SUFFIX=_<key_lowercase>`), and prints the `cd` hint. Per-worktree work-state lives at `<main>/.homebase/work-state.<sha>.json` (SHA-keyed so parallel tasks don't collide); the per-worktree `.work-env` stays inside the worktree's tree. `edit-main-checkout-guard` enforces "no editing main without an active work-state." (Two parallel agents on one repo each `work start` a different KEY → each gets its own worktree.)

```
# Terminal A — SHOPOS work
cd ~/code/field-suite
homebase work start TFD-1372
cd $(homebase work goto TFD-1372)
source .homebase/.work-env

# Terminal B — SiteDB work, in parallel
cd ~/code/field-suite
homebase work start TFD-1380
cd $(homebase work goto TFD-1380)
source .homebase/.work-env

# At any time:
homebase work list
# KEY       BRANCH                                          PATH                                                          LINEAR
# TFD-1372  shopos/1372-record-payment-action          /Users/.../field-suite/.worktrees/shopos/1372-...      In Progress
# TFD-1380  shopos/1380-course-detail-view             /Users/.../field-suite/.worktrees/shopos/1380-...      In Progress
```

`homebase work finish` and `homebase work cancel`, when invoked from inside a worktree, run the project's `worktree.teardown_command` (e.g. `bin/rails db:drop`) and `git worktree remove` on success — the operator just `cd`s back to the project root. The only serialisation point remains the FF-merge to `main`; standard git rebase-on-top-of-origin/main resolves it.

For projects that don't opt into worktree mode (or for older workflows you want to drive manually), the bare-git form still works:

```
cd ~/code/field-suite
git worktree add ../tfd-gascalc-1390 -b gascalc/1390-foo origin/main
cd ../tfd-gascalc-1390
homebase work start TFD-1390
```

### Mode 3 — Same repo, work in the main checkout

Read-only work needs nothing — sessions already launch in main. To make *tracked* edits without a worktree, `homebase work start <KEY> --no-branch` (work-state on the current branch, no worktree created). For off-contract edits to the main checkout (governance/canon, or debugging the tooling itself), `homebase work chore "<desc>"` (a chore worktree) or `HOMEBASE_OFF_CONTRACT=1` for the unfixable cases (rule 6). `edit-main-checkout-guard` denies main-checkout `Edit/Write/MultiEdit/NotebookEdit` when no work-state is active and `HOMEBASE_OFF_CONTRACT=1` is unset.

### Worktree cleanup

Worktrees are created by `homebase work start` / `homebase work chore` and disposed by `homebase work finish` / `cancel` — explicitly, never by a Stop heuristic (the HMB-87 auto-destroy + the `prune-session-worktrees` verb were removed in HMB-98 / HMB-109). A worktree that `finish` retained (finished under a live Claude session, where it can't delete its own CWD) is removed after you cd out:

```
cd <project-root> && git worktree remove --force <path> && git branch -D <branch>
```

`homebase status <project>` surfaces stray / abandoned worktrees with a one-line remediation. Linear issues left "In Progress" after a clean finish are reported — and fixed with `--apply` — by `homebase work rescue` (HMB-103).

### Shared-resource caveats

These limits are global, not per-agent:

- **Linear API rate limit** — 1500 complexity/hour for the workspace. `scripts/roadmap/linear.rb`'s retry-on-RATELIMITED logic handles bursts. Heavy concurrent activity (5+ parallel finishes) might trigger backoff but rarely failure.
- **GitHub API rate limit** — 5000 req/hr. Each finish hits gh once for PR create / edit. Far from the ceiling unless dozens of PRs are flying.
- **Xcode simulator contention** — two parallel `fastlane test platform:ios` runs spawn separate sims; usually allocates by name, but can fail with "simulator already booted" if both target the same device. Override per-worktree: `env SCAN_DEVICE="iPhone 17 Pro" homebase work finish ...`.
- **Gradle daemon** — gradle serializes builds at the daemon. Two parallel `gradlew test` calls queue. Fine, just slow.
- **mise per-terminal** — `eval "$(mise activate zsh)"` in `~/.zshrc` runs separately per shell. mise's `cd` hook applies the right `.mise.toml` for each terminal's working directory. No collision.

### When to use which mode

| Pattern | Mode | Why |
|---|---|---|
| Working on TFD + Studio + homebase together | 1 | Different repos, fully independent |
| Two TFD apps (GasCalc + LogApp) in parallel | 2 | Same monorepo; worktrees keep state isolated |
| Two TFD changes on the same app | 2 (separate worktrees per change) | Each issue gets its own worktree |
| Two changes on the same GasCalc screen | 2 if logically independent; otherwise serialise | Worktrees are the right call when the changes don't depend on each other; when they do, do them sequentially |
| Multiple Claude Code windows on one app, no worktree | 3 (won't work) | The contract refuses. Open a worktree. |

## Hook reasons → CLI verbs

When a PreToolUse hook blocks you, its `reason` string names the verb to use instead. A few common ones:

- "Manual `git commit` is forbidden inside an active work-state" → use `homebase work checkpoint` (or `homebase work finish`)
- "Manual `git push` is forbidden" → use `homebase work checkpoint --push` or `homebase work finish`
- "Direct `gh` CLI usage is prohibited" → delegate to `technical-project-manager`
- "Direct Linear API usage is prohibited" → delegate to `technical-project-manager`
- "Production deploy is a Charter red-list operation" → ask operator for `HOMEBASE_DEPLOY_CONFIRMED=1`
- "looks like product work but no `.homebase/work-state.json` exists" → `homebase work start <KEY>` first, or `chore:` prefix, or `HOMEBASE_OFF_CONTRACT=1`

---

## When to read which doc

| Question | Doc |
|---|---|
| What rules apply to me as an agent? | `@~/code/homebase/governance/AGENT_OPERATING_CONTRACT.md` (10 rules) |
| How do I actually run the workflow? | This file. |
| What does each gate do? Why? | `@~/code/homebase/standards/WORKFLOW_CONTRACT.md` |
| When do I act vs. confirm? | `@~/code/homebase/governance/AUTONOMY_CHARTER.md` |
| Why is this rule the way it is? | The relevant `sops/HOMEBASE-SOP-*.md` (each marked "explanation, not control flow") |
| What's the contract for project X? | `<project>/.homebase/workflow.yml` |
| What apps does project X have? | `<project>/.homebase/project.yml` |
| What checks run for app Y? | `apps[Y].required_checks` in workflow.yml, OR the rendered table in `<project>/CLAUDE.md` |
| Who's the gatekeeper for Z? | `gh` → TPM (SOP-002). Linear → TPM (SOP-013). |

---

## What you do NOT do

- **Do not paraphrase the contract.** Read it. The CLI enforces it.
- **Do not skip `homebase work start`** for product work. The hooks will catch you anyway, just less informatively.
- **Do not bypass a failing gate.** The gate's reason names the fix.
- **Do not write "Required follow-ups" lists** for green-list work. That's a deferral defect (see `AUTONOMY_CHARTER.md` §"Required follow-ups").
- **Do not re-ask permission after a plan is approved.** The instant a plan is approved at exit-plan-mode, your first message is execution or a status update — never "Want me to start?" / "Should I…?" / "or do you want to drive…?". The plan is the confirmation for every green/yellow step in it; delegating to TPM is not a separate confirmation (`AGENT_OPERATING_CONTRACT.md` Rules 8, 13, 15). The `PostToolUse:ExitPlanMode` reminder hook (HMB-105) re-injects this at approval time, but the rule holds with or without it.
- **Do not call `gh` or the Linear API directly.** Delegate to `technical-project-manager`.
- **Do not edit between marker pairs in CLAUDE.md.** Edit `workflow.yml` and run `render-claudemd`.
- **Do not phase-delegate UI-touching work without the SOP-007 step in the phase brief.** When you split a feature into phases and hand each phase to an architect agent (`rails-architect`, `swift-architect`, `web-frontend-architect`, `kotlin-systems-architect`, `ui-ux-designer`, etc.), any phase that touches a view / template / component / screen MUST include the render-and-observe step in the brief: render via Chrome MCP (web) or simulator/XCUITest (Apple/Android), capture a one-sentence observation, append the `Verified ...` trailer **before committing**. The architect won't add it unprompted. Verification at commit-time costs ~2 minutes; verification at finish-time (when the SOP-007 gate blocks the merge) costs ~30 minutes of dev-server spin-up + scenario seeding + non-interactive rebase. See `@~/code/homebase/sops/HOMEBASE-SOP-007-UI_VERIFICATION.md`.

---

## Cross-references

- `@~/code/homebase/governance/AGENT_OPERATING_CONTRACT.md` — the 10 rules.
- `@~/code/homebase/governance/AUTONOMY_CHARTER.md` — green / yellow / red list.
- `@~/code/homebase/standards/WORKFLOW_CONTRACT.md` — full contract reference.
- `@~/code/homebase/governance/HARD_RULES.yml` — slug → rule registry.
- `@~/code/homebase/schemas/workflow.schema.json` — schema for `<project>/.homebase/workflow.yml`.
- Skills: `/new-issue`, `/finish-work`, `/release`, `/hotfix` — each wraps a `homebase work` verb.
