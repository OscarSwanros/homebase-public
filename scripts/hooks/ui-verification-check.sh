#!/usr/bin/env bash
# Hook: Stop — enforce HOMEBASE-SOP-007 UI verification on recent commits.
#
# Scans commits on the current branch that have been made during this
# working period (unpushed to the upstream, or if none, HEAD only) for
# touches to UI-rendered files. If any such commit lacks the required
# verification trailer, the hook exits non-zero to warn the agent.
#
# Trailers accepted (HOMEBASE-SOP-007):
#   Verified in browser: <observation>            (web gate)
#   Verified by XCUITest: <test — destination>    (Apple gate, SOP-007 § Apple-platform Gate)
#   Verified on simulator: <observation>          (Android gate; supplementary on Apple)
#   Verified on device: <observation>             (supplementary on Apple)
#   UI verification waived: <reason>              (Apple-only escape; cite reference + follow-up issue)
#   UI verification skipped: <reason>             (audited — use sparingly)
#
# Modes (HOMEBASE_UI_VERIFICATION env var):
#   unset | strict  Default. Block on every Stop that sees an unverified
#                   UI commit. No warn-once leak — strict means strict.
#                   Intended for local machines with Chrome MCP.
#   warn            Print the violation but never block. Dedupes per-SHA
#                   per session so logs stay quiet on repeated Stops. For
#                   remote/headless sessions that can't render a browser.
#   off             Skip the check entirely.
#
# Exit codes:
#   0 — no UI commits, all verified, or mode is warn/off.
#   2 — strict mode and at least one unverified UI commit was found.
#
# Project-specific exclusions: a project may add UI-file globs to an
# optional `.ui-verification-excludes` file at the repo root (one glob
# per line, re-evaluated each invocation). See HOMEBASE-SOP-007 § Exclusions.
#
# Canonical source: ~/code/homebase/scripts/hooks/ui-verification-check.sh
# Symlinked into each project — do not duplicate.

set -uo pipefail

# Single source of truth for UI pattern + trailer regex + project-exclude
# loading. Both this Stop-hook and the commit-msg warn-only mirror in
# `commit-sop-check.sh` source the same lib, so the two cannot drift on
# "what counts as UI" or "what counts as a verification trailer". (HMB-59.)
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/ui-pattern.sh
. "${HOOK_DIR}/../lib/ui-pattern.sh"

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
  exit 0
fi
cd "$REPO_ROOT"

MODE="${HOMEBASE_UI_VERIFICATION:-strict}"
if [[ "$MODE" == "off" ]]; then
  exit 0
fi

# Short-circuit when invoked from inside `homebase work finish` — finish has
# already validated UI verification at gate 9. Avoids a double-block on the
# legal path (finish-then-Stop-hook).
if [[ "${HOMEBASE_WORK_PHASE:-}" == "finish" ]]; then
  exit 0
fi

# Determine the commit range to inspect.
#   Prefer @{u}..HEAD (unpushed commits on current branch).
#   If no upstream, use commits unique to this branch since diverging
#   from origin/main — avoids nagging about commits already on main.
#   Final fallback: last 5 commits.
RANGE=""
if UPSTREAM=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null); then
  RANGE="${UPSTREAM}..HEAD"
elif BASE=$(git merge-base HEAD origin/main 2>/dev/null); then
  RANGE="${BASE}..HEAD"
else
  RANGE="HEAD~5..HEAD"
fi

COMMITS=$(git log "$RANGE" --format=%H 2>/dev/null || true)
if [[ -z "$COMMITS" ]]; then
  exit 0
fi

# UI-rendered file patterns and exclude pattern are loaded from
# `scripts/lib/ui-pattern.sh` (sourced above). Project-specific exclusions
# from `<repo_root>/.ui-verification-excludes` are merged in by
# `homebase_ui_load_project_excludes`. Detailed pattern documentation
# lives in the lib.
EXCLUDE_PATTERN=$(homebase_ui_load_project_excludes "$REPO_ROOT")
UI_PATTERN="$UI_PATTERN_RE"

VIOLATIONS=()

for sha in $COMMITS; do
  FILES=$(git show --name-only --format= "$sha" 2>/dev/null || true)
  if [[ -z "$FILES" ]]; then
    continue
  fi

  RELEVANT=$(echo "$FILES" | grep -Ev "$EXCLUDE_PATTERN" || true)
  if [[ -z "$RELEVANT" ]]; then
    continue
  fi

  if ! echo "$RELEVANT" | grep -Eq "$UI_PATTERN"; then
    continue
  fi

  MSG=$(git log -1 --format=%B "$sha" 2>/dev/null || true)
  if homebase_ui_msg_has_trailer "$MSG"; then
    continue
  fi

  SHORT=$(git rev-parse --short "$sha")
  SUBJECT=$(git log -1 --format=%s "$sha")
  VIOLATIONS+=("${sha}|${SHORT} ${SUBJECT}")
done

if [[ ${#VIOLATIONS[@]} -eq 0 ]]; then
  exit 0
fi

# Warn mode: dedupe per-SHA per session so the log line only appears once
# per offending commit. Strict mode (below) intentionally does NOT dedupe
# — every Stop with an outstanding violation blocks. The earlier
# warn-once-then-fall-silent design (TFD-1408 retrospective) was a
# single point of failure: one warning per session effectively meant
# strict mode degraded to warn mode for the rest of the session.
if [[ "$MODE" == "warn" ]]; then
  WARNED_FILE="$REPO_ROOT/.claude/.ui-verification-warned"
  mkdir -p "$(dirname "$WARNED_FILE")"
  touch "$WARNED_FILE"

  NEW_VIOLATIONS=()
  for entry in "${VIOLATIONS[@]}"; do
    sha="${entry%%|*}"
    if ! grep -qxF "$sha" "$WARNED_FILE"; then
      NEW_VIOLATIONS+=("$entry")
    fi
  done

  if [[ ${#NEW_VIOLATIONS[@]} -eq 0 ]]; then
    # All violations already warned about this session — stay quiet.
    exit 0
  fi

  echo ""
  echo "HOMEBASE-SOP-007 — UI-touching commit(s) without verification trailer (warn mode):"
  for entry in "${NEW_VIOLATIONS[@]}"; do
    echo "  ${entry#*|}"
    echo "${entry%%|*}" >> "$WARNED_FILE"
  done
  exit 0
fi

# Strict mode — block on every Stop while any violation is outstanding.
echo ""
echo "HOMEBASE-SOP-007 VIOLATION — UI-touching commit(s) without verification trailer:"
echo ""
for entry in "${VIOLATIONS[@]}"; do
  echo "  ${entry#*|}"
done
echo ""
echo "UI changes must be rendered and observed before being claimed complete."
echo "Start the dev server or simulator, load the affected surface, capture a"
echo "screenshot via Chrome MCP (\`mcp__claude-in-chrome__*\`) or"
echo "\`xcrun simctl io booted screenshot\`, then amend the commit with a"
echo "trailer describing what you actually observed:"
echo ""
echo "  Verified in browser: <one-sentence observation of the rendered state>"
echo "  Verified by XCUITest: <test name — destination>"
echo "  Verified on simulator: <one-sentence observation of the rendered state>"
echo ""
echo "On Apple platforms (iOS/iPadOS/macOS/visionOS/watchOS) a passing"
echo "XCUITest is the gate — manual simulator screenshots are supplementary."
echo "See HOMEBASE-SOP-007 § Apple-platform Gate."
echo ""
echo "If the Apple-platform waiver clause applies (near-exact mirror of"
echo "already-shipping UI in the same codebase), use:"
echo "  UI verification waived: <reason citing reference + follow-up issue>"
echo ""
echo "If the change truly has no rendered surface (see HOMEBASE-SOP-007 § Scope),"
echo "use"
echo "  UI verification skipped: <reason>"
echo "and expect TPM to review it."
echo ""
echo "Remote/headless session? Set HOMEBASE_UI_VERIFICATION=warn (print only)"
echo "or off (skip) in your shell profile. HOMEBASE-SOP-007 still applies — the"
echo "hook just stops blocking when rendering isn't possible."
echo ""
echo "Full SOP: ~/code/homebase/sops/HOMEBASE-SOP-007-UI_VERIFICATION.md"

exit 2
