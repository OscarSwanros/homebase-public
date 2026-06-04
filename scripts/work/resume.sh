#!/usr/bin/env bash
# scripts/work/resume.sh — `homebase work resume <KEY>`.
#
# Recovery: rebuilds .homebase/work-state.json from observed reality
# (current branch + Linear state + commits referencing <KEY>). For:
#   - "agent skipped start, did work, then crashed"
#   - "session ended mid-work; new session needs to pick up"
#   - "state file was corrupted/deleted but the branch still exists"

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${WORK_DIR}/lib/state.sh"
. "${WORK_DIR}/lib/linear-bridge.sh"

KEY="${1:-}"
[[ -z "$KEY" ]] && { echo "usage: homebase work resume <ISSUE-KEY>" >&2; exit 2; }

ROOT="$(find_repo_root)"
[[ -z "$ROOT" ]] && { echo "resume: not in a git repo" >&2; exit 2; }

if state_active "$ROOT"; then
  echo "resume: a non-finished work-state already exists. Run 'homebase work cancel' first." >&2
  exit 1
fi

CURRENT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
[[ -z "$CURRENT_BRANCH" || "$CURRENT_BRANCH" == "HEAD" ]] && { echo "resume: not on a branch" >&2; exit 2; }

# Find commits on this branch that reference KEY.
BASE_BRANCH="$(read_project_yml_as_json "$ROOT" 2>/dev/null | jq -r '.apps[0].deploy.branch // "main"')"
BASE_BRANCH="${BASE_BRANCH:-main}"
BASE_SHA="$(git -C "$ROOT" merge-base HEAD "$BASE_BRANCH" 2>/dev/null || echo "")"

REFERENCING_COUNT=0
if [[ -n "$BASE_SHA" ]]; then
  REFERENCING_COUNT="$(git -C "$ROOT" log "${BASE_SHA}..HEAD" --grep="$KEY" --oneline 2>/dev/null | wc -l | tr -d ' ')"
fi

divider() { echo "─────────────────────────────────────────────────────────"; }
divider
echo "resume:    $KEY"
echo "branch:    $CURRENT_BRANCH"
echo "base:      $BASE_BRANCH ($BASE_SHA)"
echo "commits:   $REFERENCING_COUNT referencing $KEY"

# Try to fetch issue from Linear.
ISSUE_JSON=""
ISSUE_TITLE="?"
ISSUE_URL=""
ISSUE_STATE=""
if [[ "$KEY" =~ ^[A-Z]{2,5}-[0-9]+$ ]]; then
  if ISSUE_JSON="$(linear_get_issue "$KEY" 2>/dev/null)" && [[ -n "$ISSUE_JSON" ]]; then
    ISSUE_TITLE="$(printf '%s' "$ISSUE_JSON" | jq -r '.title // "?"')"
    ISSUE_URL="$(printf '%s' "$ISSUE_JSON" | jq -r '.url // ""')"
    ISSUE_STATE="$(printf '%s' "$ISSUE_JSON" | jq -r '.state.name // ""')"
    echo "linear:    $ISSUE_TITLE — state=$ISSUE_STATE"
  else
    echo "linear:    (could not fetch — proceeding offline)"
  fi
fi

# Resolve app — single-app shortcut.
APP="$(read_project_yml_as_json "$ROOT" | jq -r '
  if (.apps // []) | length == 1 then .apps[0].name else empty end
')"
if [[ -z "$APP" ]]; then
  echo "  [warn] multi-app project; resume cannot infer app — re-run with --app via 'cancel + start'"
  echo "         or edit work-state.json by hand once written."
  APP="?"
fi
PLATFORMS_CSV="$(read_project_yml_as_json "$ROOT" | jq -r --arg a "$APP" '
  .apps // [] | map(select(.name == $a)) | .[0].platforms // [] | join(",")
')"

state_init \
  --issue "$KEY" \
  --issue-url "$ISSUE_URL" \
  --app "$APP" \
  --platforms "$PLATFORMS_CSV" \
  --branch "$CURRENT_BRANCH" \
  --base-sha "$BASE_SHA" \
  --linear-state-at-start "$ISSUE_STATE" \
  --linear-state-now "$ISSUE_STATE" \
  --kind feature \
  --root "$ROOT"

echo "state:     $(state_path "$ROOT") rebuilt"
divider
echo "ok. Run 'homebase work status' to preview gates, or 'homebase work finish' to close out."
exit 0
