#!/usr/bin/env bash
# scripts/work/start.sh — `homebase work start <KEY> [opts]`.
#
# Begins work on a tracked issue. Validates start_gates, creates the work
# branch, transitions Linear from backlog → in_progress, writes
# .homebase/work-state.json. Becomes the only legal entry into a workflow
# session once Phase 3's pre-tool hook is registered.
#
# Args:
#   <KEY>                  Issue identifier (e.g. HMB-8 or #42 for github tracker)
#   --app <slug>           Override app inference
#   --branch <name>        Override branch-name derivation
#   --no-branch            Don't create a branch (work continues on current)
#   --kind <kind>          feature (default) | chore | hotfix | release
#
# Authorisation:
#   Linear mutation requires LINEAR_TPM_AUTHORIZED=1. Without it, gate 6
#   (linear-state move) fails with a remediation message; the rest of the
#   start flow still validates so the operator gets a clear picture.

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(dirname "${WORK_DIR}")"
# shellcheck source=./lib/state.sh
. "${WORK_DIR}/lib/state.sh"
# shellcheck source=./lib/linear-bridge.sh
. "${WORK_DIR}/lib/linear-bridge.sh"
# shellcheck source=./lib/worktree.sh
. "${WORK_DIR}/lib/worktree.sh"
# shellcheck source=../lib/ac-regex.sh
. "${SCRIPTS_DIR}/lib/ac-regex.sh"

ISSUE=""
APP=""
BRANCH=""
NO_BRANCH=0
KIND="feature"

usage() {
  cat <<EOF
usage: homebase work start <ISSUE-KEY> [--app SLUG] [--branch NAME] [--no-branch] [--kind feature|chore|hotfix|release]

Begin work on a tracked issue. Validates the project's start_gates, creates
a branch (unless --no-branch), and transitions the Linear issue's state.

Examples:
  homebase work start HMB-8
  homebase work start TBL-42 --app studio-web
  homebase work start HMB-9 --kind chore
EOF
}

# Parse args.
while (($#)); do
  case "$1" in
    -h|--help)    usage; exit 0 ;;
    --app)        APP="$2"; shift 2 ;;
    --branch)     BRANCH="$2"; shift 2 ;;
    --no-branch)  NO_BRANCH=1; shift ;;
    --kind)       KIND="$2"; shift 2 ;;
    -*)           echo "start: unknown flag $1" >&2; usage; exit 2 ;;
    *)
      if [[ -z "$ISSUE" ]]; then ISSUE="$1"; shift
      else echo "start: extra positional '$1'" >&2; usage; exit 2
      fi
      ;;
  esac
done

[[ -z "$ISSUE" ]] && { echo "start: ISSUE-KEY required" >&2; usage; exit 2; }

# Validate kind.
case "$KIND" in
  feature|chore|hotfix|release) ;;
  *) echo "start: --kind must be feature|chore|hotfix|release" >&2; exit 2 ;;
esac

ROOT="$(find_repo_root)"
[[ -z "$ROOT" ]] && { echo "start: not in a git repo" >&2; exit 2; }

# HMB-109: session-worktree adoption (HMB-87 B.12) removed with the Tier-2
# simplification. Sessions no longer auto-spawn `session/<id>` worktrees, so
# there is never one to adopt — `homebase work start` always creates a fresh
# per-task worktree (or works on the current branch under --no-branch).

workflow_yml_exists "$ROOT" || {
  echo "start: $(workflow_yml_path "$ROOT") not found" >&2
  echo "       Run 'homebase work init' to scaffold one." >&2
  exit 1
}

# ── Banner ────────────────────────────────────────────────────────────────────
divider() { echo "─────────────────────────────────────────────────────────"; }
echo "homebase work start $ISSUE"
divider

if state_active "$ROOT"; then
  cur_issue="$(state_issue "$ROOT")"
  cur_branch="$(state_branch "$ROOT")"
  echo "[fail] active work-state already exists for $cur_issue (branch $cur_branch)" >&2
  echo "       Run 'homebase work finish' or 'homebase work cancel' first." >&2
  divider
  exit 1
fi

# ── Resolve issue ─────────────────────────────────────────────────────────────

ISSUE_JSON=""
ISSUE_TITLE="?"
ISSUE_URL=""
ISSUE_TEAM_KEY=""
ISSUE_PROJECT=""
ISSUE_STATE=""
ISSUE_LABELS=""

if [[ "$ISSUE" =~ ^#[0-9]+$ ]]; then
  echo "  [warn] github-tracker mode is not yet implemented in homebase work start"
  echo "         (Linear-only for now; #N support arrives in Phase 1.5+ ext)"
  echo "issue:    $ISSUE  (github)"
elif [[ "$ISSUE" =~ ^[A-Z]{2,5}-[0-9]+$ ]]; then
  if ISSUE_JSON="$(linear_get_issue "$ISSUE" 2>/dev/null)" && [[ -n "$ISSUE_JSON" ]]; then
    ISSUE_TITLE="$(printf '%s' "$ISSUE_JSON" | jq -r '.title // "?"')"
    ISSUE_URL="$(printf '%s' "$ISSUE_JSON" | jq -r '.url // ""')"
    ISSUE_TEAM_KEY="$(printf '%s' "$ISSUE_JSON" | jq -r '.team.key // ""')"
    ISSUE_PROJECT="$(printf '%s' "$ISSUE_JSON" | jq -r '.project.name // ""')"
    ISSUE_STATE="$(printf '%s' "$ISSUE_JSON" | jq -r '.state.name // ""')"
    ISSUE_LABELS="$(printf '%s' "$ISSUE_JSON" | jq -r '.labels.nodes[].name // empty' | paste -sd, -)"
    echo "issue:    $ISSUE — $ISSUE_TITLE"
    echo "project:  $ISSUE_PROJECT"
    echo "labels:   ${ISSUE_LABELS:-(none)}"
  else
    echo "  [warn] could not fetch $ISSUE from Linear (no key, network, or unauthorised)"
    echo "         Continuing with local-only state; gates 6+12 will fail until resolved."
    echo "issue:    $ISSUE"
  fi
else
  echo "start: issue identifier must match #N or KEY-N (got '$ISSUE')" >&2
  exit 2
fi

# ── cwd-misroute pre-flight (HMB-45 Finding 7, p2 root cause) ────────────────
#
# Before any side-effects (worktree creation, Linear transition, work-state
# write), verify that the cwd is the right project for this issue. The
# Linear `ISSUE_PROJECT` field names which app the issue belongs to; the
# global registry (registry/projects.paths + each project's project.yml)
# tells us which project owns that app. If the owning project isn't an
# ancestor of cwd, abort with a redirect — no worktree, no branch, no
# Linear transition, no work-state.json.
#
# Catches the qwen3.5/TFD-1393 cascade: `homebase work start TFD-1393`
# from `~/code/homebase` silently scaffolded a worktree there (because
# `homebase work start` infers project from cwd), even though TFD-1393's
# Linear project is `ShopOS` (lives in `~/code/field-suite`).
# Empty-worktree finish + wrong-branch commit + Linear bounced to Done
# with zero shipped code followed.
#
# Falls back silently when the issue has no Linear project (legacy issues,
# pre-bootstrap state) — the existing cwd-inference path takes over with
# a documented warning. See SOP-001 §A1.

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd -P)"
# shellcheck source=../../lib/project-resolver.sh
. "$LIB_DIR/project-resolver.sh"

# Single refusal path: print the owning-project redirect and abort before any
# side-effect. $ISSUE / $APP are read from the enclosing scope.
_refuse_misroute() {  # <owner_path> <why>
  local owner="$1" why="$2"
  echo "" >&2
  echo "start: $ISSUE $why" >&2
  echo "       owning project: $owner" >&2
  echo "       cwd is $(pwd -P) — not inside the owning project." >&2
  echo "" >&2
  echo "  Recovery:" >&2
  echo "    cd $owner" >&2
  echo "    homebase work start $ISSUE${APP:+ --app $APP}" >&2
  echo "" >&2
  echo "  No worktree, branch, Linear transition, or work-state.json was written." >&2
  echo "  (HMB-45 Finding 7 / HMB-111 — cwd-misroute prevention.)" >&2
  divider
  exit 3
}

# (a) HMB-111: when --app is supplied it is AUTHORITATIVE for ownership. Resolve
#     the project that owns the app via the registry and refuse if cwd isn't
#     inside it — the flag must never be silently ignored in favour of
#     cwd-derived resolution, and a worktree must never be carved into a repo
#     that doesn't own the app.
if [[ -n "$APP" ]]; then
  APP_OWNER="$(app_to_project_path "$APP" 2>/dev/null || true)"
  if [[ -n "$APP_OWNER" ]] && ! cwd_in_project_path "$APP_OWNER"; then
    _refuse_misroute "$APP_OWNER" "started with --app $APP, which is owned by another project"
  fi
fi

# (b) Linear-project-driven check (original HMB-45 Finding 7 path). The issue's
#     Linear project names the owning app; if it resolves to a project that
#     isn't an ancestor of cwd, refuse.
if [[ -n "$ISSUE_PROJECT" ]]; then
  OWNER_PATH="$(linear_project_name_to_project_path "$ISSUE_PROJECT" 2>/dev/null || true)"
  if [[ -n "$OWNER_PATH" ]] && ! cwd_in_project_path "$OWNER_PATH"; then
    _refuse_misroute "$OWNER_PATH" "belongs to Linear project '$ISSUE_PROJECT'"
  fi
fi

# ── Resolve app (cwd-local) ──────────────────────────────────────────────────

if [[ -z "$APP" ]]; then
  # HMB-111: only fall back to the cwd project's single app when the issue is
  # not claimed by a *different* Linear project. Without this, an issue whose
  # Linear project can't be mapped to a path (or maps elsewhere) gets silently
  # swallowed by a single-app project's only app and carved into the wrong repo
  # (the bug: a Briefing/TBL issue started from ~/code/homebase scaffolded a
  # homebase worktree). Resolvable-elsewhere was already refused above (b); the
  # unresolvable case falls through to require an explicit --app.
  cwd_owns_issue=1
  if [[ -n "$ISSUE_PROJECT" ]]; then
    ip_owner="$(linear_project_name_to_project_path "$ISSUE_PROJECT" 2>/dev/null || true)"
    if [[ -z "$ip_owner" ]] || ! cwd_in_project_path "$ip_owner"; then
      cwd_owns_issue=0
    fi
  fi
  if [[ "$cwd_owns_issue" -eq 1 ]]; then
    # Single-app projects: app is the only entry in apps[].
    APP="$(read_project_yml_as_json "$ROOT" 2>/dev/null | jq -r '
      if (.apps // []) | length == 1 then .apps[0].name else empty end
    ' 2>/dev/null || echo "")"
  fi
  if [[ -z "$APP" && -n "$ISSUE_PROJECT" ]]; then
    # Multi-app: try to match the Linear Project name to apps[].name (case-insensitive,
    # whitespace and brand-name normalised).
    norm() { printf '%s' "$1" | tr '[:upper:] ' '[:lower:]_'; }
    target="$(norm "$ISSUE_PROJECT")"
    APP="$(read_project_yml_as_json "$ROOT" 2>/dev/null | jq -r --arg t "$target" '
      .apps // [] | map(select((.name | ascii_downcase) == $t)) | .[0].name // empty
    ' 2>/dev/null || echo "")"
  fi
fi

if [[ -z "$APP" ]]; then
  echo "[fail] could not resolve --app. Pass --app <slug> explicitly." >&2
  echo "       (If the issue has no Linear project, the cwd-misroute pre-flight" >&2
  echo "        cannot redirect; resolve the app manually with --app or set" >&2
  echo "        the Linear project on the issue.)" >&2
  divider
  exit 2
fi

# (c) HMB-111 catch-all: the resolved APP must belong to the cwd project. This
#     backstops every resolution path above (explicit --app, single-app
#     default, multi-app Linear-name match) — a worktree is never carved for an
#     app another project owns. Silent when the app isn't in the registry yet
#     (new/unregistered app): the downstream gates still apply.
RESOLVED_OWNER="$(app_to_project_path "$APP" 2>/dev/null || true)"
if [[ -n "$RESOLVED_OWNER" ]] && ! cwd_in_project_path "$RESOLVED_OWNER"; then
  _refuse_misroute "$RESOLVED_OWNER" "resolved to app '$APP', which is owned by another project"
fi
echo "app:      $APP"

# ── Compute branch ────────────────────────────────────────────────────────────

if [[ -z "$BRANCH" ]]; then
  pattern="$(read_effective_workflow_for_app "$APP" "$ROOT" 2>/dev/null | jq -r '.branch.naming_pattern // "{scope}/{issue}-{slug}"')"
  scope="$APP"
  issue_num="${ISSUE##*-}"
  issue_num="${issue_num##\#}"
  slug="$(printf '%s' "$ISSUE_TITLE" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/-+/-/g' | cut -c1-50)"
  [[ -z "$slug" ]] && slug="work"
  BRANCH="${pattern//\{scope\}/$scope}"
  BRANCH="${BRANCH//\{issue\}/$issue_num}"
  BRANCH="${BRANCH//\{slug\}/$slug}"
  BRANCH="${BRANCH//\{app\}/$APP}"
fi

# ── Evaluate start gates ──────────────────────────────────────────────────────

GATES_OK=1
gate_print() {
  if [[ "$1" -eq 0 ]]; then echo "  [ok]   $2"
  else echo "  [fail] $2: $3"; GATES_OK=0
  fi
}

# 4. tree clean
#
# HMB-87 B.9: skip in worktree mode. When `worktree.enabled: true`, the new
# worktree materialises from `main`'s tip (committed state), not from the
# current checkout's working tree. Any dirt in the current checkout — the
# operator's WIP, another parallel agent's uncommitted Gradle bumps,
# anything that didn't make it to `main`'s SHA — is simply not pulled into
# the new worktree. The worktree is clean by construction, so the gate on
# the current checkout is asking the wrong question. The 2026-05-18
# TFD-1449 collision (a concurrent agent's dirty `Android/gradle/libs.versions.toml`
# blocking start) is the exact pattern this relaxation closes.
if worktree_enabled "$ROOT"; then
  echo "  [skip] tree clean (worktree mode — new worktree materialises from main's tip)"
elif [[ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]]; then
  gate_print 0 "tree clean"
else
  gate_print 1 "tree clean" "uncommitted changes; commit/stash first"
fi

# 5. branch base or clean
BRANCH_BASE="$(read_effective_workflow_for_app "$APP" "$ROOT" 2>/dev/null | jq -r '.branch.base // "main"')"
CURRENT_BRANCH="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
if [[ "$CURRENT_BRANCH" == "$BRANCH_BASE" ]]; then
  gate_print 0 "branch base ($BRANCH_BASE)"
else
  # Allow already on the target branch (resume-from-clean-state).
  if [[ "$CURRENT_BRANCH" == "$BRANCH" ]]; then
    gate_print 0 "branch already on target ($BRANCH)"
  else
    gate_print 1 "branch base" "currently on '$CURRENT_BRANCH', expected '$BRANCH_BASE'"
  fi
fi

# Issue gates (if we have ISSUE_JSON)
if [[ -n "$ISSUE_JSON" ]]; then
  # 6. issue exists in correct project (best-effort: relax when project.id absent)
  gate_print 0 "issue resolved in Linear (state=$ISSUE_STATE)"
  # 7. acceptance criteria — regexes in scripts/lib/ac-regex.sh, shared with the
  #    linear-cli-guard create-gate so both gates can never drift apart.
  has_ac="$(printf '%s' "$ISSUE_JSON" | jq -r \
    --arg heading "$AC_HEADING_RE" \
    --arg checkbox "$AC_CHECKBOX_RE" '
    (.description // "") |
    test($heading) and test($checkbox)
  ')"
  if [[ "$has_ac" == "true" ]]; then
    gate_print 0 "acceptance criteria present"
  else
    if gate_active start_gates.issue_must_have_acceptance_criteria "$APP"; then
      gate_print 1 "acceptance criteria" "issue has no '## Acceptance Criteria' with at least one '- [ ]'"
    else
      echo "  [skip] acceptance criteria — disabled in workflow.yml"
    fi
  fi
  # 8. required labels
  required_labels="$(read_effective_workflow_for_app "$APP" "$ROOT" | jq -r '.linear.required_labels_at_start // [] | .[]')"
  if [[ -n "$required_labels" ]]; then
    issue_labels="$(printf '%s' "$ISSUE_JSON" | jq -r '.labels.nodes[].name // empty')"
    missing=""
    while IFS= read -r req; do
      [[ -z "$req" ]] && continue
      if ! printf '%s\n' "$issue_labels" | grep -Fxq "$req"; then
        missing+="$req "
      fi
    done <<< "$required_labels"
    if [[ -z "$missing" ]]; then
      gate_print 0 "required labels (${required_labels//$'\n'/, })"
    else
      gate_print 1 "required labels" "missing: $missing"
    fi
  fi
fi

if [[ "$GATES_OK" -ne 1 ]]; then
  echo
  echo "start: one or more start_gates failed. Fix the issue(s) above and rerun." >&2
  divider
  exit 2
fi

# ── Create branch ─────────────────────────────────────────────────────────────

# Sessions launch in the project's main checkout (Tier-2), so ROOT is the
# project root.
PROJECT_ROOT="$ROOT"
WORKTREE_ENABLED=0
WORKTREE_PATH=""
if [[ "$NO_BRANCH" -eq 0 ]] && worktree_enabled "$PROJECT_ROOT"; then
  WORKTREE_ENABLED=1
  WORKTREE_PATH="$(worktree_path_for_branch "$BRANCH" "$PROJECT_ROOT")"
fi

if [[ "$NO_BRANCH" -eq 0 ]]; then
  if [[ "$WORKTREE_ENABLED" -eq 1 ]]; then
    # Worktree mode (HMB-27): create the branch on the main checkout's
    # references (without switching it), then materialise the worktree.
    # The main checkout stays on whatever branch the operator was on.
    if ! git -C "$PROJECT_ROOT" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
      HOMEBASE_WORK_AUTHORIZED=1 git -C "$PROJECT_ROOT" branch "$BRANCH" "$BRANCH_BASE" >/dev/null
      echo "branch:   created $BRANCH (from $BRANCH_BASE)"
    else
      echo "branch:   reusing existing $BRANCH"
    fi
    if ! worktree_create "$PROJECT_ROOT" "$BRANCH"; then
      echo "start: git worktree add failed for $BRANCH" >&2
      divider
      exit 2
    fi
    # Re-root downstream operations into the worktree so state/env writers
    # land their files inside .worktrees/<branch>/.homebase/.
    ROOT="$WORKTREE_PATH"

    # Auto-trust mise on the new worktree path (HMB-45 Finding 6). Without
    # this, the next gate that touches a Ruby tool otherwise blows up with
    # a misleading error (ANDROID_HOME unset / java not found / bundle
    # check fails) because mise refuses to load tools until the path is
    # trusted. The library function is idempotent and silent when mise
    # isn't installed.
    worktree_trust_mise "$WORKTREE_PATH"
  else
    # Single-branch mode (legacy): swap the main checkout to the new branch.
    if [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
      if git -C "$ROOT" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
        git -C "$ROOT" switch "$BRANCH" >/dev/null
        echo "branch:   switched to existing $BRANCH"
      else
        HOMEBASE_WORK_AUTHORIZED=1 git -C "$ROOT" switch -c "$BRANCH" >/dev/null
        echo "branch:   created $BRANCH (from $BRANCH_BASE)"
      fi
    else
      echo "branch:   $CURRENT_BRANCH (no-op)"
    fi
  fi
else
  echo "branch:   $CURRENT_BRANCH (no-op)"
fi

# ── Workflow.yml staleness warning (HMB-45 Finding 2) ────────────────────────
#
# When the branch base predates a `.homebase/workflow.yml` change on
# origin/main, the new branch carries the OLD gate definitions. Cost
# observed: TFD-843 inherited stale rubocop scoping from before TFD-1425
# fixed it, lit up 480 false offenses on auto-generated db/*_schema.rb
# files, and required a rebase to recover. There was no signal at start
# time that the workflow.yml was outdated.
#
# This is purely a warning — we never block start. Operator can rebase
# at their own pace. Skip silently when origin/main isn't reachable
# (offline, fresh clone, single-branch repo).
if [[ "$NO_BRANCH" -eq 0 ]]; then
  STALE_BASE_SHA="$(git -C "$PROJECT_ROOT" rev-parse "$BRANCH_BASE" 2>/dev/null || echo "")"
  if [[ -n "$STALE_BASE_SHA" ]] && \
     git -C "$PROJECT_ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
    STALE_COMMITS="$(git -C "$PROJECT_ROOT" log --oneline \
      "$STALE_BASE_SHA..origin/main" -- .homebase/workflow.yml 2>/dev/null || true)"
    if [[ -n "$STALE_COMMITS" ]]; then
      echo "  [warn] .homebase/workflow.yml on origin/main has changes since branch base ($BRANCH_BASE):" >&2
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "         $line" >&2
      done <<< "$STALE_COMMITS"
      echo "         Consider 'git rebase origin/main' before working — the branch's gate" >&2
      echo "         definitions are older than main's. (HMB-45 Finding 2.)" >&2
    fi
  fi
fi

# ── Linear state move ────────────────────────────────────────────────────────
#
# Self-authorize for the canonical Backlog → In Progress move (HMB-28).
# start.sh is an audited path: the issue and target state-kind come from the
# resolved work-start input (not arbitrary args), and the transition is always
# Backlog → In Progress. The linear-cli-guard hook still gates ad-hoc Bash
# invocations of `homebase work start`; this internal export only takes effect
# once the script is already executing. Document: SOP-013 § Linear API
# Gatekeeper — Self-authorization within work-state lifecycle scripts.

LINEAR_NEW=""
if [[ -n "$ISSUE_JSON" ]]; then
  export LINEAR_TPM_AUTHORIZED=1
  target="$(linear_resolve_state_for_kind "$ISSUE" in_progress "$APP" 2>/dev/null || true)"
  if [[ -n "$target" && "$target" != "$ISSUE_STATE" ]]; then
    if linear_move_issue "$ISSUE" "$target" >/dev/null 2>&1; then
      LINEAR_NEW="$target"
      echo "linear:   moved $ISSUE_STATE → $target"
    else
      echo "  [warn] linear move failed; will retry at finish-time"
    fi
  elif [[ "$target" == "$ISSUE_STATE" ]]; then
    LINEAR_NEW="$ISSUE_STATE"
    echo "linear:   already in $ISSUE_STATE"
  else
    echo "  [warn] no in_progress state matches workflow.yml; configure linear.state_kinds"
  fi
  unset LINEAR_TPM_AUTHORIZED
fi

# ── Persist work-state ────────────────────────────────────────────────────────

BASE_SHA="$(git -C "$ROOT" rev-parse "$BRANCH_BASE" 2>/dev/null || echo "")"
PLATFORMS_CSV="$(read_project_yml_as_json "$ROOT" | jq -r --arg a "$APP" '
  .apps // [] | map(select(.name == $a)) | .[0].platforms // [] | join(",")
')"

state_init \
  --issue "$ISSUE" \
  --issue-url "$ISSUE_URL" \
  --app "$APP" \
  --platforms "$PLATFORMS_CSV" \
  --branch "$BRANCH" \
  --base-sha "$BASE_SHA" \
  --linear-state-at-start "$ISSUE_STATE" \
  --linear-state-now "${LINEAR_NEW:-$ISSUE_STATE}" \
  --kind "$KIND" \
  --root "$ROOT"

echo "state:    $(state_path "$ROOT") written"

# ── Env file for shell sourcing ─────────────────────────────────────────────
#
# Operators source this file after `homebase work start` to authorise commits
# and pushes for the duration of the work-state without per-command env
# prefixes. `homebase work finish` and `homebase work cancel` delete it.

WORK_ENV="$ROOT/.homebase/.work-env"
{
  echo "# Generated by 'homebase work start $ISSUE' at $(date -u +%FT%TZ)."
  echo "# Source this file in your shell to authorise commits/pushes for $ISSUE:"
  echo "#   source $WORK_ENV"
  echo "# Removed automatically by 'homebase work finish' / 'homebase work cancel'."
  echo "export HOMEBASE_WORK_AUTHORIZED=1"
  echo "export WORK_KEY=$ISSUE"
  echo "export WORK_APP=$APP"
  echo "export WORK_BRANCH=$BRANCH"
  if [[ "$WORKTREE_ENABLED" -eq 1 ]]; then
    suffix_env="$(worktree_db_suffix_env "$ROOT")"
    suffix="$(worktree_db_suffix_for_issue "$ISSUE")"
    echo "export WORKTREE_NAME=$ISSUE"
    echo "export WORKTREE_PATH=$WORKTREE_PATH"
    echo "export $suffix_env=$suffix"
  fi
} > "$WORK_ENV"
echo "env:      $WORK_ENV written"

# Run the project's worktree.setup_command (e.g. db:create db:migrate).
if [[ "$WORKTREE_ENABLED" -eq 1 ]]; then
  worktree_run_setup "$WORKTREE_PATH" "$ISSUE" || \
    echo "  [warn] worktree setup_command exited non-zero; finish with what you have or rerun setup manually"
fi

# Required-agents preview.
agents="$(mandatory_agents_for "$APP" "" 2>/dev/null | paste -sd, -)"
[[ -n "$agents" ]] && echo "agents:   required: $agents"

divider
echo "ready. Use 'homebase work checkpoint' for mid-task signals; 'homebase work finish' to close out."
if [[ "$WORKTREE_ENABLED" -eq 1 ]]; then
  echo "        → cd $WORKTREE_PATH"
  echo "        → source .homebase/.work-env to authorise commits/pushes for $ISSUE."
  echo "          (or: cd \$(homebase work goto $ISSUE) && source .homebase/.work-env)"
else
  echo "        → source .homebase/.work-env to authorise commits/pushes for $ISSUE."
fi
exit 0
