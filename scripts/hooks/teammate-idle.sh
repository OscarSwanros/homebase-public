#!/usr/bin/env bash
# Hook: TeammateIdle — block a teammate going idle with uncommitted changes.
#
# stdin: JSON {"teammate_name":"...","team_name":"...","session_id":"..."}
# Exit 2 + stderr = send feedback, teammate keeps working.
#
# Canonical source: ~/code/homebase/scripts/hooks/teammate-idle.sh
# Symlinked into each project — do not duplicate.

set -euo pipefail

if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
  echo "You have uncommitted changes. Commit and push your work before going idle." >&2
  exit 2
fi

exit 0
