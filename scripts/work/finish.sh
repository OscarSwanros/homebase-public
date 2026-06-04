#!/usr/bin/env bash
# scripts/work/finish.sh — `homebase work finish [opts]`.
#
# The load-bearing gate. Runs the finish sequence in order. First failure
# aborts; idempotent re-runs pick up at last_gate_passed + 1.
#
# As of HMB-22, finish lands work directly on main: rebase the work
# branch onto origin/main, FF-push HEAD:main, delete the branch (origin
# + local), Linear → Done. No PR, no In-Review limbo. The PR-based flow
# (`--no-pr`, `--ship`, `pr_must_exist`) was retired — single-operator
# default is direct-to-main per workflow review 2026-04-28 (Option A).
#
# When start used `--no-branch`, the work-state branch IS main; gate 11
# just FF-pushes origin/main and skips the branch-cleanup steps.
#
# Args:
#   --allow-empty          Permit an empty-tree HEAD when adding a closing commit.
#   --append-closing       Always re-evaluate gate 5 (closing-keyword-present)
#                          on every finish invocation, regardless of memoised
#                          state. On gate-5 failure, automatically append an
#                          empty closing commit (`Closes <state.issue>`) and
#                          re-evaluate again. Removes the manual remediation
#                          step when the agent forgot the closing keyword
#                          on HEAD, AND defends against a stale-skip when an
#                          amended commit on the branch dropped the closing
#                          keyword after a prior partial finish (HMB-17).
#   --no-pr / --ship       DEPRECATED no-ops (HMB-22). Kept so existing
#                          scripts/aliases don't break; both are accepted
#                          and ignored. Will be removed in a future release.
#
# Authorisation:
#   - Linear mutation requires LINEAR_TPM_AUTHORIZED=1.
#   - Push to main (gate 11) sets HOMEBASE_WORK_AUTHORIZED=1 internally.

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${WORK_DIR}/lib/state.sh"
. "${WORK_DIR}/lib/gates.sh"
. "${WORK_DIR}/lib/linear-bridge.sh"
# shellcheck source=./lib/worktree.sh
. "${WORK_DIR}/lib/worktree.sh"

ALLOW_EMPTY=0
APPEND_CLOSING=0

while (($#)); do
  case "$1" in
    -h|--help)        sed -n '2,32p' "$0"; exit 0 ;;
    --no-pr|--ship)   shift ;;  # deprecated no-ops, HMB-22
    --allow-empty)    ALLOW_EMPTY=1; shift ;;
    --append-closing) APPEND_CLOSING=1; shift ;;
    *) echo "finish: unknown flag $1" >&2; exit 2 ;;
  esac
done

ROOT="$(find_repo_root)"
[[ -z "$ROOT" ]] && { echo "finish: not in a git repo" >&2; exit 2; }
export GATE_REPO_ROOT="$ROOT"

state_active "$ROOT" || {
  echo "finish: no active work-state. Run 'homebase work start <KEY>' first." >&2
  exit 3
}

# Outcome is always Done in the HMB-22 direct-to-main flow.
TARGET_KIND="done"
OUTCOME="done"

# Per-kind gate skips (chore/hotfix).
KIND="$(state_kind "$ROOT")"
# HMB-103: resolve the issue key once, up front, so skip_for_kind can decide
# whether a chore's Linear gates apply (issue-bearing chores still transition).
# Empty for issue-less chores (HMB-86 B.3).
ISSUE="$(state_issue "$ROOT" 2>/dev/null || echo "")"

divider() { echo "─────────────────────────────────────────────────────────"; }
echo "homebase work finish"
divider
echo "issue: $(state_issue "$ROOT")  app: $(state_app "$ROOT")  branch: $(state_branch "$ROOT")  kind: $KIND"
divider

# Gate runner.
LAST_PASSED="$(state_last_gate_passed "$ROOT")"
RAN=0
# HMB-84: gate-ID uniqueness guard. The gate number is the dedup key for
# "already passed in a prior run", so two different gates sharing a number
# means whichever runs second silently inherits the first's skip. That is the
# exact mechanism that let `ui-verified` and `landed-to-main` both claim gate
# 11 and skip the push — marking an issue Done with unpushed code (hard rule
# 8). Fail fast the moment a number is reused for a different gate name.
#
# HMB-118: plain indexed array, NOT `declare -A`. macOS system bash is 3.2
# (what `#!/usr/bin/env bash` resolves to) and has no associative arrays —
# `declare -A` errors there. Gate IDs are integers, so an indexed array keys
# on them identically; the guard logic is unchanged. The rest of scripts/
# avoids associative arrays for the same bash-3.2 reason.
_GATE_ID_NAMES=()
run_gate() {
  local n="$1" name="$2" fn="$3"
  if [[ -n "${_GATE_ID_NAMES[$n]:-}" && "${_GATE_ID_NAMES[$n]}" != "$name" ]]; then
    echo "  [fail] gate-ID collision: gate $n is used for both '${_GATE_ID_NAMES[$n]}' and '$name'." >&2
    echo "         Every gate must have a unique integer ID (HMB-84). Renumber and rerun." >&2
    exit 2
  fi
  _GATE_ID_NAMES[$n]="$name"
  if [[ "$LAST_PASSED" -ge "$n" ]]; then
    echo "  [skip] $name — already passed in prior run"
    return 0
  fi
  RAN=1
  if "$fn"; then
    state_set_gate_passed "$n" "$ROOT"
    return 0
  else
    return 2
  fi
}

# Per-kind skip helpers.
#
# Per-kind gate skips. The decision is the pure `should_skip_gate` function in
# gates.sh (HMB-86 + HMB-103) — single-sourced so the unit tests can exercise
# it directly. Issue-bearing chores still run the Linear gates (HMB-103).
skip_for_kind() {
  local kind="$1"; shift
  if should_skip_gate "$KIND" "$kind" "${ISSUE:-}"; then
    echo "  [skip] $* — kind=$KIND"
    return 0
  fi
  return 1
}

# 0 — preflight (toolchain + env). Not memoized; re-evaluates every run
# because the env can change between invocations. Fails fast on missing
# xcode-select / ANDROID_HOME / JDK / bundle install before the slow
# gates (4-9) burn time. (HMB-16)
if [[ "${HOMEBASE_SKIP_PREFLIGHT:-0}" == "1" ]]; then
  echo "  [skip] preflight — HOMEBASE_SKIP_PREFLIGHT=1 (Charter override)"
else
  gate_preflight || exit 2
fi
# 1
run_gate 1 "state-loaded" gate_state_loaded || exit 2
# 2
run_gate 2 "branch-on-track" gate_branch_on_track || exit 2
# 3
run_gate 3 "tree-clean" gate_tree_clean || exit 2
# 4 — commits-present (HMB-45 F9). Refuses on empty commit range so a
#     mis-routed empty worktree can't transition Linear → Done with zero
#     shipped code. All-or-nothing: no Linear move, no push, no teardown.
run_gate 4 "commits-present" gate_commits_present || exit 2
# 5
run_gate 5 "commits-trailered" gate_commits_trailered || exit 2
# 6 — closing-keyword-present (with --append-closing fallback).
#
# When --append-closing is set, gate 5 ALWAYS re-evaluates regardless of
# memoized state. This catches the case where a commit added to the
# branch after a prior partial finish (typically an amended chore commit
# during gate-fix iteration) becomes HEAD without a closing keyword —
# without the re-eval, gate 5 would stay marked as passed and pre-push
# would later catch the same missing-keyword in a less informative gate.
# (See HMB-17 for the failure mode.)
if skip_for_kind gate6_closing "closing-keyword-present"; then
  state_set_gate_passed 6 "$ROOT"
elif [[ "$APPEND_CLOSING" -eq 1 ]]; then
  if gate_closing_keyword; then
    state_set_gate_passed 6 "$ROOT"
    RAN=1
  else
    ISSUE="$(state_issue "$ROOT")"
    echo "  [auto] appending empty closing commit for $ISSUE"
    HOMEBASE_WORK_AUTHORIZED=1 git -C "$ROOT" commit --allow-empty -m "$(printf 'Closes %s\n\nCo-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>\n' "$ISSUE")" >/dev/null || {
      echo "  [fail] could not append closing commit (git exit $?)" >&2
      exit 2
    }
    if gate_closing_keyword; then
      state_set_gate_passed 6 "$ROOT"
      RAN=1
    else
      echo "  [fail] closing-keyword still missing after auto-append (unexpected)" >&2
      exit 2
    fi
  fi
elif [[ "$LAST_PASSED" -ge 6 ]]; then
  echo "  [skip] closing-keyword-present — already passed in prior run"
elif gate_closing_keyword; then
  state_set_gate_passed 6 "$ROOT"
  RAN=1
else
  exit 2
fi
# 7 — gated by changelog_updated_for_feat_fix and kind
if skip_for_kind gate7_changelog "changelog-current"; then
  state_set_gate_passed 7 "$ROOT"
elif gate_active finish_gates.changelog_updated_for_feat_fix "$(state_app "$ROOT")"; then
  run_gate 7 "changelog-current" gate_changelog_current || exit 2
else
  echo "  [skip] changelog-current — disabled in workflow.yml"
  state_set_gate_passed 7 "$ROOT"
fi
# 8 — linear in_progress check
if skip_for_kind gate8_linear "linear-in-progress"; then
  state_set_gate_passed 8 "$ROOT"
elif [[ "${HOMEBASE_SKIP_LINEAR:-0}" == "1" ]]; then
  echo "  [skip] linear-in-progress — HOMEBASE_SKIP_LINEAR=1 (CI re-checks)"
  state_set_gate_passed 8 "$ROOT"
else
  run_gate 8 "linear-in-progress" gate_linear_in_progress || exit 2
fi
# 9 — validate
if skip_for_kind gate9_validate "validate-passes"; then
  state_set_gate_passed 9 "$ROOT"
else
  run_gate 9 "validate-passes" gate_validate_passes || exit 2
fi
# 10 — ui-verified
if skip_for_kind gate10_ui "ui-verified"; then
  state_set_gate_passed 10 "$ROOT"
elif gate_active finish_gates.ui_verification_present "$(state_app "$ROOT")"; then
  # HMB-84: this is gate 10, not 11. It previously called `run_gate 11`,
  # colliding with landed-to-main below: once ui-verified recorded gate 11 as
  # passed, the landed-to-main invocation matched the same dedup key and was
  # skipped on retry — pushing nothing yet transitioning Linear → Done.
  run_gate 10 "ui-verified" gate_ui_verified || exit 2
else
  echo "  [skip] ui-verified — disabled in workflow.yml"
  state_set_gate_passed 10 "$ROOT"
fi
# 11 — land directly on main (HMB-22: replaces branch-pushed + PR-opened).
#
# HMB-84: deliberately NOT run via run_gate — this gate is the hard-rule-8
# integrity boundary and must re-verify on EVERY finish attempt, never trusting
# a memoized "already passed". gate_landed_to_main is idempotent: it
# short-circuits cheaply when HEAD is already on origin/main, and otherwise
# rebases + FF-pushes. It can only return success when the commit is genuinely
# on origin/main, so gate 13 (Linear → Done) below can never run on unpushed
# code. We still record gate 11 for state continuity / progress display.
if gate_landed_to_main; then
  state_set_gate_passed 11 "$ROOT"
else
  exit 2
fi
# Gate 12 (PR) retired in HMB-22; mark passed for state continuity.
state_set_gate_passed 12 "$ROOT"
# 13 — linear move
export FINISH_TARGET_KIND="$TARGET_KIND"
if skip_for_kind gate13_linear "linear-transitioned"; then
  state_set_gate_passed 13 "$ROOT"
else
  # Self-authorize for the canonical Linear move (HMB-28). finish.sh IS an
  # audited path: gates 0-12 must pass before this runs, the issue and target
  # state come from the work-state file (not external arguments), and the
  # transition is always In Progress → Done. The linear-cli-guard hook still
  # gates ad-hoc Bash invocations of `homebase work finish`; this internal
  # export only takes effect once the script is already executing inside
  # finish.sh's process scope. Document: SOP-013 § Linear API Gatekeeper —
  # Self-authorization within work-state lifecycle scripts.
  export LINEAR_TPM_AUTHORIZED=1
  run_gate 13 "linear-transitioned" gate_linear_transitioned || exit 2
fi
# 14 — finalise
export FINISH_OUTCOME="$OUTCOME"
run_gate 14 "state-finalised" gate_state_finalised || exit 2

# Remove the env file so the next session doesn't carry a stale
# HOMEBASE_WORK_AUTHORIZED into a finished work-state.
rm -f "$ROOT/.homebase/.work-env"

# Worktree teardown (HMB-27). When `homebase work finish` runs from inside
# a per-task worktree, run the project's teardown_command (e.g. `bin/rails
# db:drop` against the per-worktree DB) and remove the worktree. Operator
# is left in the project main checkout so the next prompt is sensible.
#
# HMB-93 — Claude-aware deferral. When finish runs inside a live Claude Code
# session (signalled by CLAUDECODE=1, exported by the Claude CLI in every
# Bash-tool subprocess) and the script is sitting in a worktree that
# `worktree_destroy` would remove, deleting it would invalidate the parent
# Claude process's CWD. The `cd` at the end of this block only affects this
# subshell; the parent stays pointed at the deleted dir, after which
# `posix_spawn '/bin/sh'` fails with ENOENT for every subsequent Bash call,
# and the statusline goes dark. So the worktree is RETAINED. (HMB-98/Tier-2:
# session-end-cleanup.sh no longer auto-removes worktrees, so the operator
# disposes of the retained worktree explicitly once they've cd'd out — the
# message below names the command.)
WORKTREE_REMOVED=""
WORKTREE_RETAINED=""
if in_worktree; then
  WT="$(git rev-parse --show-toplevel)"
  PROJECT_ROOT_FOR_CLEANUP="$(worktree_project_root)"
  ISSUE_FOR_CLEANUP="$(state_issue "$ROOT" 2>/dev/null || echo "")"
  if [[ "${CLAUDECODE:-}" == "1" ]]; then
    WORKTREE_RETAINED="$WT"
  elif worktree_destroy "$WT" "$ISSUE_FOR_CLEANUP"; then
    WORKTREE_REMOVED="$WT"
  fi
  # Step out of the now-removed worktree so the calling shell isn't sitting
  # in a deleted dir on the next prompt.
  cd "$PROJECT_ROOT_FOR_CLEANUP" 2>/dev/null || true
fi

divider
# HMB-73: print the issue key captured at the top of the run (line ~75), not a
# fresh state_issue read. By this point gate 14 has finalised the work-state
# and teardown may have removed the worktree, so re-reading often returned "?"
# (seen on the HMB-69 and TFD-1445 finishes). $ISSUE is empty for issue-less
# chores, which correctly renders as "?".
echo "done. outcome=$OUTCOME  issue=${ISSUE:-?}"
echo "      .homebase/.work-env removed; source removal in your shell:"
echo "        unset HOMEBASE_WORK_AUTHORIZED WORK_KEY WORK_APP WORK_BRANCH"
if [[ -n "$WORKTREE_REMOVED" ]]; then
  echo "      worktree removed; cd back to the project root:"
  echo "        cd ${PROJECT_ROOT_FOR_CLEANUP:-..}"
fi
if [[ -n "$WORKTREE_RETAINED" ]]; then
  echo "      worktree retained (CLAUDECODE=1 — live Claude session sits"
  echo "      inside it, so finish can't remove its own CWD). It is NOT"
  echo "      auto-removed. After you cd out, dispose of it:"
  echo "        cd ${PROJECT_ROOT_FOR_CLEANUP:-..} && git worktree remove --force $WORKTREE_RETAINED"
fi
exit 0
