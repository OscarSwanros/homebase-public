#!/usr/bin/env bash
# Claude Code PreToolUse hook for Linear access control. Wears two hats:
#
#   1. Bash matcher — blocks shell-level Linear API access (curl/wget/sourcing
#      linear-api-helper.sh, or `homebase work start|checkpoint|finish|ship` /
#      `homebase roadmap bootstrap|capture`) unless LINEAR_TPM_AUTHORIZED=1 is
#      set. Routes every mutation through the technical-project-manager agent
#      per HOMEBASE-SOP-013 — analogous to the gh-cli gatekeeper from SOP-002.
#
#   2. mcp__plugin_linear_linear__save_issue matcher — blocks issue *creation*
#      (calls without `id`) when the description lacks a canonical
#      `## Acceptance Criteria` section with at least one `- [ ]`. Reuses the
#      same regex pair as the start-gate (scripts/lib/ac-regex.sh) so the two
#      gates can never drift apart. Updates (calls with `id` present) pass
#      through unchanged so we can backfill AC into existing AC-less issues
#      without disabling this gate.
#
# The TPM agent knows how to batch mutations, respect rate limits, and snapshot
# state to registry/roadmap-snapshot.yml. Allowing every agent to call the
# Linear API directly would burn through the 1500-complexity-per-hour quota
# unpredictably and jeopardises workspace integrity.
#
# Payload on stdin (JSON):
#   { "tool_name": "Bash" | "mcp__plugin_linear_linear__save_issue" | ...,
#     "tool_input": { ... },
#     "hook_event_name": "PreToolUse" }
#
# Returns JSON { "decision": "block", "reason": "..." } to block, or exits
# silently (exit 0, empty stdout) to allow.
#
# Canonical source: ~/code/homebase/scripts/hooks/linear-cli-guard-hook.sh
# Symlinked into each project via `homebase link-project`.

set -euo pipefail

INPUT=$(cat)

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(dirname "${HOOK_DIR}")"
# shellcheck source=../lib/ac-regex.sh
. "${SCRIPTS_DIR}/lib/ac-regex.sh"

# Tool-name dispatch — the hook is registered for both Bash and the Linear MCP
# save_issue tool, and the JSON payload tells us which.
TOOL_NAME=$(echo "$INPUT" | python3 -c "
import sys, json
print(json.load(sys.stdin).get('tool_name', ''))
" 2>/dev/null) || exit 0

# ─────────────────────────────────────────────────────────────────────────────
# Branch A — Linear MCP save_issue create-gate.
#
# The MCP path is intentionally NOT gated by LINEAR_TPM_AUTHORIZED (HMB-45
# Finding 11). The AC-regex create-gate below provides the equivalent
# governance guarantee for new-issue creation; updates pass through so AC
# backfill into existing issues remains possible. Routing all Linear-touching
# work through the MCP path is the right escape from the launch-time-only
# env-var trap that affects Branch B's CLI verbs.
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$TOOL_NAME" == "mcp__plugin_linear_linear__save_issue" ]]; then
  # Pass JSON payload via env var, not stdin: `python3 - <<HEREDOC` already
  # reads the script body from stdin, so we cannot use stdin for json.load too.
  RESULT=$(HOOK_INPUT="$INPUT" AC_HEADING_RE="$AC_HEADING_RE" AC_CHECKBOX_RE="$AC_CHECKBOX_RE" python3 - <<'PYEOF'
import sys, json, os, re

data = json.loads(os.environ.get('HOOK_INPUT', ''))
ti = data.get('tool_input', {}) or {}
issue_id = (ti.get('id') or '').strip()

# Update — let through. Backfilling AC into existing issues must remain
# possible without LINEAR_TPM_AUTHORIZED-style escape hatches; the TPM
# already gatekeeps mutations at the Bash layer above.
if issue_id:
    sys.exit(0)

description = ti.get('description', '') or ''
heading_re = os.environ['AC_HEADING_RE']
checkbox_re = os.environ['AC_CHECKBOX_RE']

if not re.search(heading_re, description):
    print(json.dumps({
        "decision": "block",
        "reason": (
            "Issue creation blocked: description is missing a `## Acceptance "
            "Criteria` section. Per HOMEBASE-SOP-001 §A3 every Linear issue "
            "needs a testable AC checklist before it can be created. Draft "
            "acceptance criteria first — what does done look like for this "
            "issue, in concrete `- [ ]` bullets?"
        )
    }))
    sys.exit(0)

if not re.search(checkbox_re, description):
    print(json.dumps({
        "decision": "block",
        "reason": (
            "Issue creation blocked: `## Acceptance Criteria` section is "
            "present but contains no `- [ ]` checkbox. At least one testable "
            "bullet is required so the issue's done-state is auditable per "
            "HOMEBASE-SOP-001 §C1."
        )
    }))
    sys.exit(0)
PYEOF
)
  if [[ -n "$RESULT" ]]; then
    echo "$RESULT"
  fi
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Branch B — Bash gate (TPM authorisation for Linear-touching shell commands).
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$TOOL_NAME" != "Bash" ]]; then
  exit 0
fi

COMMAND=$(echo "$INPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
cmd = data.get('tool_input', {}).get('command', '')
print(cmd)
" 2>/dev/null) || exit 0

# Match:
#   - curl / wget / httpie to api.linear.app
#   - sourcing or invoking linear-api-helper.sh
#   - invoking homebase roadmap <mutation-verb> (bootstrap | capture)
#   - invoking homebase work <mutation-verb> (start | checkpoint | finish | ship)
#     because all four can mutate Linear (state transitions, milestone close)
#
# Read-only verbs are allowed without authorisation:
#   - homebase roadmap (render | audit | portfolio | org | team | project)
#   - homebase work (status | cancel | resume | init)

# Detect Linear API access via two anchored patterns:
#   1. Direct HTTP to api.linear.app (any context — the hostname is unique).
#   2. Sourcing or executing scripts/lib/linear-api-helper.sh as a *command*,
#      not as a *filename argument*. Matches `. <path>`, `source <path>`,
#      `bash <path>`, `sh <path>`, `zsh <path>`. Does NOT match `git add`,
#      `cat`, `ls`, `vim`, or any other tool that just takes the file as an
#      argument.
if echo "$COMMAND" | grep -qE 'api\.linear\.app' \
   || echo "$COMMAND" | grep -qE '(^|[;&|]\s*)\s*(\.|source|bash|sh|zsh)\s+\S*linear-api-helper\.sh\b'; then
  if [[ "${LINEAR_TPM_AUTHORIZED:-0}" == "1" ]]; then
    exit 0
  fi

  cat <<'HOOKJSON'
{"decision":"block","reason":"Direct Linear API usage is prohibited (HOMEBASE-SOP-013). All Linear operations must go through the technical-project-manager agent.\n\nLINEAR_TPM_AUTHORIZED gates this verb at LAUNCH TIME ONLY — Claude Code reads its own process env, captured at fork. The following will NOT help:\n  - inline `LINEAR_TPM_AUTHORIZED=1 curl ...` (the hook fires before the bash subprocess runs)\n  - mid-session `export LINEAR_TPM_AUTHORIZED=1` in any Bash tool call (the env doesn't propagate up to Claude)\n\nViable fixes (pick one):\n  (a) relaunch Claude with the var: `LINEAR_TPM_AUTHORIZED=1 claude`\n  (b) add to `.claude/settings.local.json` `env` block, then relaunch\n  (c) route the operation through the Linear MCP plugin (mcp__plugin_linear_linear__*) — that path is not env-var-gated; the MCP create-gate handles new-issue governance via the AC-regex check.\n\nRun `homebase auth status` to see what's currently visible to the hook process.\n\nFull SOP: ~/code/homebase/sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md"}
HOOKJSON
  exit 0
fi

if echo "$COMMAND" | grep -qE '(^|[;&|]\s*)\s*(bin/)?homebase\s+(roadmap\s+(bootstrap|capture)|work\s+(start|checkpoint|finish|ship))\b'; then
  if [[ "${LINEAR_TPM_AUTHORIZED:-0}" == "1" ]]; then
    exit 0
  fi

  cat <<'HOOKJSON'
{"decision":"block","reason":"`homebase roadmap bootstrap|capture` and `homebase work start|checkpoint|finish|ship` require LINEAR_TPM_AUTHORIZED=1 (HOMEBASE-SOP-013).\n\nLINEAR_TPM_AUTHORIZED gates this verb at LAUNCH TIME ONLY — Claude Code reads its own process env, captured at fork. The following will NOT help:\n  - inline `LINEAR_TPM_AUTHORIZED=1 homebase work start KEY-N` (the hook fires before the bash subprocess runs)\n  - mid-session `export LINEAR_TPM_AUTHORIZED=1` in any Bash tool call (the env doesn't propagate up to Claude)\n\nViable fixes (pick one):\n  (a) relaunch Claude with the var: `LINEAR_TPM_AUTHORIZED=1 claude`\n  (b) add to `.claude/settings.local.json` `env` block, then relaunch\n\nRead-only verbs are NOT env-var-gated and work without authorisation:\n  homebase roadmap (render|audit|portfolio|org|team|project)\n  homebase work (status|cancel|resume|init|goto|list)\n\nRun `homebase auth status` to see what's currently visible to the hook process."}
HOOKJSON
  exit 0
fi

exit 0
