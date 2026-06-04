#!/usr/bin/env bash
# scripts/work/lib/linear-bridge.sh — thin wrapper around scripts/roadmap/linear.rb
# for issue-level reads and mutations consumed by `homebase work` verbs.
#
# Sourced by:
#   - scripts/work/start.sh, checkpoint.sh, finish.sh
#   - scripts/work/lib/gates.sh (indirectly via verb scripts)
#
# Authorisation:
#   - Read verbs (get, states): no LINEAR_TPM_AUTHORIZED required.
#   - Mutation verbs (move, create): require LINEAR_TPM_AUTHORIZED=1.
#
# All Linear interactions go through `ruby <repo-root>/scripts/roadmap/linear.rb`
# so the rate-limiting, retry, and credential-load logic in linear.rb stays
# the single source of truth.
#
# This file is symlinked into each homebase-adopting project by
# `bin/homebase link-project`. Do not edit copies.

[[ -n "${_LINEAR_BRIDGE_SOURCED:-}" ]] && return 0
_LINEAR_BRIDGE_SOURCED=1

_LB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../../lib/workflow-loader.sh
. "${_LB_DIR}/../../lib/workflow-loader.sh"

# Resolve the path to linear.rb. Walks up from the calling repo to find a
# scripts/roadmap/linear.rb (works in homebase itself and in projects with
# the symlink in place).
_lb_linear_rb() {
  local root; root="$(find_repo_root)"
  [[ -z "$root" ]] && return 1
  local candidate="${root}/scripts/roadmap/linear.rb"
  [[ -e "$candidate" ]] && { echo "$candidate"; return 0; }
  # Fall back to homebase itself.
  candidate="$(cd "${_LB_DIR}/../../.." && pwd -P)/scripts/roadmap/linear.rb"
  [[ -e "$candidate" ]] && { echo "$candidate"; return 0; }
  return 1
}

# Shell-out runner. All linear.rb invocations go through this.
_lb_invoke() {
  local rb
  rb="$(_lb_linear_rb)" || {
    echo "linear-bridge: linear.rb not found in repo or homebase" >&2
    return 2
  }
  command -v ruby >/dev/null 2>&1 || {
    echo "linear-bridge: ruby is required" >&2
    return 2
  }
  ruby "$rb" "$@"
}

# ── Read verbs (no auth required) ─────────────────────────────────────────────

# Print the issue JSON for a key (e.g. HMB-8). Exits 0 on success.
linear_get_issue() {
  local key="$1"
  [[ -z "$key" ]] && { echo "linear_get_issue: KEY required" >&2; return 2; }
  _lb_invoke issue get "$key"
}

# Print the team's workflow states (one JSON object per state) for the team
# that owns the given issue key. Used to map state-kind → state-name.
linear_list_issue_states() {
  local key="$1"
  [[ -z "$key" ]] && { echo "linear_list_issue_states: KEY required" >&2; return 2; }
  _lb_invoke issue states "$key"
}

# Print the issue's current state name. Convenience wrapper.
linear_issue_state() {
  local key="$1"
  linear_get_issue "$key" | jq -r '.state.name // empty'
}

# Print the team key (e.g. HMB) for a given issue key. Convenience wrapper.
linear_issue_team_key() {
  local key="$1"
  linear_get_issue "$key" | jq -r '.team.key // empty'
}

# Print the project name for a given issue key.
linear_issue_project() {
  local key="$1"
  linear_get_issue "$key" | jq -r '.project.name // empty'
}

# ── Mutation verbs (LINEAR_TPM_AUTHORIZED=1 required) ─────────────────────────

# Move an issue to the named state. Args: <KEY> <STATE_NAME>.
linear_move_issue() {
  local key="$1" state_name="$2"
  [[ -z "$key" || -z "$state_name" ]] && { echo "linear_move_issue: KEY + STATE_NAME required" >&2; return 2; }
  if [[ "${LINEAR_TPM_AUTHORIZED:-0}" != "1" ]]; then
    echo "linear_move_issue: LINEAR_TPM_AUTHORIZED=1 required (HOMEBASE-SOP-013)." >&2
    return 2
  fi
  _lb_invoke issue move "$key" "$state_name"
}

# Resolve a state-kind (backlog|in_progress|in_review|done) to the first
# matching state name available in the issue's team. Reads candidate names
# from the merged effective workflow.yml for the active app.
#
# Args: <KEY> <KIND> <APP-SLUG>
# Prints the resolved state name, or empty if no match.
linear_resolve_state_for_kind() {
  local key="$1" kind="$2" app="$3"
  local effective candidates
  effective="$(read_effective_workflow_for_app "$app")" || return 2
  candidates="$(printf '%s' "$effective" | jq -r ".linear.state_kinds.${kind} // [] | .[]")"
  [[ -z "$candidates" ]] && return 1

  local live
  live="$(linear_list_issue_states "$key" 2>/dev/null | jq -r '.name')"
  [[ -z "$live" ]] && return 1

  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    if printf '%s\n' "$live" | grep -Fxq "$candidate"; then
      echo "$candidate"
      return 0
    fi
  done <<< "$candidates"
  return 1
}
