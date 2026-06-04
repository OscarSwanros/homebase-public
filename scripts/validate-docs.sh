#!/usr/bin/env bash
# validate-docs.sh — canonical documentation validator for any homebase-adopting project.
# Run from the project repository root.
#
# Universal checks always run. Project-specific checks come from an optional
# `scripts/validate-docs-project.sh` that the project ships at its repo root.
# The project script can use the exported helper functions (error, warning,
# ok) and counters (ERRORS, WARNINGS). See § "Project extension" at the
# bottom for the interface.
#
# Canonical source: ~/code/homebase/scripts/validate-docs.sh
# Symlinked into each project — do not duplicate.

set -e

ERRORS=0
WARNINGS=0

red()    { echo -e "\033[31m$1\033[0m"; }
yellow() { echo -e "\033[33m$1\033[0m"; }
green()  { echo -e "\033[32m$1\033[0m"; }

error()   { red "  ERROR: $1"; ERRORS=$((ERRORS + 1)); }
warning() { yellow "  WARN:  $1"; WARNINGS=$((WARNINGS + 1)); }
ok()      { green "  OK:    $1"; }

# Export so the project extension can use them.
export -f red yellow green error warning ok

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$REPO_ROOT"

PROJECT_NAME=$(basename "$REPO_ROOT")

echo "=== ${PROJECT_NAME} Documentation Validation ==="
echo ""

# 1. Verify all @ references in CLAUDE.md resolve to existing files
echo "--- Checking @ references in CLAUDE.md ---"
if [ -f "CLAUDE.md" ]; then
  while IFS= read -r ref; do
    path=$(echo "$ref" | sed 's/@//')
    # Expand leading ~ if present (homebase refs use absolute paths).
    expanded_path="${path/#\~/$HOME}"
    # Worktree fallback (HMB-60): when validating homebase itself from a
    # git worktree, refs like `@~/code/homebase/sops/...` resolve to the
    # main worktree's path — where newly-added files don't exist yet. If
    # we're in homebase, also accept the same relative path resolved
    # against the worktree's REPO_ROOT, so new SOPs introduced in a
    # feature branch can be referenced from CLAUDE.md without first
    # landing in main.
    if [ ! -e "$expanded_path" ] && { [ "$PROJECT_NAME" = "homebase" ] || [[ "$REPO_ROOT" == */.worktrees/* ]]; }; then
      worktree_path="${path/#\~\/code\/homebase/$REPO_ROOT}"
      if [ -e "$worktree_path" ]; then
        expanded_path="$worktree_path"
      fi
    fi
    if [ -e "$expanded_path" ]; then
      ok "@$path exists"
    else
      error "@$path does not exist (referenced in CLAUDE.md)"
    fi
  done < <(grep -oE '@[~A-Za-z][~A-Za-z0-9/_.-]+\.md' CLAUDE.md | sort -u)
else
  warning "CLAUDE.md not found at repo root"
fi
echo ""

# 2. Check no .txt files exist in Documentation/
if [ -d "Documentation" ]; then
  echo "--- Checking for .txt files in Documentation/ ---"
  txt_files=$(find Documentation/ -name "*.txt" 2>/dev/null || true)
  if [ -z "$txt_files" ]; then
    ok "No .txt files in Documentation/"
  else
    for f in $txt_files; do
      error "$f should be .md, not .txt"
    done
  fi
  echo ""
fi

# 3. Check no .md files at repo root except CLAUDE.md, README.md
echo "--- Checking for stray .md files at repo root ---"
for f in *.md; do
  [ -f "$f" ] || continue
  if [ "$f" != "CLAUDE.md" ] && [ "$f" != "README.md" ]; then
    error "$f exists at repo root (only CLAUDE.md and README.md allowed)"
  fi
done
ok "Root directory check complete"
echo ""

# 4. Check CLAUDE.md line count
if [ -f "CLAUDE.md" ]; then
  echo "--- Checking CLAUDE.md size ---"
  line_count=$(wc -l < CLAUDE.md)
  if [ "$line_count" -le 250 ]; then
    ok "CLAUDE.md is $line_count lines (under 250 limit per HOMEBASE-SOP-003)"
  else
    warning "CLAUDE.md is $line_count lines (target: under 250 per HOMEBASE-SOP-003)"
  fi
  echo ""
fi

# 5. Check HOMEBASE-SOP-003 is referenced
echo "--- Checking HOMEBASE-SOP-003 adoption declaration ---"
if grep -q 'HOMEBASE-SOP-003' CLAUDE.md 2>/dev/null; then
  ok "HOMEBASE-SOP-003 Documentation Governance referenced in CLAUDE.md"
else
  warning "HOMEBASE-SOP-003 Documentation Governance not referenced in CLAUDE.md (§ Adopted SOPs)"
fi
echo ""

# 6. Project extension
# If the project ships scripts/validate-docs-project.sh, source it. It can
# add arbitrary checks using the helper functions declared above. Example:
#
#   # scripts/validate-docs-project.sh
#   for app in iOS/Apps/GasCalc iOS/Apps/LogApp; do
#     if [ -f "$app/CLAUDE.md" ]; then ok "$app/CLAUDE.md exists"
#     else error "$app/CLAUDE.md is missing"; fi
#   done
#
if [ -f "scripts/validate-docs-project.sh" ]; then
  echo "--- Running project-specific checks ---"
  # shellcheck source=/dev/null
  . "scripts/validate-docs-project.sh"
  echo ""
fi

# Summary
echo "=== Validation Summary ==="
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  green "All checks passed!"
elif [ "$ERRORS" -eq 0 ]; then
  yellow "$WARNINGS warning(s), 0 errors"
else
  red "$ERRORS error(s), $WARNINGS warning(s)"
  exit 1
fi
