#!/usr/bin/env bash
# Validate a commit message against HOMEBASE-SOP-001 (Development Workflow) § Issue
# Reference Trailers.
#
# This script is the single source of truth for the commit-message policy.
# It backs both the git `commit-msg` hook (via the thin wrapper at
# `.githooks/commit-msg`) and the Claude Code `PreToolUse` hook
# (`claude-precommit.sh`) so the two entry points stay in lockstep.
#
# Usage:
#   commit-sop-check.sh <path-to-commit-msg-file>     # git commit-msg mode
#   printf '%s' "$MSG" | commit-sop-check.sh          # stdin mode (Claude hook)
#
# Exit codes:
#   0 — message is compliant (or does not reference any issue at all).
#   1 — message violates HOMEBASE-SOP-001. Reason is printed to stderr.
#
# Canonical policy: ~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md
# Vendored into each project; do not edit copies. Edit in homebase, then run
# `homebase sync <project>` to propagate.

set -uo pipefail

# Single source of truth for issue-trailer regexes. Both this validator and
# `task-completed.sh` source the same lib, so they cannot drift.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/issue-trailer.sh
. "${HOOK_DIR}/../lib/issue-trailer.sh"

if [[ $# -ge 1 ]] && [[ -f "$1" ]]; then
  MSG=$(cat "$1")
else
  MSG=$(cat -)
fi

# Strip comment lines (git COMMIT_EDITMSG convention) so we validate the
# actual message, not the editor scaffolding.
MSG_CLEAN=$(printf '%s\n' "$MSG" | grep -v '^#' || true)

# Exempt categories — these commits do not require an issue reference at all.
# Matched on the subject (first) line.
#   Release {AppName} {version}        — tag-cut commits
#   Post-release: ...                  — post-release housekeeping
#   Merge ...                          — merge commits
#   chore: ...                         — governance/tooling/deps/CI (case-insensitive)
SUBJECT=$(printf '%s\n' "$MSG_CLEAN" | head -1)
IS_EXEMPT=0
if printf '%s' "$SUBJECT" | grep -Eq '^(Release |Post-release:|Merge )'; then
  IS_EXEMPT=1
fi
if printf '%s' "$SUBJECT" | grep -Eiq '^chore(\([^)]+\))?:'; then
  IS_EXEMPT=1
fi

# Exempt commits: no further checks. Chore commits that happen to reference
# an issue with a valid trailer are fine; chore commits that use an
# anti-pattern trailer skip the anti-pattern check. That's acceptable: the
# point of the chore exemption is that these commits are not tracked via
# issues at all.
if [[ $IS_EXEMPT -eq 1 ]]; then
  exit 0
fi

# Anti-pattern trailers: plausible English, but NOT GitHub or Linear auto-close
# keywords. A commit with only `Part of #N` / `Related to TFD-9` / `See HMB-3`
# reads correctly to a human but leaves the issue open — the automation the
# SOP is designed to drive silently breaks.
# Match on a line of its own, case-insensitive. Accepts either #N or KEY-N.
# Pattern source: scripts/lib/issue-trailer.sh (ANTI_PATTERN_LINE_RE).
ANTI_MATCH=$(printf '%s\n' "$MSG_CLEAN" | grep -Ein "$ANTI_PATTERN_LINE_RE" | head -1 || true)
if [[ -n "$ANTI_MATCH" ]]; then
  cat >&2 <<EOF

HOMEBASE-SOP-001 VIOLATION — non-compliant issue-reference trailer:

  ${ANTI_MATCH}

The auto-close parser (GitHub or Linear) only recognises:

  | Stage                | GitHub       | Linear         |
  |----------------------|--------------|----------------|
  | Intermediate         | Refs #N      | Refs KEY-N     |
  | Final (enhancement)  | Closes #N    | Closes KEY-N   |
  | Final (bug)          | Fixes #N     | Fixes KEY-N    |
  | Final (alt)          | Resolves #N  | Resolves KEY-N |

\`Part of\`, \`Related\`, \`See\`, \`References\` are NOT in the set — they read
correctly to a human but leave the issue open, so the automation the SOP
is designed to drive silently breaks.

Body prose may still use \`(part of #N)\` or \`(part of KEY-N)\` in parentheses
for partial-work context — but a trailer line, if present, must be one of
the four keywords above.

Full SOP: ~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md
EOF
  exit 1
fi

# Issue-reference required (issue-first rule). Non-exempt commits MUST
# reference a tracked issue (GitHub #N or Linear KEY-N) somewhere in the
# message. Developers who need to land a commit without an issue should use
# one of the exempt prefixes (chore:, Release, Post-release:, Merge).
if ! printf '%s\n' "$MSG_CLEAN" | grep -Eiq "$ISSUE_REF_RE"; then
  cat >&2 <<EOF

HOMEBASE-SOP-001 VIOLATION — commit does not reference a tracked issue.

Every feature or bug commit MUST reference a tracked issue, in either form:

  GitHub:  #N            e.g. #412
  Linear:  KEY-N         e.g. TFD-123, HMB-7

Add one of the following on its own line at the end of the commit body:

  Refs #N        | Refs KEY-N        (intermediate commit)
  Closes #N      | Closes KEY-N      (final commit on an enhancement)
  Fixes #N       | Fixes KEY-N       (final commit on a bug)

If this commit genuinely has no associated issue (governance, tooling,
dependency updates, CI config, doc typos, etc.), use one of the exempt
subject prefixes — no issue reference is required:

  chore: ...
  Release {App} {version}
  Post-release: ...
  Merge ...

Full SOP: ~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md
EOF
  exit 1
fi

# Valid trailer presence check: when the message references an issue, it
# MUST carry a valid trailer keyword on its own line. This catches the case
# where someone mentions #N or KEY-N mid-body but forgets the trailer
# entirely, and the case where someone writes \`(part of #N)\` in prose but
# no trailer.
# Pattern source: scripts/lib/issue-trailer.sh (TRAILER_LINE_RE).
if ! printf '%s\n' "$MSG_CLEAN" | grep -Eiq "$TRAILER_LINE_RE"; then
  cat >&2 <<EOF

HOMEBASE-SOP-001 VIOLATION — the message references an issue but has no valid trailer.

Add one of the following on its own line at the end of the commit body
(GitHub #N and Linear KEY-N are both accepted — see SOP-001 §0):

  Refs #N      | Refs KEY-N      (intermediate commit)
  Closes #N    | Closes KEY-N    (final commit on an enhancement)
  Fixes #N     | Fixes KEY-N     (final commit on a bug)

Body prose \`(part of #N)\` or \`(part of KEY-N)\` alone does not satisfy the
rule — a trailer line is also required.

Full SOP: ~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md
EOF
  exit 1
fi

# ── Wrong-branch commit-policy gate (HMB-45 Finding 8) ───────────────────────
#
# When an active work-state exists, refuse commits whose current branch
# differs from `work-state.branch`. Catches the failure mode where edits
# land on main (or any branch other than the one the work-state expects)
# while a worktree-style work-state is active. Pairs with F7's
# cwd-misroute prevention and F9's commits-present finish gate as the
# belt-and-suspenders line — F7 prevents the wrong start, F8 catches the
# wrong commit, F9 catches the empty-range finish that follows.
#
# Escape hatches (in priority order):
#   - HOMEBASE_OFF_CONTRACT=1            — operator-acknowledged off-contract commit
#   - state.finished == true             — the work-state is closed; no comparison needed
#   - state.branch unset                 — malformed work-state; skip rather than misfire
#   - no .homebase/work-state.json       — no active work-state; nothing to compare
#   - detached HEAD                      — no symbolic ref to compare against; skip
#   - missing jq                         — degrade gracefully (rare on operator machines)

if [[ "${HOMEBASE_OFF_CONTRACT:-0}" != "1" ]] && command -v jq >/dev/null 2>&1; then
  REPO_ROOT_FOR_GATE="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [[ -n "$REPO_ROOT_FOR_GATE" ]]; then
    # HMB-87 B.11: resolve the SHA-keyed per-worktree state path via the
    # loader. Falls back to the legacy single-file path if the loader
    # symlink isn't present (mid-migration safety).
    STATE_FILE=""
    if [[ -f "$REPO_ROOT_FOR_GATE/scripts/lib/workflow-loader.sh" ]]; then
      # shellcheck source=../lib/workflow-loader.sh
      . "$REPO_ROOT_FOR_GATE/scripts/lib/workflow-loader.sh"
      STATE_FILE="$(work_state_path "$REPO_ROOT_FOR_GATE" 2>/dev/null || echo "")"
    fi
    [[ -z "$STATE_FILE" ]] && STATE_FILE="$REPO_ROOT_FOR_GATE/.homebase/work-state.json"
    if [[ -f "$STATE_FILE" ]]; then
      WS_FINISHED="$(jq -r '.finished // false' "$STATE_FILE" 2>/dev/null || echo "true")"
      if [[ "$WS_FINISHED" != "true" ]]; then
        WS_BRANCH="$(jq -r '.branch // ""' "$STATE_FILE" 2>/dev/null || echo "")"
        WS_ISSUE="$(jq -r '.issue // ""' "$STATE_FILE" 2>/dev/null || echo "")"
        CUR_BRANCH="$(git -C "$REPO_ROOT_FOR_GATE" symbolic-ref --short HEAD 2>/dev/null || echo "")"
        if [[ -n "$WS_BRANCH" && -n "$CUR_BRANCH" && "$WS_BRANCH" != "$CUR_BRANCH" ]]; then
          cat >&2 <<EOF

HOMEBASE-SOP-001 VIOLATION — wrong-branch commit (HMB-45 Finding 8):

  active work-state for ${WS_ISSUE} expects commits on branch:  ${WS_BRANCH}
  current branch is:                                            ${CUR_BRANCH}

This usually means edits landed in the main checkout instead of the
worktree the active work-state created. Two recovery paths:

  - cd \$(homebase work goto ${WS_ISSUE})  (and source .homebase/.work-env)
    re-apply the change in the right worktree, commit there.

  - if the commit is genuinely off-contract chore work that should land
    on this branch (e.g. a typo fix, governance edit), re-run with
    HOMEBASE_OFF_CONTRACT=1 prefixed.

  - if the work-state is stale (the work was finished out-of-band), run
    'homebase work finish' or 'homebase work cancel' first.

Full SOP: ~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md
EOF
          exit 1
        fi
      fi
    fi
  fi
fi

# ── Warn-only: UI-touching commit without SOP-007 trailer (HMB-59) ───────────
#
# Shift-left mirror of `scripts/hooks/ui-verification-check.sh` (the Stop-hook
# gate). That gate fires AFTER commit + AFTER Stop, where remediation costs
# ~30 minutes (spin up dev server, seed scenarios, rebase). This warn fires
# BEFORE the commit lands, where remediation costs ~2 minutes: notice the
# warning, render the change in Chrome MCP / simulator, append the trailer,
# re-commit.
#
# Non-blocking: exit code stays 0. The strict block remains at the Stop-hook
# + the `homebase work finish` gate. This avoids duplicating finish-gate
# semantics at commit time (mid-branch WIP commits legitimately may not be
# verified yet) while still surfacing the gap as early as possible.
#
# Set HOMEBASE_UI_VERIFICATION=off to skip even this warning. The exempt
# subject prefixes (chore:, Release, Post-release:, Merge) already exit
# earlier in this script, so the warn cannot fire on them.
if [[ "${HOMEBASE_UI_VERIFICATION:-}" != "off" ]]; then
  HOOK_DIR_FOR_UI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  # shellcheck source=../lib/ui-pattern.sh
  . "${HOOK_DIR_FOR_UI}/../lib/ui-pattern.sh"

  REPO_ROOT_FOR_UI="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
  if [[ -n "$REPO_ROOT_FOR_UI" ]]; then
    STAGED_FILES="$(git -C "$REPO_ROOT_FOR_UI" diff --cached --name-only 2>/dev/null || echo "")"
    if [[ -n "$STAGED_FILES" ]] && \
       homebase_ui_files_touch_ui "$REPO_ROOT_FOR_UI" "$STAGED_FILES" && \
       ! homebase_ui_msg_has_trailer "$MSG_CLEAN"; then
      cat >&2 <<'EOF'

HOMEBASE-SOP-007 WARNING — this commit touches UI files but has no Verified trailer.

The Stop-hook + `homebase work finish` gate 9 will block on this; remediating
at finish-time costs ~30 minutes (spin up dev server, seed scenarios,
non-interactive rebase). Add the trailer NOW (a body line on this commit, or
amend with `--amend` after the commit lands):

  Verified in browser: <one-sentence observation of the rendered state>
  Verified by XCUITest: <test name — destination>
  Verified on simulator: <one-sentence observation of the rendered state>

(See HOMEBASE-SOP-007 § "What counts as verification" for the full set,
including the `UI verification waived:` and `UI verification skipped:`
escape valves.)

This is a warning only — the commit will land. The strict block lives at
`scripts/hooks/ui-verification-check.sh` (Stop-hook) and gate 9 of
`homebase work finish`. Set `HOMEBASE_UI_VERIFICATION=off` to suppress this
warning.

EOF
    fi
  fi
fi

exit 0
