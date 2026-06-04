#!/usr/bin/env bash
# Claude Code PreToolUse hook for the Bash tool. Blocks any direct `gh` CLI
# invocation unless TPM_AUTHORIZED=1 is set — enforcing HOMEBASE-SOP-002 (GitHub API
# Usage), which routes all GitHub operations through the technical-project-
# manager agent.
#
# The TPM agent knows how to rate-limit-batch reads, delay mutations, and
# cache responses. Allowing every agent to call `gh` directly burns through
# the 5,000 req/hr quota unpredictably and breaks release operations.
#
# Payload on stdin (JSON):
#   { "tool_name": "Bash",
#     "tool_input": { "command": "..." },
#     "hook_event_name": "PreToolUse" }
#
# Returns JSON { "decision": "block", "reason": "..." } to block, or exits
# silently to allow.
#
# Canonical source: ~/code/homebase/scripts/hooks/gh-cli-guard-hook.sh
# Vendored into each project; do not edit copies.

set -euo pipefail

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
cmd = data.get('tool_input', {}).get('command', '')
print(cmd)
" 2>/dev/null) || exit 0

# Match direct gh invocations: "gh ", "gh\n", standalone "gh", path-to-gh
if echo "$COMMAND" | head -1 | grep -qE '^\s*(gh\s|gh$|/usr/local/bin/gh|/opt/homebrew/bin/gh)'; then
  if [[ "${TPM_AUTHORIZED:-0}" == "1" ]]; then
    exit 0
  fi

  cat <<'HOOKJSON'
{"decision":"block","reason":"Direct gh CLI usage is prohibited (HOMEBASE-SOP-002). All GitHub operations must go through the technical-project-manager agent. See ~/code/homebase/sops/HOMEBASE-SOP-002-GITHUB_API_USAGE.md."}
HOOKJSON
  exit 0
fi

exit 0
