# Inverted Swiss Cheese — Risk Management in Homebase

Reference material for how homebase prevents agents (and tired operators) from doing the wrong thing. Read this when you want to understand *why* the contract is structured the way it is. The control flow itself lives in `standards/WORKFLOW_CONTRACT.md` + each project's `.homebase/workflow.yml` + the hooks under `scripts/hooks/`; this doc explains the spine.

Promoted into the governance set on 2026-05-19 after the HMB-85 + HMB-86 + HMB-87 + TBL-536 + HMB-88 + HMB-89 + HMB-90 track sealed the last loose edges. See the "Track-of-record" footer for which issue materialized which slice.

## Context — why this artifact exists

the operator runs a single-operator software company (`homebase` = HQ; projects = engagements; agents = staff; SOPs = handbook). Most of the actual coding is done by Claude. The risk that matters is not "a bad actor" — it's **drift**: an agent (or the operator at 1 am) doing something plausible-but-wrong, and that mistake reaching `main`, a release, or production before anyone notices. Homebase is the machinery that makes that structurally hard.

---

## The spine metaphor: Swiss cheese, inverted

**James Reason's classic model:** defence layers are cheese slices. Holes are latent weaknesses. They drift independently. An accident happens when a hazard finds a moment where holes in *every* layer line up. It is a **default-allow** world — the hazard travels freely until a layer happens to stop it; safety is the *improbability* of total alignment.

**Homebase inverts it.** The slices are **solid by default — default-deny**. Nothing reaches `main` unless it is *explicitly permitted* at every layer. The "holes" are not accidental weaknesses that drift open — they are **deliberately cut, well-lit, logged doorways**: the one sanctioned path through each slice. You do not *slip* through homebase. You *walk* through it, and every door records that you did.

Three consequences of the inversion — these are the thesis:

1. **A "hole" is now a feature, not a flaw.** The doorways are named: the `homebase work` CLI verbs (`start`, `chore`, `checkpoint`, `finish`, `cancel`, `resume`) are the legal mutation paths. Escape-hatch env vars (`LINEAR_TPM_AUTHORIZED=1`, `TPM_AUTHORIZED=1`, `HOMEBASE_OFF_CONTRACT=1`, `HOMEBASE_DEPLOY_CONFIRMED=1`, `HOMEBASE_FORCE_PUSH_CONFIRMED=1`, `HOMEBASE_HOTFIX_AUTHORIZED=1`, `HOMEBASE_SHIP_CONFIRMED=1`) are the explicit, audited exceptions. An exception is *visible*, never silent.

2. **The doorways can't drift apart.** Classic Swiss cheese fails because holes grow independently per layer. Homebase single-sources the validation logic — `scripts/lib/issue-trailer.sh`, `scripts/lib/ac-regex.sh`, `scripts/hooks/ui-pattern.sh` are each *one regex file* sourced by the Claude hook, the git hook, the finish gate, and CI. Every layer's doorway is cut from the same stencil. A trajectory that passes one layer's check passes all of them; one that fails, fails identically everywhere. The classic failure mode is designed out.

3. **The further a mistake travels, the less Claude can touch the slice.** The layers are caller-invariant in increasing degree — ending in CI, which runs on GitHub's runners on a clean checkout. The last slice is *outside the machine Claude runs on*.

---

## The five slices (layers of enforcement)

Ordered by when they catch a mistake — earliest first.

### Slice 1 — Claude PreToolUse hooks (block the *intent*)

Fire before any Bash / Linear-MCP / Edit call even runs. Wired in `.claude/settings.json` (`hooks.PreToolUse`).

- `claude-precommit.sh` — blocks `git commit --no-verify` / `-n` (hard rule 3); self-heals `core.hooksPath`; blocks committing third-party `AGENTS.md`.
- `gh-cli-guard-hook.sh` — `gh` denied unless `TPM_AUTHORIZED=1` (rate-limit discipline, SOP-002).
- `linear-cli-guard-hook.sh` — Linear API denied unless `LINEAR_TPM_AUTHORIZED=1`; **also** an issue-create gate: no `## Acceptance Criteria` + `- [ ]` checkbox → no new issue (hard rule 2.1, the create-gate reuses the same regex as the `homebase work start` start-gate via `scripts/lib/ac-regex.sh` — single-stencil discipline).
- `xcodebuild-cli-guard-hook.sh` — raw `xcodebuild` / `simctl` denied; must go through `xcodebuildmcp` (SOP-015 / HMB-60 / hard rule 17).
- `work-cli-guard-hook.sh` — manual `git commit` / `push` / `tag` / `rebase` / branch-delete blocked when a work-state is active; bare `chore:`-prefix commits blocked in worktree-mode projects unless `HOMEBASE_OFF_CONTRACT=1` (HMB-86); `homebase deploy` blocked without `HOMEBASE_DEPLOY_CONFIRMED=1` (Charter red-list).
- `edit-main-checkout-guard.sh` — **HMB-87 B.10**: the **primary** "isolate writes from main" enforcer post-Tier-2 (HMB-98 removed the session-spawn wrapper that used to make this belt-and-suspenders). Denies `Edit` / `Write` / `MultiEdit` / `NotebookEdit` against files in a worktree-enabled project's main checkout when no active work-state exists for the current cwd AND `HOMEBASE_OFF_CONTRACT=1` is unset. This is what makes "read in main, dispatch to a worktree to write" hold.

**Why it works:** denial is JSON `{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"..."}}` — no silent failure, the reason names the fix. Catches the mistake before it has consequences.

### Slice 0 — Session-spawn wrapper — **REMOVED (HMB-98, Tier-2 simplification, 2026-05-20)**

> **Superseded.** This slice (HMB-87 B.12 auto-spawn) auto-minted a
> session-worktree on *every* `claude` invocation and auto-destroyed "empty"
> ones via a Stop-hook heuristic. Its failure modes — destroying worktrees
> under live sessions, vanishing the CWD mid-command, keying transcripts to
> ephemeral paths, and launching sessions in a bare worktree that never
> inherited the operator's `.claude/settings.local.json` env — cost far more
> than the rare, recoverable parallel-agent collision it prevented (three CWD
> destructions in a single planning session prompted the removal).
> `bin/homebase-claude` is now a pass-through; `homebase bootstrap` uninstalls
> the `claude()` shell function; `session-end-cleanup.sh` is a documented no-op.

**Replacement model (simple, deterministic).** Sessions launch in the project's
**main checkout** and read freely there, inheriting main's env at fork (no
propagation, no relaunch). The moment the agent **writes**, `homebase work start
<KEY>` (or `homebase work chore "<desc>"`) creates a per-task worktree and the
agent `cd`s into it. Worktrees are born by an **explicit verb** and destroyed
only by explicit `homebase work finish` / `cancel` — never by a heuristic Stop
hook. The "isolate writes from main" property that Slice 0 over-engineered is
now enforced by **Slice 1's `edit-main-checkout-guard`** alone: no editing the
main checkout without an active work-state. Parallel same-repo work still falls
out naturally — two agents each `work start` a different KEY, each gets its own
worktree (SHA-keyed central state, HMB-87 B.11, retained), no collision.

### Slice 2 — Local git hooks (block the *git operation*, caller-invariant)

Wired via `core.hooksPath=.githooks` (auto-healed by `claude-precommit.sh` on every commit). A `subprocess.run(['git', ...])` cannot dodge these.

- `pre-commit` — registry-drift check (homebase); **work-state coherence**: current branch must match `work-state.branch`, staged files must stay inside the active app's path (catches edits landing in the wrong app's tree; cross-app entanglement); legacy single-file `work-state.json` is auto-migrated to HMB-87 B.11's SHA-keyed central form on first read.
- `commit-msg` → `commit-sop-check.sh` — the **single source of truth** for commit policy: canonical trailer keywords only (`Refs` / `Closes` / `Fixes` / `Resolves`), anti-patterns ("Part of", "See", "Related to" …) rejected, issue reference required, wrong-branch commits refused, warn-only UI-verification nudge.
- `commit-msg` → `commit-changelog-check.sh` — `feat/fix` commits must stage the app's CHANGELOG or carry an audited `Changelog skipped:` trailer.
- `pre-push` — push blocked without `HOMEBASE_WORK_AUTHORIZED=1` or `HOMEBASE_OFF_CONTRACT=1`; force-push to `main` / tags blocked without `HOMEBASE_FORCE_PUSH_CONFIRMED=1`; on a finish-push, HEAD must carry a closing keyword.

**Why it works:** invariant to *who* calls git. Slice 1 guards Claude's intent; Slice 2 guards the operation itself.

### Slice 3 — Session-lifecycle hooks (block *loose ends at session boundaries*)

- `session-start.sh` — surfaces uncommitted changes and any active work-state from a prior session via a banner; prunes stale legacy `work-state.json` files older than 14 days (HMB-87 B.11); banners Charter red-list overrides (`HOMEBASE_UI_VERIFICATION=off`).
- `session-end-cleanup.sh` — **HMB-87 B.12** Stop hook: removes empty session-worktrees on Claude exit (zero commits beyond base AND no work-state file). Commit-bearing or state-bearing session-worktrees are preserved — the operator owns finish/cancel/promote on those.
- `task-created.sh` — warns/blocks on tasks that look like tracked work but have no issue.
- `task-completed.sh` / `teammate-idle.sh` — cannot end a session or go idle with a dirty tree, unpushed commits, or an unfinished work-state.
- `ui-verification-check.sh` (Stop hook) — UI-touching commits without a `Verified …` trailer block the Stop in strict mode (SOP-007).

**Why it works:** the expensive failure is *losing context between sessions*. This slice makes "stop" and "done" mean the tree is clean, pushed, and either tracked or torn down — every time.

### Slice 4 — The `homebase work` CLI gates (block *the workflow from completing wrong*)

The only legal mutation surface. Three entry verbs (tracked work, chore work, hotfix work) → one finish.

**Entry verbs:**

- `homebase work start <KEY>` — tracked work. Start gates: tree-clean (skipped in worktree mode per HMB-87 B.9, since the new worktree materialises from `main`'s tip and the current checkout's dirt has zero bearing on cleanliness), on-base-branch (or adopting a session-worktree per HMB-87 B.12), issue exists in Linear with `## Acceptance Criteria`, required labels present.
- `homebase work chore "<desc>"` — **HMB-86**: off-contract chore work (governance, canon, SOP edits, README typos) that legitimately doesn't need a Linear issue. Creates `.worktrees/chore-<slug>/`, writes `kind: chore` / `issue: null` work-state; finish-time skips Linear + closing-keyword gates. The HMB-86 chore-prefix denial in Slice 1's `work-cli-guard-hook.sh` routes agents into this verb when they'd otherwise reach for `HOMEBASE_OFF_CONTRACT=1`.
- `homebase work start --hotfix <KEY>` — P0 only (Charter red-list); requires `HOMEBASE_HOTFIX_AUTHORIZED=1`; branches from latest tag instead of `main`; finish skips changelog, in-progress check, PR.

**Finish gates** (`scripts/work/lib/gates.sh`, ~14 steps): preflight toolchain → state valid → branch on track → tree clean → non-empty commit range → every commit trailered → closing keyword on HEAD → changelog current → Linear in-progress → required checks pass (with an expiring allowlist for inherited main failures) → UI verified (XCUITest gate for Apple) → rebase + FF-push to main + branch cleanup → Linear transitioned → state finalised. For `kind: chore`: skip 6 (closing-keyword), 7 (changelog), 8 (linear-in-progress), 9 (validate), 10 (ui-verified), 13 (linear-transitioned).

**Verbs the slice supports:**

- `homebase work checkpoint` — mid-flight progress signal; optional state move + push.
- `homebase work cancel` — abandon the work-state, tear down the worktree.
- `homebase work resume <KEY>` — recovery; rebuild work-state from current branch + Linear.
- `homebase work list` / `goto` — read-only enumeration / lookup.
- `homebase work rescue [<issue>…] [--apply] [--all]` — **HMB-103**: report (and, with `--apply`, transition) issues left stranded "In Progress" after a clean finish.
- `homebase status <project>` — read-only diagnostic; reports symlink drift, branch protection drift, and **stray worktree advisory** (HMB-88): unowned worktrees with no commits + no state, with a one-line `git worktree remove --force` remediation.

**Why it works:** gates are **memoised and idempotent** — a failed finish records `last_gate_passed`; the operator fixes the one thing and re-runs, picking up where it stopped. First failure **aborts with zero downstream side-effects** (no push, no Linear move). All-or-nothing.

### Slice 5 — CI reusable workflows (block at *merge*, off-machine)

Project `.github/workflows/*.yml` call reusable workflows hosted *in homebase* (`commit-sop-check.yml`, `validate-docs.yml`, `work-finish-validate.yml`, `work-linear-state.yml`, `work-state-integrity.yml`, `render-claudemd-drift.yml`). Clean-logapp replay of the same single-sourced checks on GitHub's runners.

**Why it works:** Claude cannot tamper with it. It re-derives the verdict from scratch. It is the slice that exists *because* you assume the earlier slices might have been bypassed.

---

## The governance spine — SOPs are the stencil, not a slice

The 15 HOMEBASE-SOPs each carry the header **"Status: explanation, not control flow."** They explain *why* a rule exists; they are not themselves enforcement. Control flow lives in `standards/WORKFLOW_CONTRACT.md` + each project's `.homebase/workflow.yml`. `governance/HARD_RULES.yml` is the slug→wording registry; `bin/homebase render-claudemd` stamps it into every project's CLAUDE.md.

`governance/AUTONOMY_CHARTER.md` defines the green/yellow/red lists — when Claude acts vs. reports vs. must confirm.

`governance/AGENT_OPERATING_CONTRACT.md` is the agent-auto-loaded rulebook (every agent's prompt footer references it via `@`-ref). Rules 1–12 codify the structural rules above; **rules 13 + 14 (HMB-85)** codify the *posture*:

- **Rule 13 — Default to action; reserve asks for the red-list.** The Charter's green / yellow → act; red → confirm. Promotes the canon from `AGENT_GUIDE.md` § Execution principle into the contract layer so every agent reads it on every turn. The rule's second paragraph names documented-config edits as red-list (the 2026-05-18 Briefing deploy-wedge failure mode: don't unilaterally rewrite a config that carries operator-authored rationale) and paired-recovery operations as green-list (clearing stale Docker buildx contexts, restarting Docker Desktop, SSH-into-prod state fixes that *don't* modify the documented configuration).
- **Rule 14 — File it, don't list it.** When you identify follow-up work mid-task: (a) in-scope green → do it now; (b) out-of-scope governance / canon / SOP edit → `homebase work chore "<desc>"`; (c) out-of-scope OR red-list code work → delegate to `technical-project-manager` for a Linear issue with `## Acceptance Criteria`. Writing a numbered chore list is a deferral defect.

**Why it works:** separating the *why* (prose, SOPs) from the *how* (contract + CLI + hooks) means the explanation can never silently become the enforcement. And `render-claudemd-drift.yml` fails CI if the rendered rules drift from the YAML — the stencil and the cut stay in sync. The Charter's §Revision homeostasis (HMB-85 A.6) requires that any red-list addition name a paired green-list expansion — preventing the monotonic-tightening regression that produced over-deferral in the first place.

## The distribution model — why the cheese doesn't develop accidental holes

One canonical copy of every shared asset:

- **Symlinked** into each project: agents, skills, hooks (`scripts/hooks/*`), shared libs (`scripts/lib/*`), `.claude/settings.json`, `.githooks/commit-msg`. Single-source `bin/homebase link-project <path>` materialises every link.
- **Referenced by `@`-path** from each project's CLAUDE.md: SOPs, governance docs, standards. Never copied.
- **Sentinel-bracketed shell-function install** in `~/.zshrc` / `~/.bashrc` via `homebase bootstrap` step 9 (HMB-87 B.12). The `claude()` function block is idempotently refreshed on every bootstrap — operator can't accidentally drift it without the next bootstrap noticing.

Edit the canonical file once; every project gets it on the next session. There are no per-project forks to drift. This is the structural answer to classic Swiss cheese's "holes grow independently."

`homebase status <project>` verifies every expected symlink resolves; CI's `homebase status` job re-verifies on every PR. Drift is loud, not silent.

## Worktree strategy — explicit per-task isolation (Tier-2)

**Pre-HMB-87:** each tracked task ran in its own git worktree (`.worktrees/<branch>/`), but the operator had to explicitly invoke `homebase work start <KEY>` first. The window between session-start and that verb being called was a default-allow path — agents could edit `main` in that window.

**HMB-87 (retired):** Slice 0 auto-spawned a session-worktree on *every* `claude` invocation to close that window. It cost more than it saved (see Slice 0 above) and was removed in HMB-98.

**Tier-2 (current):** sessions launch in the project's **main checkout** and read freely; the moment the agent writes, `homebase work start <KEY>` (or `homebase work chore "<desc>"`) creates the per-task worktree and the agent `cd`s in. The "no editing main without a work-state" property is enforced by **Slice 1's `edit-main-checkout-guard`**. SHA-keyed central state (`<main>/.homebase/work-state.<sha8>.json`, HMB-87 B.11) is retained so two parallel agents on one monorepo each hold their own work-state.

Worktrees provide per-task isolation — own filesystem, own per-task database (`WORKTREE_DB_SUFFIX=_<key_lowercase>` for Rails / Go web apps), own `.work-env`, shared (symlinked) caches. `mise trust` is run on creation so toolchain gates don't false-fail. `homebase work resume <KEY>` re-enters it later; `homebase work goto <KEY>` resolves the path.

Lifecycle (Tier-2 — born and disposed by explicit verbs only, never by a Stop heuristic):

- **Created** by `homebase work start <KEY>` / `homebase work chore "<desc>"`.
- **Disposed** by `homebase work finish` / `cancel`. When finish runs from *inside* the worktree under a live Claude session (CLAUDECODE=1), it can't remove its own CWD, so the worktree is retained and finish prints the `git worktree remove` command to run after cd-ing out.
- **Stray worktrees** (under `.worktrees/<branch>/`, abandoned) are surfaced by `homebase status <project>` (HMB-88) with a one-line cleanup remediation.

Cross-brand parity:

| Project | Worktree mode | Notes |
|---|---|---|
| **homebase** | enabled | substrate itself; eats own dog food |
| **studio** | enabled | TBL-536 added the block on 2026-05-19 |
| **field-suite** | enabled | HMB-27 era |

A homebase substrate edit that lands in only some consuming projects is a scoped fix, not a substrate fix — `AUTONOMY_CHARTER.md` §Revision's cross-brand-applicability discipline (HMB-85 A.6) prevents accidental scope creep.

---

## Synthesis — why the inverted model works

**The cost-of-deviation argument.** For a wrong change to reach `main`, it must pass — *deliberately, with knowledge of each escape hatch* — through:

1. A Claude PreToolUse hook (including `edit-main-checkout-guard`, which enforces "no editing main without an active work-state" now that Slice 0 is gone).
2. A caller-invariant git hook.
3. A session-lifecycle gate.
4. The `homebase work` finish sequence.
5. Clean-logapp CI it cannot touch.

Each slice is default-deny. The doorways are single-sourced (identical across slices), named, and logged. **Accidental drift is not improbable — it is structurally impossible**, because there is no default-allow path for it to travel. Intentional deviation is *possible* (the escape hatches exist — this is a single-operator shop, not a prison) but it is *loud*: it requires typing a specific env var, and that env var is visible in shell history, `ps` output, and the commit / state record.

Reason's model asks: *how do we make the holes unlikely to align?* Homebase asks a different question: *what is the exact set of things we want to allow — and how do we make everything else impossible by default?* That is the inversion. Same five-layer picture; opposite polarity.

---

## Suggested presentation order

If you're showing this to someone (talk, onboarding, exec review):

1. The classic Swiss cheese image — Reason's default-allow model.
2. "Now invert it" — default-deny, holes become doorways.
3. The five slices, one per slide, each with its "why it works" line. Slice 0 first chronologically.
4. SOPs-as-stencil + single-sourcing (the no-drift slide).
5. Worktrees = explicit per-task isolation (`work start` creates; explicit verbs dispose).
6. Cost-of-deviation closing slide.

## Verification / dry-run

If you want to demonstrate the model live, three demos cover every slice:

- Walk one real example: `homebase work start HMB-NN` → show a start-gate rejection (e.g. missing acceptance criteria) → fix → show a finish-gate rejection (e.g. missing closing keyword) → `--append-closing` → green. That single demo hits Slices 1, 4, and 2.
- Show a blocked `gh` call without `TPM_AUTHORIZED=1`, then the same call authorised — the "lit doorway" made concrete.
- `git commit --no-verify` getting blocked — the "you cannot remove a slice" point.

---

## Track-of-record

| Slice / section | Materialized by |
|---|---|
| Slice 0 (session-spawn wrapper) + lifecycle | HMB-87 B.12 — **removed HMB-98 (Tier-2)** |
| Slice 0 (per-worktree state) | HMB-87 B.11 (retained) |
| Slice 0 (tree-clean gate relax in worktree mode) | HMB-87 B.9 (retained) |
| Slice 1 — `edit-main-checkout-guard.sh` | HMB-87 B.10 |
| Slice 1 — `work-cli-guard-hook.sh` chore-prefix denial | HMB-86 B.4 |
| Slice 1 — `linear-cli-guard-hook.sh` AC create-gate | HMB-32 / HMB-37 |
| Slice 2 — `commit-sop-check.sh` wrong-branch gate | HMB-45 Finding 8 |
| Slice 3 — `session-end-cleanup.sh` Stop hook | HMB-87 B.12 — **no-op since HMB-98 (Tier-2)** |
| Slice 3 — `session-start.sh` 14-day legacy prune | HMB-87 B.11 |
| Slice 4 — `homebase work chore` verb | HMB-86 B.1 / B.2 / B.3 |
| Slice 4 — start.sh session-worktree adoption | HMB-87 B.12 — **removed HMB-109** |
| Slice 4 — `homebase prune-session-worktrees` verb | HMB-89 — **removed HMB-109** |
| Slice 4 — `homebase work rescue` verb | HMB-103 |
| Slice 4 — `homebase status` stray-worktree advisory | HMB-88 |
| Distribution model — bootstrap step 9 (shell-function install) | HMB-87 B.12 — **now uninstalls the fn, HMB-98** |
| Governance spine — rules 13 + 14 | HMB-85 A.1 / A.2 |
| Governance spine — finish-work closure-audit | HMB-85 A.5 |
| Governance spine — Charter §Revision homeostasis | HMB-85 A.6 |
| Governance spine — `WORKFLOW_QUICKREF.md` rule-14 path | HMB-85 A.7 |
| Worktree cross-brand parity (studio) | TBL-536 |
| Worktree cross-brand parity (field-suite) | HMB-27 |
| Operator escapes — three bypass paths documented | HMB-90 — **moot since HMB-98 (no wrapper to bypass)** |

This table dates the doc and surfaces future drift: if a slice's enforcement changes, the corresponding row should update or move; if a row points at a closed issue whose change has been reverted, the model has drifted from the code.
