#!/usr/bin/env bash
# Claude PreToolUse hook fired before any `git commit` Bash invocation.
#
# Two jobs:
#   1. Ensure `core.hooksPath` points at the repo's `.githooks/` so the
#      committed commit-msg validator actually runs. Self-healing across
#      fresh clones and branch checkouts.
#   2. Block bypass flags (`--no-verify`, `-n`) so the agent cannot skip
#      the validator. Bypassing the hook is prohibited by HOMEBASE-SOP-001.
#
# Payload on stdin (from Claude Code):
#   { "tool_name": "Bash",
#     "tool_input": { "command": "git commit -m \"...\"" },
#     "hook_event_name": "PreToolUse" }
#
# Output contract:
#   - To block: emit hookSpecificOutput JSON with permissionDecision=deny,
#     then exit 0. The commit never runs and the reason surfaces to Claude.
#   - To allow: exit 0 with no output.
#
# The repo-level `.githooks/commit-msg` hook is the actual validator
# (delegates to `scripts/hooks/commit-sop-check.sh`). This script only
# guards the path to it.
#
# Canonical source: ~/code/homebase/scripts/hooks/claude-precommit.sh
# Vendored into each project; do not edit copies.

set -uo pipefail

PAYLOAD=$(cat -)
COMMAND=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // ""' 2>/dev/null || true)

if [[ -z "$COMMAND" ]]; then
  exit 0
fi

# Only care about git commit invocations. The Claude-side matcher narrows
# this too, but belt-and-suspenders.
if ! printf '%s' "$COMMAND" | grep -Eq '(^|[[:space:]]|;|&&|\|\|)git[[:space:]]+commit(\b|[[:space:]])'; then
  exit 0
fi

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -n "$REPO_ROOT" ]]; then
  CURRENT=$(git -C "$REPO_ROOT" config --get core.hooksPath 2>/dev/null || echo "")
  if [[ "$CURRENT" != ".githooks" ]]; then
    git -C "$REPO_ROOT" config core.hooksPath .githooks >/dev/null 2>&1 || true
  fi
fi

# Block bypass flags. Look for --no-verify or a standalone -n (not -nX).
if printf '%s' "$COMMAND" | grep -Eq '(^|[[:space:]])(--no-verify|-n)([[:space:]]|$)'; then
  jq -n '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: "Commit bypass flags (--no-verify / -n) are forbidden. The commit-msg hook enforces HOMEBASE-SOP-001 trailer keywords — running without it defeats the point. If the validator is wrong about your message, fix the message or fix the validator at scripts/hooks/commit-sop-check.sh."
    }
  }'
  exit 0
fi

# HMB-60: refuse to commit AGENTS.md at the repo root. `xcodebuildmcp init`
# drops the file on every run; .gitignore catches accidental `git add -A`
# but a deliberate `git add -f AGENTS.md` would still slip through. This
# guard plugs that hole. Applies in every homebase-governed project, not
# just homebase itself — AGENTS.md is alien to homebase's CLAUDE.md
# convention everywhere.
if [[ -n "$REPO_ROOT" ]]; then
  if git -C "$REPO_ROOT" diff --cached --name-only 2>/dev/null | grep -Fxq 'AGENTS.md'; then
    jq -n '{
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "AGENTS.md is gitignored and must not be committed (HOMEBASE-SOP-015 / HMB-60). It is dropped by `xcodebuildmcp init` and points to third-party content homebase intentionally does not track. Unstage with `git restore --staged AGENTS.md` and remove the local file (`rm AGENTS.md`)."
      }
    }'
    exit 0
  fi
fi

exit 0
