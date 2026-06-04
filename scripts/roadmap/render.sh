#!/usr/bin/env bash
# homebase roadmap render — regenerate registry/ROADMAP.md + registry/roadmap-snapshot.yml.
#
# Read-only against Linear. Writes registry/ROADMAP.md and
# registry/roadmap-snapshot.yml — so it cannot legally run on `main` with
# a clean tree (would dirty the working tree without an active branch
# and violate the issue-first workflow, hard rule 4). Pass --allow-on-main
# to override (e.g. for a one-off snapshot capture during recovery).
#
# Canonical source: ~/code/homebase/scripts/roadmap/render.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

allow_on_main=0
forwarded_args=()
for arg in "$@"; do
  case "$arg" in
    --allow-on-main)
      allow_on_main=1
      ;;
    *)
      forwarded_args+=("$arg")
      ;;
  esac
done

if [[ "$allow_on_main" -eq 0 ]]; then
  current_branch="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '')"
  if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
    echo "roadmap render: refused on '$current_branch' — issue-first workflow violation (hard rule 4)." >&2
    echo "  This verb writes registry/ROADMAP.md and registry/roadmap-snapshot.yml; running on" >&2
    echo "  '$current_branch' would dirty the working tree without an active work-state." >&2
    echo "" >&2
    echo "  Fixes:" >&2
    echo "    - Run from a work branch (homebase work start <KEY>), then re-invoke." >&2
    echo "    - Pass --allow-on-main to override (use sparingly; the dirtied registry" >&2
    echo "      files will need to be committed under a chore: prefix or restored)." >&2
    exit 2
  fi
fi

exec ruby "$SCRIPT_DIR/linear.rb" render ${forwarded_args[@]+"${forwarded_args[@]}"}
