#!/usr/bin/env bash
# homebase auth status — print auth env vars visible to the hook process.
#
# HMB-45 Finding 11 self-diagnosis verb. Hook gates like
# `linear-cli-guard-hook.sh` read Claude Code's parent-process env at fork
# time. Inline `LINEAR_TPM_AUTHORIZED=1 cmd` prefixes and mid-session
# `export` don't help — they only affect the bash subprocess, which the
# hook fires *before*. The viable fixes are launching Claude with the var
# set (`LINEAR_TPM_AUTHORIZED=1 claude`) or adding it to
# `.claude/settings.local.json`'s `env` block.
#
# This script reports what the hook actually sees, so an agent or operator
# can self-diagnose without trial-and-error retries.
#
# Read-only. No mutations. No auth required.
#
# Canonical source: ~/code/homebase/scripts/auth/status.sh

set -euo pipefail

# When sourced (test mode), skip the side-effects.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]] && [[ "${HOMEBASE_AUTH_TEST_MODE:-0}" == "1" ]]; then
  return 0 2>/dev/null || true
fi

# ── Env-var visibility ──────────────────────────────────────────────────────
#
# We deliberately query each var directly so the output is verbatim rather
# than computed. The hook does the same — `${VAR:-0}` reads the parent env.

print_var() {
  local name="$1"
  local value="${!name:-}"
  if [[ -n "$value" ]]; then
    printf '  %-32s = set (value: %s)\n' "$name" "$value"
  else
    printf '  %-32s = unset\n' "$name"
  fi
}

echo "homebase auth status"
echo "===================="
echo ""
echo "Env vars visible to this process (= what the hook sees at PreToolUse time):"
echo ""

print_var LINEAR_TPM_AUTHORIZED
print_var TPM_AUTHORIZED
print_var HOMEBASE_WORK_AUTHORIZED
print_var HOMEBASE_OFF_CONTRACT
print_var HOMEBASE_DEPLOY_CONFIRMED
print_var HOMEBASE_FORCE_PUSH_CONFIRMED
print_var HOMEBASE_HOTFIX_AUTHORIZED
print_var HOMEBASE_SKIP_PREFLIGHT
print_var HOMEBASE_SKIP_LINEAR

echo ""

# ── Linear MCP plugin connection ────────────────────────────────────────────
#
# The Linear MCP plugin is registered in `.claude/settings.json`'s
# `enabledPlugins` (and the per-project overlay). When connected, the
# `mcp__plugin_linear_linear__*` tools are reachable; mutations through
# them are NOT env-var-gated (the AC-regex create-gate handles
# governance). Knowing whether the plugin is connected tells the
# operator whether the MCP escape route is available without relaunch.

mcp_status="unknown"
mcp_reason=""
for settings in \
  "$HOME/.claude/settings.json" \
  "$HOME/.claude/settings.local.json" \
  "$PWD/.claude/settings.json" \
  "$PWD/.claude/settings.local.json"; do
  [[ -f "$settings" ]] || continue
  # The Linear MCP plugin's tool permissions appear in the allowlist as
  # `mcp__plugin_linear_linear__*`. Detect that pattern as the proxy for
  # "tools available this session" — Claude doesn't expose a runtime API
  # to the bash subprocess, so we rely on configured permissions as the
  # closest available signal.
  if grep -q 'mcp__plugin_linear_linear' "$settings" 2>/dev/null; then
    mcp_status="permissioned in config"
    mcp_reason="$settings"
    break
  fi
done

if [[ "$mcp_status" == "unknown" ]]; then
  mcp_status="not detected in known settings paths"
fi

printf '  %-32s = %s' "LINEAR_MCP_PLUGIN" "$mcp_status"
if [[ -n "$mcp_reason" ]]; then
  printf ' (%s)' "$mcp_reason"
fi
echo ""

echo ""

# ── Decision hint ───────────────────────────────────────────────────────────

if [[ "${LINEAR_TPM_AUTHORIZED:-0}" != "1" ]]; then
  cat <<'EOF'
Note: LINEAR_TPM_AUTHORIZED is unset. CLI verbs that mutate Linear
(homebase work start|checkpoint|finish|ship; homebase roadmap
bootstrap|capture) will be denied by the linear-cli-guard hook. To
unblock:

  (a) Relaunch Claude with the var set:
        LINEAR_TPM_AUTHORIZED=1 claude
  (b) Or add to .claude/settings.local.json's env block, then relaunch:
        { "env": { "LINEAR_TPM_AUTHORIZED": "1" } }
  (c) Or route the operation through the Linear MCP plugin
      (mcp__plugin_linear_linear__*) — that path is not env-var-gated.

Mid-session 'export LINEAR_TPM_AUTHORIZED=1' and inline 'VAR=1 cmd'
prefixes do NOT work — the hook reads Claude's parent-process env
captured at fork time.

EOF
fi

exit 0
