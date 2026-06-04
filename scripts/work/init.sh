#!/usr/bin/env bash
# scripts/work/init.sh — `homebase work init`.
#
# Scaffolds <project>/.homebase/workflow.yml from the template. Idempotent.
# Refuses to overwrite an existing file. Called by `homebase link-project`
# (Phase 5) when a project is missing its contract.

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${WORK_DIR}/lib/state.sh"

ROOT="$(find_repo_root)"
[[ -z "$ROOT" ]] && { echo "init: not in a git repo" >&2; exit 2; }

TEMPLATE="$(cd "$WORK_DIR/../.." && pwd -P)/templates/workflow.yml.tmpl"
if [[ ! -f "$TEMPLATE" ]]; then
  # Fall back to homebase canonical path (when called from a project via symlink).
  TEMPLATE="$(readlink "$WORK_DIR/../../templates/workflow.yml.tmpl" 2>/dev/null || echo "")"
fi
if [[ ! -f "$TEMPLATE" ]]; then
  echo "init: cannot locate templates/workflow.yml.tmpl" >&2
  exit 2
fi

DEST="$ROOT/.homebase/workflow.yml"
mkdir -p "$(dirname "$DEST")"

if [[ -f "$DEST" ]]; then
  echo "init: $DEST already exists; refusing to overwrite"
  exit 0
fi

cp "$TEMPLATE" "$DEST"
echo "init: scaffolded $DEST from $TEMPLATE"

# Ensure work-state artefacts are gitignored. work-state.json contains
# session-local state (active issue, branch, gate progress); committing it
# would leak local-only state across sessions.
GITIGNORE="$ROOT/.gitignore"
gi_entries=(
  ".homebase/work-state.json"
  ".homebase/work-state.json.lock"
  ".homebase/work-state.*.json"
  ".homebase/work-state.*.json.lock"
  ".homebase/work-state.audit.log"
  ".homebase/work-finish-*.log"
  ".homebase/.pr-number"
  ".homebase/.work-env"
)
added=0
for entry in "${gi_entries[@]}"; do
  if [[ ! -f "$GITIGNORE" ]] || ! grep -Fxq "$entry" "$GITIGNORE"; then
    echo "$entry" >> "$GITIGNORE"
    added=1
  fi
done
if [[ "$added" -eq 1 ]]; then
  echo "      .gitignore updated with work-state artefacts."
fi

echo "      Edit the file, then run 'bin/homebase render-claudemd' to refresh CLAUDE.md."
exit 0
