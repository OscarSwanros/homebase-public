#!/usr/bin/env bash
# linear-api-helper.sh -- Rate-limit-aware wrappers for Linear GraphQL API calls.
#
# Canonical source: ~/code/homebase/scripts/lib/linear-api-helper.sh
# Symlinked into each project via `homebase link-project`.
#
# Source this file from scripts that call the Linear API:
#   source "$(dirname "$0")/../lib/linear-api-helper.sh"
#
# Provides:
#   linear_api            -- wraps GraphQL POST with rate-limit retry
#   linear_mutate_delay   -- enforces minimum delay between mutations
#   linear_auth           -- loads LINEAR_API_KEY from 1Password; fails closed
#   linear_check_quota    -- prints remaining complexity budget
#
# Enforcement: this helper refuses to run unless LINEAR_TPM_AUTHORIZED=1.
# Only the technical-project-manager agent is authorised to set that flag.
# See HOMEBASE-SOP-013 and HOMEBASE-SOP-002.
#
# Configuration (env vars):
#   _LINEAR_VERBOSE=1       -- debug output to stderr
#   _LINEAR_MAX_RETRIES=3   -- max retries on rate-limit errors (default 3)
#   _LINEAR_MUTATE_DELAY=1  -- min seconds between mutations (default 1)
#   _LINEAR_MAX_WAIT=60     -- max seconds to wait for rate-limit reset
#
# Requires: curl, jq. Reads LINEAR_API_KEY from env or from
# ~/.config/homebase/env (recommended: chmod 600).

set -euo pipefail

# ── Gatekeeper ─────────────────────────────────────────────────────────────────

if [[ "${LINEAR_TPM_AUTHORIZED:-0}" != "1" ]]; then
  echo "[linear-api-helper] refusing to load: LINEAR_TPM_AUTHORIZED is not 1." >&2
  echo "[linear-api-helper] All Linear API calls must route through technical-project-manager (SOP-013)." >&2
  return 1 2>/dev/null || exit 1
fi

# ── Configuration ──────────────────────────────────────────────────────────────

_LINEAR_VERBOSE="${_LINEAR_VERBOSE:-0}"
_LINEAR_MAX_RETRIES="${_LINEAR_MAX_RETRIES:-3}"
_LINEAR_MUTATE_DELAY="${_LINEAR_MUTATE_DELAY:-1}"
_LINEAR_MAX_WAIT="${_LINEAR_MAX_WAIT:-60}"
_LINEAR_LAST_MUTATION_TIME="${_LINEAR_LAST_MUTATION_TIME:-0}"
_LINEAR_ENDPOINT="https://api.linear.app/graphql"
_LINEAR_ENV_FILE="${HOME}/.config/homebase/env"

# ── Internal helpers ───────────────────────────────────────────────────────────

_linear_log() {
  [ "$_LINEAR_VERBOSE" = "1" ] && echo "[linear-api-helper] $*" >&2 || true
}

_linear_warn() {
  echo "[linear-api-helper] WARNING: $*" >&2
}

_linear_error() {
  echo "[linear-api-helper] ERROR: $*" >&2
}

_linear_epoch() {
  date +%s
}

_linear_sleep() {
  local seconds="$1"
  local reason="${2:-rate limit}"
  _linear_log "Sleeping ${seconds}s ($reason)"
  sleep "$seconds"
}

# ── Authentication ─────────────────────────────────────────────────────────────

# Load LINEAR_API_KEY from the env file (or keep the existing value if set).
# Fails loud if neither env var nor file is present.
linear_auth() {
  if [ -n "${LINEAR_API_KEY:-}" ]; then
    _linear_log "LINEAR_API_KEY already set in environment."
    return 0
  fi

  if [ ! -f "$_LINEAR_ENV_FILE" ]; then
    _linear_error "Linear API key not found: \$LINEAR_API_KEY empty and $_LINEAR_ENV_FILE does not exist."
    _linear_error "Create $_LINEAR_ENV_FILE with 'LINEAR_API_KEY=<your-key>' (chmod 600)."
    return 3
  fi

  local key
  key=$(grep -E '^\s*LINEAR_API_KEY\s*=' "$_LINEAR_ENV_FILE" | head -1 | sed -E 's/^\s*LINEAR_API_KEY\s*=\s*//; s/^["'\''](.*)["'\'']$/\1/')
  if [ -z "$key" ]; then
    _linear_error "LINEAR_API_KEY not found in $_LINEAR_ENV_FILE."
    return 3
  fi

  export LINEAR_API_KEY="$key"
  _linear_log "Loaded LINEAR_API_KEY from $_LINEAR_ENV_FILE."
}

# ── Core wrapper ───────────────────────────────────────────────────────────────

# Post a GraphQL query/mutation to Linear with retry on rate-limit errors.
# Usage:
#   linear_api '<graphql>' '<variables-json>'
# Example:
#   linear_api 'query { viewer { id name } }' '{}'
linear_api() {
  local query="$1"
  local variables="${2:-{\}}"
  local attempt=0
  local max_retries="$_LINEAR_MAX_RETRIES"
  local output
  local http_code

  if [ -z "${LINEAR_API_KEY:-}" ]; then
    linear_auth || return $?
  fi

  local body
  body=$(jq -n --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')

  while [ "$attempt" -le "$max_retries" ]; do
    _linear_log "POST $_LINEAR_ENDPOINT (attempt $((attempt + 1)))"

    local tmpfile
    tmpfile=$(mktemp)
    http_code=$(curl -sS -o "$tmpfile" -w '%{http_code}' \
      -X POST "$_LINEAR_ENDPOINT" \
      -H "Authorization: $LINEAR_API_KEY" \
      -H "Content-Type: application/json" \
      --data "$body" 2>&1) || http_code="000"
    output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    if [ "$http_code" = "200" ]; then
      if echo "$output" | jq -e '.errors[]? | select(.extensions.type == "RATELIMITED" or .extensions.code == "RATELIMITED")' >/dev/null 2>&1; then
        attempt=$((attempt + 1))
        if [ "$attempt" -gt "$max_retries" ]; then
          _linear_error "Linear rate limit exceeded after ${max_retries} retries"
          echo "$output"
          return 1
        fi
        local wait_time=$((2 ** attempt))
        [ "$wait_time" -gt "$_LINEAR_MAX_WAIT" ] && wait_time="$_LINEAR_MAX_WAIT"
        _linear_warn "Linear rate-limited. Retrying in ${wait_time}s (attempt ${attempt}/${max_retries})"
        _linear_sleep "$wait_time" "linear rate-limit backoff"
        continue
      fi
      echo "$output"
      return 0
    fi

    if [ "$http_code" = "429" ]; then
      attempt=$((attempt + 1))
      if [ "$attempt" -gt "$max_retries" ]; then
        _linear_error "HTTP 429 from Linear after ${max_retries} retries"
        echo "$output"
        return 1
      fi
      local wait_time=$((2 ** attempt))
      [ "$wait_time" -gt "$_LINEAR_MAX_WAIT" ] && wait_time="$_LINEAR_MAX_WAIT"
      _linear_warn "HTTP 429. Retrying in ${wait_time}s (attempt ${attempt}/${max_retries})"
      _linear_sleep "$wait_time" "http 429 backoff"
      continue
    fi

    _linear_error "Linear API returned HTTP $http_code"
    echo "$output"
    return 1
  done

  echo "$output"
  return 1
}

# ── Mutation delay ─────────────────────────────────────────────────────────────

# Call BEFORE every mutation. Enforces _LINEAR_MUTATE_DELAY seconds since the
# last mutation issued by this process.
linear_mutate_delay() {
  local now
  now=$(_linear_epoch)
  local elapsed=$((now - _LINEAR_LAST_MUTATION_TIME))

  if [ "$_LINEAR_LAST_MUTATION_TIME" -gt 0 ] && [ "$elapsed" -lt "$_LINEAR_MUTATE_DELAY" ]; then
    local wait_time=$((_LINEAR_MUTATE_DELAY - elapsed))
    _linear_sleep "$wait_time" "mutation delay"
  fi

  _LINEAR_LAST_MUTATION_TIME=$(_linear_epoch)
}

# ── Quota check ────────────────────────────────────────────────────────────────

# Prints remaining complexity budget for the current API key window.
linear_check_quota() {
  local output
  output=$(linear_api 'query { apiKeyUsage { complexity { limit remaining resetAt } } }' '{}' 2>/dev/null) || {
    _linear_warn "Could not check Linear quota (endpoint or schema may have changed)."
    return 1
  }

  local limit remaining reset_at
  limit=$(echo "$output" | jq -r '.data.apiKeyUsage.complexity.limit // "?"')
  remaining=$(echo "$output" | jq -r '.data.apiKeyUsage.complexity.remaining // "?"')
  reset_at=$(echo "$output" | jq -r '.data.apiKeyUsage.complexity.resetAt // "?"')

  echo "Linear complexity: ${remaining}/${limit} remaining (resets ${reset_at})"

  if [ "$remaining" != "?" ] && [ "$remaining" -lt 300 ] 2>/dev/null; then
    _linear_warn "Linear quota low: ${remaining} remaining"
  fi
}
