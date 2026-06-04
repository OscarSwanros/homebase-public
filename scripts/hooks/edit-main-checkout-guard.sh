#!/usr/bin/env bash
# scripts/hooks/edit-main-checkout-guard.sh — Claude Code PreToolUse hook
# for Edit / Write / MultiEdit / NotebookEdit.
#
# HMB-87 B.10: belt-and-suspenders for the session-spawn flow (B.12). The
# wrapper `bin/homebase-claude` prevents the failure mode by default —
# sessions in worktree-enabled projects spawn inside `.worktrees/session-<id>/`
# so they can't accidentally land edits on the main checkout. This hook
# covers the bypass paths: operator runs `HOMEBASE_NO_SPAWN_WORKTREE=1 claude`,
# uses `command claude`, passes `--no-spawn-worktree`, or opens a session
# from before the wrapper was installed.
#
# Denies when ALL of:
#   - target file path is inside a worktree-enabled project's main checkout
#     (i.e. NOT under `<project>/.worktrees/...`)
#   - no active work-state exists for the current Claude cwd (so the agent
#     is operating off-contract from the workflow's perspective)
#   - HOMEBASE_OFF_CONTRACT=1 is unset (the canonical escape hatch)
#
# Remediation message names the three paths back to compliance:
#   1. `homebase work start <KEY>` — for tracked work on an issue
#   2. `homebase work chore "<desc>"` — for unticketed governance / chore work
#      (verb lands in HMB-87 Issue B Phase 1 / HMB-86)
#   3. `HOMEBASE_OFF_CONTRACT=1` — explicit operator opt-out
#
# Allows silently (exit 0 no output) in every other case so the hook stays
# transparent for non-homebase projects, worktree-mode-disabled projects,
# edits already inside an active worktree, or already-opted-out sessions.

set -uo pipefail

INPUT=$(cat)

# Extract tool_input.file_path (Edit / Write / NotebookEdit) or
# tool_input.notebook_path (NotebookEdit's older shape).
TARGET=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = data.get('tool_input', {}) or {}
# MultiEdit's file_path is the single canonical target; per-edit paths in
# its 'edits' array all refer back to the same file.
print(ti.get('file_path') or ti.get('notebook_path') or '')
" 2>/dev/null) || exit 0

# No target → nothing to gate on.
[[ -z "$TARGET" ]] && exit 0

# Resolve to absolute path. Python's os.path.realpath handles missing
# files (Write creates new files) and symlinks consistently across
# Linux + macOS — BSD realpath lacks the `-m` flag, and GNU readlink -f
# isn't installed by default on macOS. Python is already a hook dep.
ABS_TARGET="$(python3 -c "
import os, sys
print(os.path.realpath(sys.argv[1]))
" "$TARGET" 2>/dev/null || echo "$TARGET")"

# Walk up from the target file's parent directory to find a homebase
# project root (a directory containing `.homebase/project.yml`).
TARGET_DIR="$(dirname "$ABS_TARGET")"
PROJECT_ROOT=""
cur="$TARGET_DIR"
while [[ "$cur" != "/" && -n "$cur" ]]; do
  if [[ -f "$cur/.homebase/project.yml" ]]; then
    PROJECT_ROOT="$cur"
    break
  fi
  cur="$(dirname "$cur")"
done

# Not a homebase project → allow.
[[ -z "$PROJECT_ROOT" ]] && exit 0

# Project doesn't have worktree mode enabled → allow.
if ! grep -A 2 '^worktree:' "$PROJECT_ROOT/.homebase/project.yml" 2>/dev/null \
   | grep -q '^[[:space:]]*enabled:[[:space:]]*true'; then
  exit 0
fi

# Determine the main checkout. If PROJECT_ROOT is itself the main, that's
# our answer; otherwise we may have walked up from inside a worktree's
# tracked tree (worktrees contain `.homebase/project.yml` too).
# `git -C <path> rev-parse --git-common-dir` returns `.git` (relative to
# CWD) when inside the main checkout, an absolute path otherwise. `pwd -P`
# normalises symlinks (e.g. /var → /private/var on macOS) so the prefix
# match against ABS_TARGET works regardless of which side realpath
# resolved first.
MAIN_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && \
  common="$(git rev-parse --git-common-dir 2>/dev/null)" && \
  ( cd "$common" 2>/dev/null && cd .. && pwd -P ) )"
[[ -z "$MAIN_ROOT" ]] && exit 0

# If the target is inside any `.worktrees/...` directory under the main,
# it's a worktree-resident edit — that's the GOOD case, allow.
if [[ "$ABS_TARGET" == "$MAIN_ROOT/.worktrees/"* ]]; then
  exit 0
fi
# Symlink-fallback: on macOS, /tmp resolves to /private/tmp via realpath
# but `pwd -P` from inside `/tmp/...` keeps the un-prefixed form when the
# worktree directory was created via the un-prefixed path. Try the other
# direction too so we don't false-deny on filesystem-layout quirks.
if [[ "$ABS_TARGET" == "/private$MAIN_ROOT/.worktrees/"* ]]; then
  exit 0
fi

# Target is in the main checkout (or somewhere else under MAIN_ROOT that
# isn't a worktree). Continue with the deny logic.

# Operator opt-out → allow.
if [[ "${HOMEBASE_OFF_CONTRACT:-0}" == "1" ]]; then
  exit 0
fi

# Active work-state for the current cwd → allow. The cwd-based work-state
# means the operator has authorised this work; the edit landing in main is
# a wrong-branch problem the commit-sop-check hook will catch with a
# clearer message, not an off-contract violation.
#
# Path-scheme agnostic: accept either the pre-HMB-87 legacy single-file
# (`<cwd-worktree>/.homebase/work-state.json`) or any SHA-keyed central
# file at the main checkout (`<main>/.homebase/work-state.*.json`). Until
# the SHA-keyed loader propagates to every consuming project's main
# checkout, both shapes legitimately represent active work; refusing
# either would surface a false deny.
CWD_WT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
have_active_state=0
if command -v jq >/dev/null 2>&1; then
  # Legacy single-file path.
  if [[ -n "$CWD_WT" && -f "$CWD_WT/.homebase/work-state.json" ]]; then
    finished="$(jq -r '.finished // false' "$CWD_WT/.homebase/work-state.json" 2>/dev/null || echo "true")"
    [[ "$finished" == "false" ]] && have_active_state=1
  fi
  # SHA-keyed central files at the main checkout. Any non-finished entry
  # is enough — the hook treats "the operator has work in flight in this
  # project" as authorisation to edit the main checkout (the wrong-branch
  # case is caught later by commit-sop-check.sh with a sharper message).
  if [[ "$have_active_state" -eq 0 ]]; then
    shopt -s nullglob
    for sf in "$MAIN_ROOT/.homebase/"work-state.*.json; do
      [[ "$sf" == *.lock ]] && continue
      f="$(jq -r '.finished // false' "$sf" 2>/dev/null || echo "true")"
      if [[ "$f" == "false" ]]; then have_active_state=1; break; fi
    done
    shopt -u nullglob
  fi
fi
if [[ "$have_active_state" -eq 1 ]]; then
  exit 0
fi

# All conditions met — deny with remediation.
jq -n --arg target "$TARGET" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason:
      "edit-main-checkout-guard (HMB-87 B.10): refusing to edit `\($target)` — it lives in the main checkout of a worktree-enabled project, and this Claude session has no active work-state.\n\nThree ways forward:\n  1. `homebase work start <KEY>`   — for tracked work on a Linear issue (creates a worktree, transitions Linear backlog→in_progress).\n  2. `homebase work chore \"<desc>\"`  — for unticketed governance / chore edits (creates a chore worktree; see HMB-86).\n  3. `HOMEBASE_OFF_CONTRACT=1`     — explicit operator opt-out for one shell; reserved for the unfixable cases (debugging homebase-claude, fixing the worktree machinery itself, post-incident hot patches).\n\nThis hook is belt-and-suspenders to HMB-87 B.12. The session-spawn wrapper normally prevents main-checkout sessions; this denial means the wrapper was bypassed (via HOMEBASE_NO_SPAWN_WORKTREE=1, `command claude`, or a session that pre-dates the wrapper install)."
  }
}'
exit 0
