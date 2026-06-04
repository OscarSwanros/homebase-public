#!/usr/bin/env bash
# scripts/work/lib/state.sh — work-state.json read/write/lock library.
#
# Sourced by:
#   - scripts/work/{start,checkpoint,finish,status,cancel,resume}.sh
#   - scripts/hooks/work-cli-guard-hook.sh (Phase 3)
#   - scripts/hooks/{session-start,task-completed}.sh (Phase 3 extensions)
#
# State file shape: see standards/WORKFLOW_CONTRACT.md § Work-state lifecycle.
# Path: <repo-root>/.homebase/work-state.json (gitignored).
#
# Concurrency: every write acquires an exclusive lock on the state file.
# Uses flock when available (Linux util-linux); falls back to a Python
# fcntl shim on macOS (which does not ship flock by default). Two-window
# safety: separate Claude Code sessions in the same worktree serialise;
# sessions in separate worktrees see separate state files.
#
# This file is symlinked into each homebase-adopting project by
# `bin/homebase link-project`. Do not edit copies.

[[ -n "${_WORK_STATE_SOURCED:-}" ]] && return 0
_WORK_STATE_SOURCED=1

# Shared loader for repo-root + path helpers.
_WORK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../../lib/workflow-loader.sh
. "${_WORK_LIB_DIR}/../../lib/workflow-loader.sh"

# ── Schema constants ──────────────────────────────────────────────────────────

WORK_STATE_SCHEMA_VERSION=1

# ── Locking ───────────────────────────────────────────────────────────────────
#
# Writes hold an exclusive lock when `flock` is available (Linux util-linux,
# Homebrew `flock` package on macOS). When unavailable (default macOS),
# writes proceed unlocked. Two-window concurrency in the same worktree is
# rare in single-operator workflows; v2 may add a Python fcntl fallback.
#
# Idiom — every write block is:
#
#   if _state_lock_available; then ( flock 9; … ) 9>"$lock"
#   else                                ( … )
#   fi
#
# Wrapped via `_state_locked` to keep call sites short.

_state_lock_available() {
  command -v flock >/dev/null 2>&1
}

# ── Path helpers ──────────────────────────────────────────────────────────────

# Print the absolute path to .homebase/work-state.json. (Re-exported here for
# scripts that source state.sh without also sourcing workflow-loader.sh.)
state_path() {
  work_state_path "$@"
}

# Print the absolute path to the lock file. flock can use the state file
# itself, but a separate lock file is more portable across filesystems.
state_lock_path() {
  local p
  p="$(state_path "$@")" || return 2
  echo "${p}.lock"
}

# ── Existence + lifecycle ─────────────────────────────────────────────────────

# Exit 0 if a work-state file exists.
state_exists() {
  local p
  p="$(state_path "$@")" || return 2
  [[ -f "$p" ]]
}

# Exit 0 if work-state exists and `.finished == false`.
state_active() {
  work_state_active "$@"
}

# Exit 0 if work-state exists and `.finished == true`.
state_finished() {
  work_state_finished "$@"
}

# ── Read helpers ──────────────────────────────────────────────────────────────

# Read a top-level field from work-state. Args: <field> [<repo_root>].
# Prints the field value (string scalar) or empty for missing fields.
state_read() {
  local field="$1"
  local root="${2:-}"
  local p
  p="$(state_path "$root")" || return 2
  [[ -f "$p" ]] || return 1
  require_jq || return 2
  jq -r --arg k "$field" '.[$k] // empty' "$p"
}

# Print the active issue key (e.g. HMB-8). Empty if no state.
state_issue() {
  active_work_issue "$@"
}

# Print the active branch name. Empty if no state.
state_branch() {
  active_work_branch "$@"
}

# Print the active app slug.
state_app() {
  active_work_app "$@"
}

# Print the active kind (feature|chore|hotfix|release).
state_kind() {
  state_read kind "$@"
}

# Print the gate-progress integer.
state_last_gate_passed() {
  local raw
  raw="$(state_read last_gate_passed "$@")"
  [[ -z "$raw" ]] && raw=0
  echo "$raw"
}

# ── Write helpers (locked) ────────────────────────────────────────────────────

# Initialize a fresh work-state file. Args:
#   --issue KEY            (required UNLESS --no-issue is set)
#   --no-issue             For kind:chore — store issue as JSON null
#   --issue-url URL
#   --github-mirror REPO#N
#   --app SLUG             (required)
#   --platforms "ios,web"
#   --branch BRANCH        (required)
#   --base-sha SHA
#   --linear-state-at-start NAME
#   --linear-state-now NAME
#   --kind KIND            (default: feature)
#   --override-kind KIND   (e.g. hotfix)
#   --root PATH
#
# Refuses (returns 1) if a non-finished work-state already exists.
#
# HMB-86 B.1: --no-issue is the chore path. Chore work doesn't have a
# Linear / GitHub issue — the state file's `issue` field becomes JSON
# null; finish.sh's kind:chore branch skips Linear gates accordingly.
state_init() {
  local issue="" issue_url="" github_mirror="" app="" platforms_csv=""
  local branch="" base_sha="" linear_at="" linear_now="" kind="feature"
  local override_kind="null" root=""
  local no_issue=0
  while (($#)); do
    case "$1" in
      --issue)              issue="$2"; shift 2 ;;
      --no-issue)           no_issue=1; shift ;;
      --issue-url)          issue_url="$2"; shift 2 ;;
      --github-mirror)      github_mirror="$2"; shift 2 ;;
      --app)                app="$2"; shift 2 ;;
      --platforms)          platforms_csv="$2"; shift 2 ;;
      --branch)             branch="$2"; shift 2 ;;
      --base-sha)           base_sha="$2"; shift 2 ;;
      --linear-state-at-start) linear_at="$2"; shift 2 ;;
      --linear-state-now)   linear_now="$2"; shift 2 ;;
      --kind)               kind="$2"; shift 2 ;;
      --override-kind)      override_kind="\"$2\""; shift 2 ;;
      --root)               root="$2"; shift 2 ;;
      *) echo "state_init: unknown flag $1" >&2; return 2 ;;
    esac
  done
  if [[ "$no_issue" -eq 1 ]]; then
    [[ "$kind" != "chore" ]] && { echo "state_init: --no-issue requires --kind chore (got '$kind')" >&2; return 2; }
    [[ -n "$issue"  ]] && { echo "state_init: --no-issue and --issue '$issue' are mutually exclusive" >&2; return 2; }
  else
    [[ -z "$issue"  ]] && { echo "state_init: --issue required (or --no-issue for chore)"  >&2; return 2; }
  fi
  [[ -z "$app"    ]] && { echo "state_init: --app required"    >&2; return 2; }
  [[ -z "$branch" ]] && { echo "state_init: --branch required" >&2; return 2; }

  if state_active "$root"; then
    echo "state_init: a non-finished work-state already exists at $(state_path "$root"). Run 'homebase work cancel' or 'homebase work finish' first." >&2
    return 1
  fi

  require_jq || return 2

  local p lock
  p="$(state_path "$root")" || return 2
  lock="$(state_lock_path "$root")" || return 2
  mkdir -p "$(dirname "$p")"

  local platforms_json
  if [[ -z "$platforms_csv" ]]; then
    platforms_json="[]"
  else
    platforms_json="$(printf '%s' "$platforms_csv" | jq -R 'split(",") | map(. | gsub("^\\s+|\\s+$"; ""))')"
  fi

  # HMB-86 B.1: when --no-issue, store issue as JSON null (not "" string)
  # so downstream consumers (finish.sh's Linear gates, hooks reading
  # state.issue) can distinguish "chore work with no Linear key" from
  # "tracked work with empty key" — the former is legal, the latter is a
  # malformed state file.
  local issue_jq_flag="--arg"
  local issue_jq_value="$issue"
  if [[ "$no_issue" -eq 1 ]]; then
    issue_jq_flag="--argjson"
    issue_jq_value="null"
  fi

  (
    _state_lock_available && flock 9
    jq -n \
      --argjson schema_version "$WORK_STATE_SCHEMA_VERSION" \
      "$issue_jq_flag" issue "$issue_jq_value" \
      --arg issue_url "$issue_url" \
      --arg github_mirror "$github_mirror" \
      --arg app "$app" \
      --argjson platforms "$platforms_json" \
      --arg branch "$branch" \
      --arg base_sha "$base_sha" \
      --arg started_at "$(date -u +%FT%TZ)" \
      --arg linear_at "$linear_at" \
      --arg linear_now "$linear_now" \
      --arg kind "$kind" \
      --argjson override_kind "$override_kind" \
      '{
        schema_version: $schema_version,
        issue: $issue,
        issue_url: ($issue_url // ""),
        github_mirror: ($github_mirror // ""),
        app: $app,
        platforms: $platforms,
        branch: $branch,
        base_sha: ($base_sha // ""),
        started_at: $started_at,
        linear_state_at_start: ($linear_at // ""),
        linear_state_now: ($linear_now // ""),
        kind: $kind,
        override_kind: $override_kind,
        checkpoints: [],
        finished: false,
        finished_at: null,
        finish_outcome: null,
        last_gate_passed: 0
      }' > "$p"
  ) 9>"$lock"
}

# Update a single top-level field. Args: <field> <json-or-string-value> [<root>].
# When the value parses as JSON, it's stored as JSON; otherwise as string.
state_set() {
  local field="$1"
  local value="$2"
  local root="${3:-}"
  local p lock
  p="$(state_path "$root")" || return 2
  lock="$(state_lock_path "$root")" || return 2
  [[ -f "$p" ]] || { echo "state_set: $p missing" >&2; return 1; }
  require_jq || return 2

  local jq_arg
  if printf '%s' "$value" | jq empty 2>/dev/null; then
    jq_arg=(--argjson v "$value")
  else
    jq_arg=(--arg v "$value")
  fi

  (
    _state_lock_available && flock 9
    local tmp; tmp="$(mktemp)"
    jq --arg k "$field" "${jq_arg[@]}" '.[$k] = $v' "$p" > "$tmp" && mv "$tmp" "$p"
  ) 9>"$lock"
}

# Bump last_gate_passed to N. Args: <gate-number> [<root>].
state_set_gate_passed() {
  state_set last_gate_passed "$1" "${2:-}"
}

# Append a checkpoint. Args: --note "<text>" [--commit-sha SHA] [--root PATH].
state_append_checkpoint() {
  local note="" commit_sha="" root=""
  while (($#)); do
    case "$1" in
      --note)       note="$2"; shift 2 ;;
      --commit-sha) commit_sha="$2"; shift 2 ;;
      --root)       root="$2"; shift 2 ;;
      *) echo "state_append_checkpoint: unknown flag $1" >&2; return 2 ;;
    esac
  done
  local p lock
  p="$(state_path "$root")" || return 2
  lock="$(state_lock_path "$root")" || return 2
  [[ -f "$p" ]] || { echo "state_append_checkpoint: $p missing" >&2; return 1; }
  require_jq || return 2

  (
    _state_lock_available && flock 9
    local tmp; tmp="$(mktemp)"
    jq --arg at "$(date -u +%FT%TZ)" \
       --arg note "$note" \
       --arg sha "$commit_sha" \
       '.checkpoints += [{at: $at, note: $note, commit_sha: $sha}]' \
       "$p" > "$tmp" && mv "$tmp" "$p"
  ) 9>"$lock"
}

# Mark the state finished. Args: <outcome> [--pr <num>] [--last-commit <sha>] [--root <path>].
# Outcome must be one of: in_review | done | cancelled.
state_finalize() {
  local outcome="$1"; shift
  local pr="" last_commit="" root=""
  while (($#)); do
    case "$1" in
      --pr)          pr="$2"; shift 2 ;;
      --last-commit) last_commit="$2"; shift 2 ;;
      --root)        root="$2"; shift 2 ;;
      *) echo "state_finalize: unknown flag $1" >&2; return 2 ;;
    esac
  done
  case "$outcome" in
    in_review|done|cancelled) ;;
    *) echo "state_finalize: outcome must be in_review|done|cancelled" >&2; return 2 ;;
  esac

  local p lock
  p="$(state_path "$root")" || return 2
  lock="$(state_lock_path "$root")" || return 2
  [[ -f "$p" ]] || { echo "state_finalize: $p missing" >&2; return 1; }
  require_jq || return 2

  (
    _state_lock_available && flock 9
    local tmp; tmp="$(mktemp)"
    local pr_arg=("--arg" "pr" "$pr")
    if [[ -n "$pr" ]]; then
      pr_arg=("--argjson" "pr" "$pr")
    fi
    jq --arg at "$(date -u +%FT%TZ)" \
       --arg outcome "$outcome" \
       --arg last_commit "$last_commit" \
       "${pr_arg[@]}" \
       '. + {finished: true, finished_at: $at, finish_outcome: $outcome, last_commit_sha: $last_commit, pr_number: $pr}' \
       "$p" > "$tmp" && mv "$tmp" "$p"
  ) 9>"$lock"
}

# Remove the work-state file. Append an audit log line first. Args: [--reason <text>] [--root <path>].
state_clear() {
  local reason="" root=""
  while (($#)); do
    case "$1" in
      --reason) reason="$2"; shift 2 ;;
      --root)   root="$2"; shift 2 ;;
      *) echo "state_clear: unknown flag $1" >&2; return 2 ;;
    esac
  done
  local p lock audit_log
  p="$(state_path "$root")" || return 2
  lock="$(state_lock_path "$root")" || return 2
  audit_log="$(dirname "$p")/work-state.audit.log"
  [[ -f "$p" ]] || return 0  # nothing to do
  require_jq || return 2

  (
    _state_lock_available && flock 9
    local issue branch ts
    ts="$(date -u +%FT%TZ)"
    issue="$(jq -r '.issue // "?"' "$p" 2>/dev/null || echo "?")"
    branch="$(jq -r '.branch // "?"' "$p" 2>/dev/null || echo "?")"
    printf '%s\tcleared\t%s\t%s\t%s\n' "$ts" "$issue" "$branch" "${reason:-no-reason}" >> "$audit_log"
    rm -f "$p"
  ) 9>"$lock"
}

# Pretty-print a one-line summary of the active state to stdout. Empty if no state.
state_summary() {
  local p
  p="$(state_path "$@")" || return 2
  [[ -f "$p" ]] || return 0
  require_jq || return 2
  jq -r '
    "issue=\(.issue) app=\(.app) branch=\(.branch) " +
    "kind=\(.kind) finished=\(.finished) " +
    "gates=\(.last_gate_passed)"
  ' "$p"
}
