#!/usr/bin/env bash
# Hook: TaskCreated — warn if a task doesn't reference a GitHub issue.
# Does NOT block creation — teammates may need sub-tasks without issues.
#
# stdin: JSON {"task_subject":"...","task_description":"...","teammate_name":"...","team_name":"..."}
# Exit 2 + stderr = send feedback without blocking (hook convention).
#
# Canonical source: ~/code/homebase/scripts/hooks/task-created.sh
# Symlinked into each project — do not duplicate.

set -euo pipefail

INPUT=$(cat)
SUBJECT=$(echo "$INPUT" | jq -r '.task_subject // ""')
DESCRIPTION=$(echo "$INPUT" | jq -r '.task_description // ""')

COMBINED="$SUBJECT $DESCRIPTION"

# Accept either GitHub (#N) or Linear (KEY-N) identifier shape.
if echo "$COMBINED" | grep -qE '#[0-9]+|[A-Z]{2,5}-[0-9]+'; then
  exit 0
fi

# Workflow-shaped task without an issue reference — escalate when a contract
# is in place and no work-state is active. HOMEBASE_OFF_CONTRACT=1 is the
# escape hatch for tasks that legitimately don't need an issue (research,
# governance, planning).
WORKFLOW_KEYWORDS_RE='\b(fix|feature|bug|add|implement|refactor|migrate|wire|ship|release)\b'
REPO_ROOT_HOOK="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

# HMB-87 B.11: resolve the SHA-keyed per-worktree work-state via the loader so
# the no-active-state escalation honours per-worktree state files.
WORK_STATE_HOOK=""
if [[ -n "$REPO_ROOT_HOOK" && -f "$REPO_ROOT_HOOK/scripts/lib/workflow-loader.sh" ]]; then
  # shellcheck source=../lib/workflow-loader.sh
  . "$REPO_ROOT_HOOK/scripts/lib/workflow-loader.sh"
  WORK_STATE_HOOK="$(work_state_path "$REPO_ROOT_HOOK" 2>/dev/null || echo "")"
fi
[[ -z "$WORK_STATE_HOOK" && -n "$REPO_ROOT_HOOK" ]] && WORK_STATE_HOOK="$REPO_ROOT_HOOK/.homebase/work-state.json"

if [[ -n "$REPO_ROOT_HOOK" \
      && -f "$REPO_ROOT_HOOK/.homebase/workflow.yml" \
      && "${HOMEBASE_OFF_CONTRACT:-0}" != "1" ]] \
      && echo "$COMBINED" | grep -qiE "$WORKFLOW_KEYWORDS_RE" \
      && [[ ! -f "$WORK_STATE_HOOK" \
            || "$(jq -r '.finished // true' "$WORK_STATE_HOOK" 2>/dev/null)" == "true" ]]; then
  echo "Workflow-shaped task \"$SUBJECT\" has no issue reference and no active work-state." >&2
  echo "  Run 'homebase work start <KEY>' first, or set HOMEBASE_OFF_CONTRACT=1 for off-contract work." >&2
  exit 2
fi

# Fire the nudge at most once per Claude Code session. $PPID is the parent
# Claude Code process and is stable across all hook invocations in a session;
# when Claude Code restarts, $PPID changes and the next unlinked task nudges
# once more.
SENTINEL="${TMPDIR:-/tmp}/claude-task-nudge-$PPID.flag"
if [ -e "$SENTINEL" ]; then
  exit 0
fi
: > "$SENTINEL"

echo "Reminder: \"$SUBJECT\" has no #N — link an issue before code lands (SOP-001)." >&2
exit 2
