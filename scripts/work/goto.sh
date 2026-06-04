#!/usr/bin/env bash
# scripts/work/goto.sh — `homebase work goto <KEY>` (HMB-27).
#
# Prints the absolute path of the worktree for <KEY> in the current
# project (looked up by branch + per-worktree work-state.json).
# Operators wrap the call in a cd:
#
#   cd "$(homebase work goto HMB-27)"
#
# Exit codes:
#   0 — worktree found, path written to stdout
#   2 — usage error (missing argument)
#   3 — no matching worktree
#
# Args: <KEY>

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./lib/worktree.sh
. "${WORK_DIR}/lib/worktree.sh"

usage() {
  cat <<EOF
usage: homebase work goto <KEY>

Prints the absolute path of the worktree for <KEY> in this project.
Wrap in cd: \`cd \$(homebase work goto HMB-27)\`.
EOF
}

if [[ $# -lt 1 ]]; then
  usage >&2
  exit 2
fi

case "$1" in
  -h|--help) usage; exit 0 ;;
esac

KEY="$1"

ROOT="$(worktree_project_root)" || {
  echo "homebase work goto: not inside a homebase-managed git repo" >&2
  exit 2
}

WT="$(worktree_for_issue "$KEY" "$ROOT")"
if [[ -z "$WT" ]]; then
  echo "homebase work goto: no active worktree found for $KEY in $ROOT" >&2
  exit 3
fi

echo "$WT"
