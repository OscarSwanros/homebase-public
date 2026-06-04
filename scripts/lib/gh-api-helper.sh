#!/usr/bin/env bash
# gh-api-helper.sh -- Rate-limit-aware wrappers for GitHub API calls.
#
# Canonical source: ~/code/homebase/scripts/lib/gh-api-helper.sh
# Vendored into each project; edit in homebase and `homebase sync` to propagate.
#
# Source this file from scripts that make GitHub API calls:
#   source "$(dirname "$0")/lib/gh-api-helper.sh"
#
# Provides:
#   gh_api              -- wraps `gh api` with rate limit checking and retry on 429/403
#   gh_api_graphql      -- wraps `gh api graphql` with GraphQL rate limit error detection
#   gh_mutate_delay     -- enforces minimum delay between mutation calls
#   gh_check_rate_limit -- prints current REST/GraphQL rate limit status
#
# Configuration (env vars):
#   _GH_VERBOSE=1         -- print debug info to stderr
#   _GH_MAX_RETRIES=3     -- max retries on rate limit errors (default: 3)
#   _GH_MUTATE_DELAY=1    -- min seconds between mutations (default: 1)
#   _GH_MAX_WAIT=60       -- max seconds to wait for rate limit reset (default: 60)
#
# Requires: gh CLI
# Compatible with macOS bash 3.2 (no associative arrays, no [[ -v ]])

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────────

_GH_VERBOSE="${_GH_VERBOSE:-0}"
_GH_MAX_RETRIES="${_GH_MAX_RETRIES:-3}"
_GH_MUTATE_DELAY="${_GH_MUTATE_DELAY:-1}"
_GH_MAX_WAIT="${_GH_MAX_WAIT:-60}"
_GH_LAST_MUTATION_TIME="${_GH_LAST_MUTATION_TIME:-0}"

# ── Internal helpers ───────────────────────────────────────────────────────────

_gh_log() {
  if [ "$_GH_VERBOSE" = "1" ]; then
    echo "[gh-api-helper] $*" >&2
  fi
}

_gh_warn() {
  echo "[gh-api-helper] WARNING: $*" >&2
}

_gh_error() {
  echo "[gh-api-helper] ERROR: $*" >&2
}

_gh_epoch() {
  date +%s
}

_gh_sleep() {
  local seconds="$1"
  local reason="${2:-rate limit}"
  _gh_log "Sleeping ${seconds}s ($reason)"
  sleep "$seconds"
}

# ── Rate limit checking ───────────────────────────────────────────────────────

gh_check_rate_limit() {
  local output
  output=$(gh api rate_limit --cache 30s 2>/dev/null) || {
    _gh_warn "Could not check rate limit status"
    return 1
  }

  local rest_remaining rest_limit graphql_remaining graphql_limit
  rest_remaining=$(echo "$output" | grep -o '"remaining":[0-9]*' | head -1 | grep -o '[0-9]*$')
  rest_limit=$(echo "$output" | grep -o '"limit":[0-9]*' | head -1 | grep -o '[0-9]*$')

  graphql_remaining=$(echo "$output" | grep -A5 '"graphql"' | grep -o '"remaining":[0-9]*' | head -1 | grep -o '[0-9]*$')
  graphql_limit=$(echo "$output" | grep -A5 '"graphql"' | grep -o '"limit":[0-9]*' | head -1 | grep -o '[0-9]*$')

  echo "REST: ${rest_remaining:-?}/${rest_limit:-?} remaining"
  echo "GraphQL: ${graphql_remaining:-?}/${graphql_limit:-?} remaining"

  if [ -n "$rest_remaining" ] && [ "$rest_remaining" -lt 100 ]; then
    _gh_warn "REST rate limit low: ${rest_remaining} remaining"
  fi
  if [ -n "$graphql_remaining" ] && [ "$graphql_remaining" -lt 100 ]; then
    _gh_warn "GraphQL rate limit low: ${graphql_remaining} remaining"
  fi
}

# ── Core wrappers ──────────────────────────────────────────────────────────────

# Wrap `gh api` with rate limit awareness and retry logic.
# Usage: gh_api [gh api args...]
# Example: gh_api repos/owner/repo/issues --cache 60s
gh_api() {
  local attempt=0
  local max_retries="$_GH_MAX_RETRIES"
  local output
  local exit_code

  while [ "$attempt" -le "$max_retries" ]; do
    _gh_log "gh api $* (attempt $((attempt + 1)))"

    output=$(gh api "$@" 2>&1) && exit_code=0 || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
      echo "$output"
      return 0
    fi

    if echo "$output" | grep -qi "rate limit\|API rate limit\|secondary rate limit\|abuse detection"; then
      attempt=$((attempt + 1))
      if [ "$attempt" -gt "$max_retries" ]; then
        _gh_error "Rate limit exceeded after ${max_retries} retries"
        echo "$output"
        return 1
      fi

      local wait_time=$((2 ** attempt))
      if [ "$wait_time" -gt "$_GH_MAX_WAIT" ]; then
        wait_time="$_GH_MAX_WAIT"
      fi
      _gh_warn "Rate limited. Retrying in ${wait_time}s (attempt ${attempt}/${max_retries})"
      _gh_sleep "$wait_time" "rate limit backoff"
    else
      echo "$output"
      return "$exit_code"
    fi
  done

  echo "$output"
  return 1
}

# Wrap `gh api graphql` with rate limit awareness.
# Detects GraphQL-level rate limit errors (HTTP 200 with RATE_LIMIT error type).
# Usage: gh_api_graphql [gh api graphql args...]
gh_api_graphql() {
  local attempt=0
  local max_retries="$_GH_MAX_RETRIES"
  local output
  local exit_code

  while [ "$attempt" -le "$max_retries" ]; do
    _gh_log "gh api graphql $* (attempt $((attempt + 1)))"

    output=$(gh api graphql "$@" 2>&1) && exit_code=0 || exit_code=$?

    if echo "$output" | grep -q '"type":"RATE_LIMIT"\|"type": "RATE_LIMIT"'; then
      attempt=$((attempt + 1))
      if [ "$attempt" -gt "$max_retries" ]; then
        _gh_error "GraphQL rate limit exceeded after ${max_retries} retries"
        echo "$output"
        return 1
      fi

      local wait_time=$((2 ** attempt))
      if [ "$wait_time" -gt "$_GH_MAX_WAIT" ]; then
        wait_time="$_GH_MAX_WAIT"
      fi
      _gh_warn "GraphQL rate limited. Retrying in ${wait_time}s (attempt ${attempt}/${max_retries})"
      _gh_sleep "$wait_time" "GraphQL rate limit backoff"
      continue
    fi

    if [ "$exit_code" -ne 0 ] && echo "$output" | grep -qi "rate limit\|API rate limit\|secondary rate limit"; then
      attempt=$((attempt + 1))
      if [ "$attempt" -gt "$max_retries" ]; then
        _gh_error "Rate limit exceeded after ${max_retries} retries"
        echo "$output"
        return 1
      fi

      local wait_time=$((2 ** attempt))
      if [ "$wait_time" -gt "$_GH_MAX_WAIT" ]; then
        wait_time="$_GH_MAX_WAIT"
      fi
      _gh_warn "Rate limited. Retrying in ${wait_time}s (attempt ${attempt}/${max_retries})"
      _gh_sleep "$wait_time" "rate limit backoff"
      continue
    fi

    echo "$output"
    return "$exit_code"
  done

  echo "$output"
  return 1
}

# ── Mutation delay ─────────────────────────────────────────────────────────────

# Enforce minimum delay between mutation calls. Call this BEFORE each mutation.
# Usage: gh_mutate_delay
gh_mutate_delay() {
  local now
  now=$(_gh_epoch)
  local elapsed=$((now - _GH_LAST_MUTATION_TIME))

  if [ "$_GH_LAST_MUTATION_TIME" -gt 0 ] && [ "$elapsed" -lt "$_GH_MUTATE_DELAY" ]; then
    local wait_time=$((_GH_MUTATE_DELAY - elapsed))
    _gh_sleep "$wait_time" "mutation delay"
  fi

  _GH_LAST_MUTATION_TIME=$(_gh_epoch)
}
