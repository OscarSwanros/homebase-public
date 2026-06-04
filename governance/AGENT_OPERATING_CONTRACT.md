# Agent Operating Contract

**Status**: canonical (Phase 0)
**Owner**: `technical-project-manager`
**Applies to**: every agent in `~/code/homebase/agents/`, in every project that consumes homebase

**Auto-loaded with this contract**: `@~/code/homebase/governance/WORKFLOW_QUICKREF.md` — practical agent recipe for the common scenarios (start / checkpoint / finish, off-contract, release, hotfix, recovery), gate-failure fixes, and authorisation matrix. Read it once; reach for it when the rules below tell you to "run `homebase work`" but you need the exact command sequence.

---

## The contract

These rules define how every agent participates in the workflow. They replace the per-agent "Mandatory SOPs" sections that used to live in each agent prompt. SOPs remain as reference material — they explain *why* the rules exist; this contract is *what* the agent does.

1. **Workflow goes through `homebase work`.** Manual `git commit`, `git push`, `gh pr create`, and direct Linear API calls are blocked outside the CLI. The CLI is the only legal mutation surface.
2. **The contract for this project lives in `.homebase/workflow.yml` and `.homebase/project.yml`.** Read them; do not paraphrase them. The CLI loads both and enforces what they declare.
3. **Start before mutation.** `homebase work start <KEY>` precedes any code change. Use `homebase work checkpoint` for mid-flight commits. End with `homebase work finish`.
4. **SOPs are reference, not procedure.** `~/code/homebase/sops/HOMEBASE-SOP-*.md` explain the rationale behind contract clauses. Read them when designing new procedures, not when executing routine work — the CLI enforces them.
5. **Gate failures name their fix.** When a gate fails, the failure message names the remediation. Apply the fix and rerun. Do not work around the gate; do not edit `.homebase/work-state.json` to fake completion.
6. **Off-contract work is explicit.** Research, governance edits, README typos, and other work that legitimately doesn't need a Linear issue start with `homebase work chore "<desc>"` — this materialises a chore-flavoured worktree at `.worktrees/chore-<slug>/`, writes a `kind: chore` work-state with `issue: null`, and lets the operator commit + finish + tear down the worktree without a Linear move (HMB-86). Direct-to-main chore commits via `HOMEBASE_OFF_CONTRACT=1` are reserved for the unfixable cases (debugging the chore verb itself, fixing a worktree-creation bug, post-incident hot patches). The `--kind chore` flag on `homebase work start` labels chore-flavoured **tracked** work; it does not waive the ISSUE-KEY requirement.
7. **Charter red-list still applies.** Deploy, force-push to a remote, hotfix override (`--hotfix`), and `HOMEBASE_UI_VERIFICATION=off` require operator confirmation. The CLI prompts via dedicated env vars (`HOMEBASE_DEPLOY_CONFIRMED=1`, `HOMEBASE_FORCE_PUSH_CONFIRMED=1`, `HOMEBASE_HOTFIX_AUTHORIZED=1`).
8. **Plan-mode approval is the green-light.** A plan approved at exit-plan-mode is the confirmation for everything green and yellow that follows from the plan, including every `homebase work` call. Re-confirming individual mechanical steps is a deferral defect.
9. **Project context comes from the root CLAUDE.md.** Read it at the start of every session. Never hardcode project names, brands, app inventories, or domain rules into your own prompts or replies — the CLAUDE.md is the runtime source of truth.
10. **The contract wins.** If `.homebase/workflow.yml` and an SOP disagree, the contract is the operative rule. Update the SOP (or open an issue) so the explanation matches the control.
11. **Worktree mode is mandatory when the project opts in.** When `<project>/.homebase/project.yml` declares `worktree.enabled: true`, every code change must happen inside the per-task worktree, not the main checkout. The end of `homebase work start <KEY>` prints the cd hint; follow it before any edit. The minimum sequence is `homebase work start <KEY>` → `cd $(homebase work goto <KEY>)` → `source .homebase/.work-env` → edit + commit. Editing in the main checkout while a worktree exists silently bypasses the per-task isolation HMB-27 was built for, and `homebase work finish` will fail at the tree-clean gate because the worktree's tracked tree won't match the changes you actually made. This rule applies to chore work too — `homebase work chore "<desc>"` (HMB-86) creates a worktree the same way `homebase work start <KEY>` does. Direct-to-main chore commits via `HOMEBASE_OFF_CONTRACT=1` bypass this isolation and are reserved for the unfixable cases named in rule 6.
12. **Issue creation requires acceptance criteria.** When you identify work that needs a tracked Linear issue, hand off to `technical-project-manager` with a complete draft body that includes a `## Acceptance Criteria` section with at least one testable, platform-specific `- [ ]` checkbox. The `mcp__plugin_linear_linear__save_issue` create-gate (`scripts/hooks/linear-cli-guard-hook.sh`) will reject the call otherwise. Updates (`save_issue` with `id` present) pass through so AC can be backfilled into existing issues. If you cannot articulate what "done" looks like in concrete checkboxes, you do not yet understand the problem well enough to log it — the discipline is the point.

13. **Default to action; reserve asks for the red-list.** Confirmation rounds are a cost. The operator runs a single-operator workspace; there is no second human to defer to. Within an approved plan, do not re-ask. The Charter's three lists (`@~/code/homebase/governance/AUTONOMY_CHARTER.md` § Three lists) define the boundary: green and yellow → act; red → confirm. This rule canonicalizes `governance/AGENT_GUIDE.md` § Execution principle (*"When an SOP says MUST, execute and report — do not ask for confirmation"*) into the agent-auto-loaded contract — same principle, now visible at every tool-call. Specifically: do not ask before popping your own stash, before continuing an approved release-flow phase, or before delegating to TPM. Delegations to TPM are not separate confirmations (Charter Decision Note 4) — the gatekeeper routes the *implementation*, not the decision.

    **Documented architectural decisions are red-list to modify — even when troubleshooting.** When a configuration file carries operator-authored rationale (a comment explaining *why* the value is what it is — Kamal builder, DNS, registry endpoints, env-var contracts, Dockerfile build args), the comment is the operator's prior approval; rewriting it overrides them retroactively. If the documented path is failing, surface the failure + the alternatives — do not unilaterally pick one. The corresponding green-list affordance (per the Charter's homeostasis principle): trying documented retry / recovery procedures that **restore** the documented path is green-list — act, don't ask. This includes clearing stale Docker buildx contexts, killing wedged build processes locally, restarting Docker Desktop, and SSH-into-prod operations that fix infrastructure state (removing a stuck BuildKit container, restarting a single Kamal-managed app) *without modifying the configuration that drove the state.* **Recovery operations restore the documented path; reconfiguration replaces it.** The two failure modes pair: a deploy wedge is a recovery problem, not a reconfiguration problem.

14. **File it, don't list it.** When you identify follow-up work while finishing a task, do not write it back to the operator as a numbered chore list. Three paths: (a) in-scope and green-list → do it now in the current worktree; (b) out-of-scope governance / canon / SOP edit that has no Linear issue → `homebase work chore "<desc>"` in a fresh worktree (HMB-86 chore-fast-path); (c) out-of-scope OR red-list code work → delegate to TPM to file a Linear issue with `## Acceptance Criteria`. Writing the list without doing one of (a), (b), or (c) is a deferral defect (Charter § Required follow-ups).

15. **Plan approval ends the asking.** The instant a plan is approved at exit-plan-mode, your *first* message must be execution or a status update — never a permission question. "Want me to start?", "Should I…?", "or do you want to drive…?" after an approved plan are deferral defects: the plan IS the confirmation for every green/yellow-list step in it, and delegating to a gatekeeper agent (TPM for Linear/GitHub) is not a separate confirmation (Rule 8 + Rule 13 + Charter Decision Notes 4 & 5). A `PostToolUse:ExitPlanMode` hook (`scripts/hooks/post-plan-approval-reminder.sh`, registered in `.claude/user-settings.json`, HMB-105) re-injects this rule at approval time, where it's most likely to slip; the hook is a salience aid, not the source of truth — this rule is.

---

## Why this contract exists

Every rule above was previously expressed as prose in 19 agent prompts, 3 project CLAUDE.md files, and 13 SOPs. That distributed encoding produced three failure modes the contract closes:

- **Drift** — the same rule expressed three different ways means three places where the truth can rot. One contract, one renderer, one CLI.
- **Deviation surface** — agents synthesised the workflow from prose every session, sometimes dropping a step (especially the closing keyword on the final commit, or the UI-verification trailer). The CLI runs the full sequence as one deterministic gate.
- **Deferral defects** — the AUTONOMY_CHARTER §"Required follow-ups" antipattern was rooted in agents writing chore lists back to the operator instead of completing green-list work. The CLI removes the room for "what should I do next?" — it's `homebase work checkpoint` or `homebase work finish`, every time.

The contract is intentionally short. If a rule needs more than one sentence, the explanation belongs in `~/code/homebase/standards/WORKFLOW_CONTRACT.md` or the relevant SOP, and the rule above gets a cross-reference.

---

## Authority and conflicts

The contract is canon. When two canon documents disagree:

- This contract beats individual agent prompts (per-agent prompt updates lag canon edits).
- This contract beats project root CLAUDE.md (CLAUDE.md sections are generated from `workflow.yml`; if a hand-written section contradicts the contract, the hand-written section is wrong).
- The Autonomy Charter (`governance/AUTONOMY_CHARTER.md`) coexists. The Charter governs *when* an action is taken (act vs. confirm); this contract governs *how* it is taken (which CLI verb). They do not overlap.
- An SOP describes the rationale behind a clause; if the SOP and `.homebase/workflow.yml` disagree on what to do, follow the workflow.yml. Then file an issue to update the SOP so the explanation matches.

---

## Revision

When a rule above needs to change, edit this file directly. Then:

1. Update `~/code/homebase/standards/WORKFLOW_CONTRACT.md` if the change affects the canonical control doc.
2. Update `~/code/homebase/governance/HARD_RULES.yml` if the change introduces or renames a hard rule.
3. Update `~/code/homebase/schemas/workflow.schema.json` if the change adds a new gate, kind, or field.
4. Run `bin/homebase render-claudemd` so every project's CLAUDE.md picks up the change.

The contract is canon, not policy-by-precedent — disagreements about a specific incident land here as a list change, not as a one-off override.

---

## Cross-references

- `@~/code/homebase/governance/WORKFLOW_QUICKREF.md` — practical agent recipe with concrete commands per scenario.
- `@~/code/homebase/standards/WORKFLOW_CONTRACT.md` — canonical control flow; rationale and gate sequence.
- `@~/code/homebase/governance/AUTONOMY_CHARTER.md` — green/yellow/red list; what gets confirmed.
- `@~/code/homebase/governance/HARD_RULES.yml` — slug → display data registry rendered into each project's CLAUDE.md.
- `@~/code/homebase/schemas/workflow.schema.json` — schema for `<project>/.homebase/workflow.yml`.
- `@~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` — explanation: why issue-first / why these trailer keywords / why per-issue commits.
- `@~/code/homebase/sops/HOMEBASE-SOP-002-GITHUB_API_USAGE.md` — explanation: why `gh` routes through TPM.
- `@~/code/homebase/sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md` — explanation: why Linear routes through TPM.
