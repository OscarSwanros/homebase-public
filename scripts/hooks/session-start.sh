#!/usr/bin/env bash
# Hook: SessionStart — check for stale uncommitted work and reset
# per-session hook state.
# Triggered by .claude/settings.json at the start of each session.
#
# Canonical source: ~/code/homebase/scripts/hooks/session-start.sh
# Symlinked into each project — do not duplicate.

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -n "$REPO_ROOT" ]]; then
  rm -f "$REPO_ROOT/.claude/.ui-verification-warned"
fi

DIRTY=$(git status --porcelain 2>/dev/null)
if [[ -n "$DIRTY" ]]; then
  COUNT=$(echo "$DIRTY" | wc -l | tr -d ' ')
  echo "WARNING: ${COUNT} uncommitted change(s) from a previous session. Run 'git status' to review."
fi

# Surface active workflow state from a prior session.
if [[ -n "$REPO_ROOT" ]]; then
  # HMB-87 B.11: resolve the SHA-keyed per-worktree work-state via the loader.
  WORK_STATE=""
  if [[ -f "$REPO_ROOT/scripts/lib/workflow-loader.sh" ]]; then
    # shellcheck source=../lib/workflow-loader.sh
    . "$REPO_ROOT/scripts/lib/workflow-loader.sh"
    WORK_STATE="$(work_state_path "$REPO_ROOT" 2>/dev/null || echo "")"
  fi
  [[ -z "$WORK_STATE" ]] && WORK_STATE="$REPO_ROOT/.homebase/work-state.json"
  if [[ -f "$WORK_STATE" ]] && command -v jq >/dev/null 2>&1; then
    finished=$(jq -r '.finished // false' "$WORK_STATE" 2>/dev/null || echo "true")
    if [[ "$finished" == "false" ]]; then
      issue=$(jq -r '.issue // "?"' "$WORK_STATE" 2>/dev/null || echo "?")
      branch=$(jq -r '.branch // "?"' "$WORK_STATE" 2>/dev/null || echo "?")
      gates=$(jq -r '.last_gate_passed // 0' "$WORK_STATE" 2>/dev/null || echo "0")
      echo "WORK IN FLIGHT: $issue on branch $branch (gates passed: $gates/13)."
      echo "  Continue: 'homebase work checkpoint' or 'homebase work finish'."
      echo "  Abandon:  'homebase work cancel'."
    fi
  fi
fi

# HMB-87 B.11: prune stale legacy single-file work-state.json files across all
# worktrees. The migration in workflow-loader.sh catches files in worktrees
# that get visited by any state-resolving call; this prune catches the rest —
# legacy files in worktrees nobody has touched in N days. Default threshold
# 14 days; override via HOMEBASE_WORK_STATE_LEGACY_PRUNE_DAYS.
if [[ -n "$REPO_ROOT" ]]; then
  PRUNE_DAYS="${HOMEBASE_WORK_STATE_LEGACY_PRUNE_DAYS:-14}"
  # Walk every worktree (main + all .worktrees/*) and check its legacy path.
  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        wt_path="${line#worktree }"
        legacy="$wt_path/.homebase/work-state.json"
        if [[ -f "$legacy" ]]; then
          # mtime in days. `find -mtime +N` lists files older than N days.
          if [[ -n "$(find "$legacy" -type f -mtime +"$PRUNE_DAYS" 2>/dev/null)" ]]; then
            rm -f "$legacy" "$legacy.lock"
            echo "Pruned stale legacy work-state at $legacy (older than ${PRUNE_DAYS} days)."
          fi
        fi
        ;;
    esac
  done < <(git -C "$REPO_ROOT" worktree list --porcelain 2>/dev/null)
fi

# Charter red-list banner: HOMEBASE_UI_VERIFICATION=off is a bypass that CI
# will still re-check, but local Stop-blocking is suppressed.
if [[ "${HOMEBASE_UI_VERIFICATION:-}" == "off" ]]; then
  echo "CHARTER RED-LIST ACTIVE: HOMEBASE_UI_VERIFICATION=off is set."
  echo "  Local Stop-hook UI verification is suppressed; CI re-checks on PR."
  echo "  See @~/code/homebase/governance/AUTONOMY_CHARTER.md § Red-list."
fi
