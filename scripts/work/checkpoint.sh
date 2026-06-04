#!/usr/bin/env bash
# scripts/work/checkpoint.sh — `homebase work checkpoint [opts]`.
#
# Mid-task progress signal. Doesn't end work. Validates that recent commits
# all reference the active issue. Optionally moves Linear state. Optionally
# pushes the branch.
#
# Args:
#   --note "<text>"        Free-form note recorded in state.checkpoints[]
#   --state <kind>         Move Linear state to first matching state-name for
#                          the given kind (backlog|in_progress|in_review|done)
#   --commit-required      Refuse if there are uncommitted changes (forces
#                          a commit boundary at every checkpoint)
#   --push                 Push the branch to origin (uses HOMEBASE_WORK_AUTHORIZED=1)
#   --validate             Run gate 9 (required_checks) as a dry-run

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${WORK_DIR}/lib/state.sh"
. "${WORK_DIR}/lib/linear-bridge.sh"
. "${WORK_DIR}/lib/gates.sh"

NOTE=""
TARGET_KIND=""
COMMIT_REQUIRED=0
DO_PUSH=0
DO_VALIDATE=0

usage() {
  cat <<EOF
usage: homebase work checkpoint [--note TEXT] [--state KIND] [--commit-required] [--push] [--validate]

Mid-task progress signal. Validates that all branch commits reference the
active issue. Optionally moves Linear state and/or pushes.

KIND must be one of: backlog | in_progress | in_review | done
EOF
}

while (($#)); do
  case "$1" in
    -h|--help)         usage; exit 0 ;;
    --note)            NOTE="$2"; shift 2 ;;
    --state)           TARGET_KIND="$2"; shift 2 ;;
    --commit-required) COMMIT_REQUIRED=1; shift ;;
    --push)            DO_PUSH=1; shift ;;
    --validate)        DO_VALIDATE=1; shift ;;
    *) echo "checkpoint: unknown flag $1" >&2; usage; exit 2 ;;
  esac
done

ROOT="$(find_repo_root)"
[[ -z "$ROOT" ]] && { echo "checkpoint: not in a git repo" >&2; exit 2; }

state_active "$ROOT" || {
  echo "checkpoint: no active work-state. Run 'homebase work start <KEY>' first." >&2
  exit 3
}

ISSUE="$(state_issue "$ROOT")"
APP="$(state_app "$ROOT")"
BRANCH="$(state_branch "$ROOT")"

divider() { echo "─────────────────────────────────────────────────────────"; }
echo "homebase work checkpoint"
divider
echo "issue:    $ISSUE"
echo "app:      $APP"
echo "branch:   $BRANCH"

# Verify branch matches state.
CURRENT="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
if [[ "$CURRENT" != "$BRANCH" ]]; then
  echo "  [fail] HEAD on '$CURRENT', expected '$BRANCH'" >&2
  divider
  exit 2
fi

# Tree clean check (only blocking when --commit-required).
DIRTY="$(git -C "$ROOT" status --porcelain 2>/dev/null)"
if [[ -n "$DIRTY" ]]; then
  if [[ "$COMMIT_REQUIRED" -eq 1 ]]; then
    echo "  [fail] uncommitted changes; commit first (--commit-required is set)" >&2
    divider
    exit 2
  else
    echo "  [warn] uncommitted changes (use --commit-required to enforce)"
  fi
fi

# All branch commits reference the active issue.
GATE_REPO_ROOT="$ROOT" gate_commits_trailered || {
  divider
  exit 2
}

# Optional: --validate runs gate 9.
if [[ "$DO_VALIDATE" -eq 1 ]]; then
  GATE_REPO_ROOT="$ROOT" gate_validate_passes || {
    echo "  [warn] validate-passes failed in checkpoint --validate (non-blocking)"
  }
fi

# Optional: --state moves Linear.
LINEAR_NEW=""
if [[ -n "$TARGET_KIND" ]]; then
  case "$TARGET_KIND" in
    backlog|in_progress|in_review|done) ;;
    *) echo "checkpoint: --state must be backlog|in_progress|in_review|done" >&2; exit 2 ;;
  esac
  if [[ "${LINEAR_TPM_AUTHORIZED:-0}" != "1" ]]; then
    echo "  [fail] LINEAR_TPM_AUTHORIZED=1 required for --state move" >&2
    exit 2
  fi
  target="$(linear_resolve_state_for_kind "$ISSUE" "$TARGET_KIND" "$APP" 2>/dev/null || true)"
  if [[ -z "$target" ]]; then
    echo "  [fail] no state-name matches kind '$TARGET_KIND' for issue $ISSUE" >&2
    exit 2
  fi
  if linear_move_issue "$ISSUE" "$target" >/dev/null 2>&1; then
    LINEAR_NEW="$target"
    state_set linear_state_now "$target" "$ROOT"
    echo "linear:   moved → $target"
  else
    echo "  [fail] linear move to '$target' failed" >&2
    exit 2
  fi
fi

# Optional: --push.
if [[ "$DO_PUSH" -eq 1 ]]; then
  if HOMEBASE_WORK_AUTHORIZED=1 git -C "$ROOT" push -u origin "$BRANCH" >/dev/null 2>&1; then
    echo "branch:   pushed origin/$BRANCH"
  else
    echo "  [fail] push failed" >&2
    exit 2
  fi
fi

# Append checkpoint to state.
HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)"
state_append_checkpoint --note "${NOTE:-(no note)}" --commit-sha "$HEAD_SHA" --root "$ROOT"

CKCOUNT="$(jq -r '.checkpoints | length' "$(state_path "$ROOT")")"
echo "checkpoints: $CKCOUNT"
[[ -n "$NOTE" ]] && echo "note:     \"$NOTE\""
echo "state:    updated"
divider
echo "ok."
exit 0
