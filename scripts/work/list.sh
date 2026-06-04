#!/usr/bin/env bash
# scripts/work/list.sh — `homebase work list` (HMB-27).
#
# Lists every active worktree under <project>/.worktrees/ in the current
# project: KEY → branch → path → Linear state. Skips the main checkout.
# Reads each worktree's .homebase/work-state.json for KEY + linear_state.
#
# Exit codes:
#   0 — listed (table or "no worktrees" message)
#   2 — not inside a homebase-managed git repo

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./lib/worktree.sh
. "${WORK_DIR}/lib/worktree.sh"

usage() {
  cat <<EOF
usage: homebase work list

Lists active worktrees in the current project.
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

ROOT="$(worktree_project_root)" || {
  echo "homebase work list: not inside a homebase-managed git repo" >&2
  exit 2
}

ROWS="$(worktree_list "$ROOT")"
if [[ -z "$ROWS" ]]; then
  echo "no active worktrees in $ROOT/.worktrees/"
  exit 0
fi

# Pretty table.
{
  printf 'KEY\tBRANCH\tPATH\tLINEAR\n'
  printf '%s\n' "$ROWS"
} | column -ts $'\t'
