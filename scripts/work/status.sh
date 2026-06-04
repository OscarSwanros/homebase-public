#!/usr/bin/env bash
# scripts/work/status.sh — `homebase work status [--exit-code-on-fail]`.
#
# Read-only diagnostic. Never mutates. Safe to call from any agent at any
# time. Used by:
#   - session-start.sh hook (banner)
#   - finish-work skill (preview before invoking finish)
#   - any agent wanting to know "where am I"
#
# Args:
#   --exit-code-on-fail    Exit 2 if any preview-gate would fail. Default
#                          is exit 0 always (status is informational).
#   --json                 Emit JSON instead of human-readable banner.

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${WORK_DIR}/lib/state.sh"
. "${WORK_DIR}/lib/gates.sh"

EXIT_ON_FAIL=0
EMIT_JSON=0

while (($#)); do
  case "$1" in
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    --exit-code-on-fail) EXIT_ON_FAIL=1; shift ;;
    --json) EMIT_JSON=1; shift ;;
    *) echo "status: unknown flag $1" >&2; exit 2 ;;
  esac
done

ROOT="$(find_repo_root)"
if [[ -z "$ROOT" ]]; then
  if [[ "$EMIT_JSON" -eq 1 ]]; then
    echo '{"in_flight": false, "reason": "not-in-git-repo"}'
  else
    echo "not in a git repo"
  fi
  exit 0
fi

if ! state_active "$ROOT"; then
  if [[ "$EMIT_JSON" -eq 1 ]]; then
    echo '{"in_flight": false}'
  else
    echo "no active work-state. Run 'homebase work start <KEY>' to begin."
  fi
  exit 0
fi

ISSUE="$(state_issue "$ROOT")"
APP="$(state_app "$ROOT")"
BRANCH="$(state_branch "$ROOT")"
KIND="$(state_kind "$ROOT")"
STARTED="$(state_read started_at "$ROOT")"
LINEAR_NOW="$(state_read linear_state_now "$ROOT")"
CHECKPOINTS="$(jq -r '.checkpoints | length' "$(state_path "$ROOT")")"
COMMITS="$(git -C "$ROOT" rev-list --count "$(state_read base_sha "$ROOT")"..HEAD 2>/dev/null || echo "?")"

if [[ "$EMIT_JSON" -eq 1 ]]; then
  jq -n \
    --arg issue "$ISSUE" --arg app "$APP" --arg branch "$BRANCH" \
    --arg kind "$KIND" --arg started "$STARTED" --arg linear "$LINEAR_NOW" \
    --argjson checkpoints "$CHECKPOINTS" --arg commits "$COMMITS" \
    '{
      in_flight: true,
      issue: $issue, app: $app, branch: $branch, kind: $kind,
      started_at: $started, linear_state_now: $linear,
      checkpoints: $checkpoints, commits_since_start: $commits
    }'
  exit 0
fi

divider() { echo "─────────────────────────────────────────────────────────"; }
divider
echo "in flight: $ISSUE"
echo "app:       $APP ($(read_project_yml_as_json "$ROOT" | jq -r --arg a "$APP" '.apps[] | select(.name==$a) | .platforms | join(", ")'))"
echo "branch:    $BRANCH ($COMMITS commits since start)"
echo "started:   $STARTED"
echo "kind:      $KIND"
echo "linear:    $LINEAR_NOW"
echo "checkpoints: $CHECKPOINTS"
divider

# Preview gates 2-7 (cheap, read-only). Heavy gates (validate, push, PR,
# linear move) are run only by `finish`, not by `status`.
echo "finish_gates (preview):"
GATES_FAILED=0
GATE_REPO_ROOT="$ROOT" gate_branch_on_track || GATES_FAILED=1
GATE_REPO_ROOT="$ROOT" gate_tree_clean      || GATES_FAILED=1
GATE_REPO_ROOT="$ROOT" gate_commits_present || GATES_FAILED=1
GATE_REPO_ROOT="$ROOT" gate_commits_trailered || GATES_FAILED=1
GATE_REPO_ROOT="$ROOT" gate_closing_keyword || GATES_FAILED=1
GATE_REPO_ROOT="$ROOT" gate_changelog_current || GATES_FAILED=1

divider
echo "finish:    homebase work finish"
echo "abandon:   homebase work cancel"

if [[ "$EXIT_ON_FAIL" -eq 1 && "$GATES_FAILED" -eq 1 ]]; then
  exit 2
fi
exit 0
