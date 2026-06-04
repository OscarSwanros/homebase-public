#!/usr/bin/env bash
# scripts/hooks/pre-push.sh — invoked by .githooks/pre-push.
#
# Layer 2 (inside-git) push-time gate. Catches manual `git push` that
# slipped past Layer 1's PreToolUse, and re-validates finish-push state.
#
# Inputs (per git's pre-push convention):
#   $1: remote name (origin)
#   $2: remote URL
#   stdin: lines of "<local_ref> <local_sha> <remote_ref> <remote_sha>"
#
# When .homebase/workflow.yml is absent the hook is a NO-OP (project hasn't
# adopted the contract). When present:
#   - Refuses unless HOMEBASE_WORK_AUTHORIZED=1.
#   - On HOMEBASE_WORK_PHASE=finish, requires the HEAD commit to carry a
#     closing keyword (Closes/Fixes/Resolves) referencing the work-state issue.
#   - Force-push to main/master/tag refs requires HOMEBASE_FORCE_PUSH_CONFIRMED=1.
#
# Canonical source: ~/code/homebase/scripts/hooks/pre-push.sh
# Symlinked into each project via the .githooks/pre-push wrapper (Phase 5).

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
[[ -z "$REPO_ROOT" ]] && exit 0

WORKFLOW_YML="$REPO_ROOT/.homebase/workflow.yml"

# HMB-87 B.11: resolve the SHA-keyed per-worktree work-state path via the
# loader. Loader is symlinked into every adopting project at
# scripts/lib/workflow-loader.sh; absent it, fall back to the legacy path.
if [[ -f "$REPO_ROOT/scripts/lib/workflow-loader.sh" ]]; then
  # shellcheck source=../lib/workflow-loader.sh
  . "$REPO_ROOT/scripts/lib/workflow-loader.sh"
  WORK_STATE="$(work_state_path "$REPO_ROOT" 2>/dev/null || echo "")"
fi
[[ -z "${WORK_STATE:-}" ]] && WORK_STATE="$REPO_ROOT/.homebase/work-state.json"

# No contract → no enforcement.
[[ -f "$WORKFLOW_YML" ]] || exit 0

# Single source of truth for trailer regex.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../lib/issue-trailer.sh
. "${HOOK_DIR}/../lib/issue-trailer.sh"

REMOTE="${1:-}"
URL="${2:-}"

block() {
  echo
  echo "pre-push: $1" >&2
  echo
  exit 1
}

# ── Authorisation gate ────────────────────────────────────────────────────────
#
# Allow when EITHER an active work-state has authorised this shell
# (HOMEBASE_WORK_AUTHORIZED=1, set by `homebase work` verbs) OR the operator
# has explicitly opted out of contract enforcement for this push
# (HOMEBASE_OFF_CONTRACT=1, for chore / governance / snapshot commits with
# no work-state). Symmetric with work-cli-guard-hook.sh's PreToolUse layer
# per HMB-18 — both layers must accept both env vars or off-contract pushes
# deadlock with no legal path forward.
#
# Force-push to protected refs is gated separately below regardless of which
# auth env var is set (Charter red-list).

if [[ "${HOMEBASE_WORK_AUTHORIZED:-0}" != "1" ]] && [[ "${HOMEBASE_OFF_CONTRACT:-0}" != "1" ]]; then
  block "Manual \`git push\` is forbidden when .homebase/workflow.yml is present.
       Use \`homebase work checkpoint --push\` (mid-flight) or
       \`homebase work finish\` (close-out) for product work. The CLI sets
       HOMEBASE_WORK_AUTHORIZED=1 internally for the duration of its push.

       For chore / off-contract pushes (snapshot updates, governance edits,
       README typos) set HOMEBASE_OFF_CONTRACT=1 in your shell."
fi

# ── Per-ref checks ────────────────────────────────────────────────────────────

# Read the ref-list from stdin.
declare -a REFS=()
while IFS=' ' read -r local_ref local_sha remote_ref remote_sha; do
  REFS+=("$local_ref|$local_sha|$remote_ref|$remote_sha")
done

# Force-push protection: the calling git invocation passes --force /
# --force-with-lease via the parent; we detect it via the remote_sha NOT
# being an ancestor of local_sha (non-fast-forward). In that case,
# require HOMEBASE_FORCE_PUSH_CONFIRMED=1 for protected refs.
#
# Empty REFS happens on a no-op push (e.g. the second `homebase work
# finish` retry after the first run already FF-pushed everything).
# Iterating an empty array under `set -u` raises "REFS[@]: unbound
# variable", so skip the loop entirely when there's nothing to inspect.
# (HMB-36 surfaced this when retrying a finish after gate-10 cleanup.)
for entry in "${REFS[@]+"${REFS[@]}"}"; do
  IFS='|' read -r local_ref local_sha remote_ref remote_sha <<< "$entry"
  # Skip deletions (local_sha is all zeros).
  [[ "$local_sha" =~ ^0+$ ]] && continue
  # Skip new branches (remote_sha is all zeros — fast-forward only by definition).
  [[ "$remote_sha" =~ ^0+$ ]] && continue

  # Non-fast-forward detection: remote_sha not an ancestor of local_sha.
  if ! git merge-base --is-ancestor "$remote_sha" "$local_sha" 2>/dev/null; then
    case "$remote_ref" in
      refs/heads/main|refs/heads/master|refs/tags/*)
        if [[ "${HOMEBASE_FORCE_PUSH_CONFIRMED:-0}" != "1" ]]; then
          block "Non-fast-forward push to $remote_ref is a Charter red-list
       operation. Set HOMEBASE_FORCE_PUSH_CONFIRMED=1 only after
       explicit operator confirmation."
        fi
        ;;
    esac
  fi
done

# ── Finish-push: closing keyword required on HEAD ─────────────────────────────
#
# HMB-86: chore work-states have .kind == "chore" and .issue == null — no
# Linear key to close, no closing keyword expected. Skip this gate for
# chore finishes; finish.sh's gate 6 (closing-keyword-present) already
# skips for kind:chore, so this hook must mirror that or chore-finish
# deadlocks at push time.

if [[ "${HOMEBASE_WORK_PHASE:-}" == "finish" ]]; then
  STATE_KIND=""
  if [[ -f "$WORK_STATE" ]] && command -v jq >/dev/null 2>&1; then
    STATE_KIND="$(jq -r '.kind // ""' "$WORK_STATE" 2>/dev/null || echo "")"
  fi
  if [[ "$STATE_KIND" == "chore" ]]; then
    : # chore finish — no Closes keyword required.
  else
    HEAD_MSG="$(git log -1 --pretty=%B 2>/dev/null || echo "")"
    if ! echo "$HEAD_MSG" | grep -qiE "^(Closes|Close|Closed|Fixes|Fix|Fixed|Resolves|Resolve|Resolved)[[:space:]]+${ISSUE_REF_RE}[[:space:]]*$"; then
      if [[ -f "$WORK_STATE" ]] && command -v jq >/dev/null 2>&1; then
        ISSUE="$(jq -r '.issue // "?"' "$WORK_STATE" 2>/dev/null || echo "?")"
      else
        ISSUE="<active issue>"
      fi
      block "Finish-push: HEAD commit lacks a closing keyword for $ISSUE.

       Append an empty closing commit (HOMEBASE_WORK_AUTHORIZED is already
       set for this push):

         git commit --allow-empty -m \"Closes $ISSUE\"

       Then re-run 'homebase work finish'."
    fi
  fi
fi

exit 0
