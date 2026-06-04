#!/usr/bin/env bash
# scripts/work/cancel.sh — `homebase work cancel [--reset-linear] [--reason TEXT]`.
#
# Abandons the active work-state. Leaves the branch and commits intact —
# branch deletion is an explicit operator action.

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${WORK_DIR}/lib/state.sh"
. "${WORK_DIR}/lib/linear-bridge.sh"
# shellcheck source=./lib/worktree.sh
. "${WORK_DIR}/lib/worktree.sh"

RESET_LINEAR=0
REASON=""

while (($#)); do
  case "$1" in
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    --reset-linear) RESET_LINEAR=1; shift ;;
    --reason)       REASON="$2"; shift 2 ;;
    *) echo "cancel: unknown flag $1" >&2; exit 2 ;;
  esac
done

ROOT="$(find_repo_root)"
[[ -z "$ROOT" ]] && { echo "cancel: not in a git repo" >&2; exit 2; }

if ! state_exists "$ROOT"; then
  echo "cancel: no work-state to cancel"
  exit 3
fi

ISSUE="$(state_issue "$ROOT")"
APP="$(state_app "$ROOT")"
BRANCH="$(state_branch "$ROOT")"

divider() { echo "─────────────────────────────────────────────────────────"; }
divider
echo "abandoning: $ISSUE"
echo "branch:     $BRANCH (kept; delete manually if unwanted)"

if [[ "$RESET_LINEAR" -eq 1 ]]; then
  if [[ "${LINEAR_TPM_AUTHORIZED:-0}" != "1" ]]; then
    echo "  [warn] LINEAR_TPM_AUTHORIZED=1 not set — Linear state not reverted"
  else
    target="$(linear_resolve_state_for_kind "$ISSUE" backlog "$APP" 2>/dev/null || true)"
    if [[ -n "$target" ]]; then
      if linear_move_issue "$ISSUE" "$target" >/dev/null 2>&1; then
        echo "linear:     reverted → $target"
      else
        echo "  [warn] linear move to '$target' failed"
      fi
    fi
  fi
else
  echo "linear:     left as-is — pass --reset-linear to revert"
fi

state_clear --reason "${REASON:-cancelled by operator}" --root "$ROOT"
rm -f "$ROOT/.homebase/.work-env"
echo "state:      $(state_path "$ROOT") removed (audit log appended)"
echo "env:        .homebase/.work-env removed"

# Worktree teardown (HMB-27): if we're inside a per-task worktree, run
# the project's teardown_command and remove the worktree.
WORKTREE_REMOVED=""
if in_worktree; then
  WT="$(git rev-parse --show-toplevel)"
  PROJECT_ROOT_FOR_CLEANUP="$(worktree_project_root)"
  if worktree_destroy "$WT" "$ISSUE"; then
    WORKTREE_REMOVED="$WT"
  fi
  cd "$PROJECT_ROOT_FOR_CLEANUP" 2>/dev/null || true
fi
if [[ -n "$WORKTREE_REMOVED" ]]; then
  echo "worktree:   removed; cd back to ${PROJECT_ROOT_FOR_CLEANUP:-..} when prompted"
fi
divider
exit 0
