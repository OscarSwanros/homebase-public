#!/usr/bin/env bash
# Hook: TaskCompleted — enforce commit/push/issue-reference discipline.
# Blocks task completion if: uncommitted changes, unpushed commits, or
# the last commit lacks an issue reference.
#
# stdin: JSON {"task_id":"...","task_subject":"...","teammate_name":"...","team_name":"..."}
# Exit 2 + stderr = block completion with feedback.
#
# Canonical source: ~/code/homebase/scripts/hooks/task-completed.sh
# Symlinked into each project — do not duplicate.

set -euo pipefail

# Single source of truth for issue-trailer regexes. Same lib as commit-sop-check.sh
# so the two hooks cannot drift on which keywords / identifier shapes are valid.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/issue-trailer.sh
. "${HOOK_DIR}/../lib/issue-trailer.sh"

INPUT=$(cat)
SUBJECT=$(echo "$INPUT" | jq -r '.task_subject // ""')

ERRORS=""

# 1. Check for uncommitted changes
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  ERRORS="${ERRORS}Uncommitted changes detected. Commit all work before completing.\n"
fi

# 2. Check for unpushed commits (skip if no upstream)
if git rev-parse --verify '@{u}' &>/dev/null; then
  UNPUSHED=$(git log '@{u}..HEAD' --oneline 2>/dev/null)
  if [ -n "$UNPUSHED" ]; then
    ERRORS="${ERRORS}Unpushed commits found. Push before completing.\n"
  fi
fi

# 2.5 If .homebase/workflow.yml is present, an active work-state must be finished.
WORKFLOW_YML=""
WORK_STATE=""
REPO_ROOT_HOOK="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
if [[ -n "$REPO_ROOT_HOOK" ]]; then
  WORKFLOW_YML="$REPO_ROOT_HOOK/.homebase/workflow.yml"
  # HMB-87 B.11: resolve the SHA-keyed per-worktree work-state via the loader.
  if [[ -f "$REPO_ROOT_HOOK/scripts/lib/workflow-loader.sh" ]]; then
    # shellcheck source=../lib/workflow-loader.sh
    . "$REPO_ROOT_HOOK/scripts/lib/workflow-loader.sh"
    WORK_STATE="$(work_state_path "$REPO_ROOT_HOOK" 2>/dev/null || echo "")"
  fi
  [[ -z "$WORK_STATE" ]] && WORK_STATE="$REPO_ROOT_HOOK/.homebase/work-state.json"
fi
if [[ -f "$WORKFLOW_YML" && -f "$WORK_STATE" ]] && command -v jq >/dev/null 2>&1; then
  finished=$(jq -r '.finished // false' "$WORK_STATE" 2>/dev/null || echo "true")
  if [[ "$finished" != "true" ]]; then
    issue=$(jq -r '.issue // "?"' "$WORK_STATE" 2>/dev/null || echo "?")
    ERRORS="${ERRORS}Active work-state for $issue is not finished. Run 'homebase work finish' before completing.\n"
  fi
fi

# 3. Check most recent commit references an issue (unless exempt chore:/Release/Merge/Post-release:).
LAST_MSG=$(git log -1 --pretty=%B 2>/dev/null || echo "")
LAST_SUBJECT=$(echo "$LAST_MSG" | head -1)
IS_EXEMPT=0
if echo "$LAST_SUBJECT" | grep -Eq '^(Release |Post-release:|Merge )'; then
  IS_EXEMPT=1
fi
if echo "$LAST_SUBJECT" | grep -Eiq '^chore(\([^)]+\))?:'; then
  IS_EXEMPT=1
fi
if [ -n "$LAST_MSG" ] && [ $IS_EXEMPT -eq 0 ]; then
  # Accept either GitHub (#N) or Linear (KEY-N) identifier shape; see
  # HOMEBASE-SOP-001 §0 and §B2.
  # Pattern source: scripts/lib/issue-trailer.sh (TRAILER_ANYWHERE_RE).
  # Case-insensitive (matches Closes/closes/Fix/fixed/etc.) — keep in lockstep
  # with `commit-sop-check.sh` which uses `grep -Ei` against TRAILER_LINE_RE.
  if ! echo "$LAST_MSG" | grep -qiE "$TRAILER_ANYWHERE_RE"; then
    ERRORS="${ERRORS}Last commit doesn't reference a tracked issue (Closes/Fixes/Refs #N or KEY-N). Per HOMEBASE-SOP-001, every commit must link to an issue.\n"
  fi
fi

if [ -n "$ERRORS" ]; then
  printf "Cannot complete task \"%s\":\n%b" "$SUBJECT" "$ERRORS" >&2
  exit 2
fi

exit 0
