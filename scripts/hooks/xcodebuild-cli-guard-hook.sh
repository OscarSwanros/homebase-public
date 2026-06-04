#!/usr/bin/env bash
# Claude Code PreToolUse hook for the Bash tool. Blocks any direct invocation
# of the raw Apple toolchain CLIs that homebase routes through `xcodebuildmcp`:
#
#   - `xcodebuild ...` (build, test, list, install, archive, etc.)
#   - `xcrun simctl ...` (simulator boot/erase/list/io/install/launch)
#   - bare `simctl ...`
#
# Rationale: HOMEBASE-SOP-015. xcodebuildmcp gives agents structured output,
# discoverable workflows (build/test/run/ui-automation/debugging), and a
# UI-automation surface (tap/swipe/type/screenshot) that the raw CLIs lack.
# Letting every agent re-derive xcodebuild's prose-log conventions burns
# tokens and produces brittle flows.
#
# Allow-list (always passes through, before the block patterns are checked):
#   - `xcodebuildmcp ...` (the wrapper itself)
#   - `xcrun --find <tool>` (read-only tool discovery; xcodebuildmcp uses this)
#   - `xcrun lipo|otool|codesign|altool|swift|swiftc|dwarfdump|atos` (binary
#     inspection, signing, and compiler frontends — xcodebuildmcp doesn't wrap
#     these)
#   - `pkill|killall|kill ... xcodebuild` (process management)
#   - `which|command -v|type xcodebuild` (existence checks)
#
# Escape hatch: `XCODEBUILDMCP_AUTHORIZED=1` lets blocked commands through.
# Per the LINEAR_TPM_AUTHORIZED precedent, env vars are captured at Claude's
# fork time — inline `XCODEBUILDMCP_AUTHORIZED=1 xcodebuild ...` and mid-session
# `export` do NOT affect what this hook sees. Set the var via
# `.claude/settings.local.json` `env` block then relaunch Claude.
#
# Payload on stdin (JSON):
#   { "tool_name": "Bash",
#     "tool_input": { "command": "..." },
#     "hook_event_name": "PreToolUse" }
#
# Returns JSON { "decision": "block", "reason": "..." } to block, or exits
# silently to allow.
#
# Canonical source: ~/code/homebase/scripts/hooks/xcodebuild-cli-guard-hook.sh
# Vendored into each project via `bin/homebase link-project`; do not edit copies.

set -euo pipefail

INPUT=$(cat)

# Extract the command, then strip `cat` heredoc bodies before the guard scans
# it (HMB-76). A `cat <<'EOF' ... EOF` body is inert text — most often a git
# commit message written as `git commit -m "$(cat <<'EOF' ... EOF)"` — so an
# Apple-tool name *mentioned* there is documentation, not an invocation, and
# must not trip the block. Only `cat` heredocs are stripped: a `bash <<EOF ...
# EOF` body is actually executed, so its contents deliberately stay in scope.
# The opener line itself is kept, so a real `; xcodebuild ...` on the command
# line is still caught.
COMMAND=$(HOMEBASE_HOOK_INPUT="$INPUT" python3 <<'PY'
import os, json, re
try:
    data = json.loads(os.environ.get("HOMEBASE_HOOK_INPUT", "") or "{}")
except Exception:
    data = {}
cmd = data.get("tool_input", {}).get("command", "")
lines = cmd.split("\n")
opener = re.compile("cat\\s+<<-?\\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")
out, i = [], 0
while i < len(lines):
    line = lines[i]
    out.append(line)            # keep the opener / command line itself
    m = opener.search(line)
    if m:
        delim = m.group(1)
        i += 1
        while i < len(lines) and lines[i].strip() != delim:
            i += 1              # drop heredoc body lines
        i += 1                  # drop the closing delimiter line too
        continue
    i += 1
print("\n".join(out))
PY
) 2>/dev/null || exit 0

# Escape hatch — set by `.claude/settings.local.json` `env` block + relaunch.
if [[ "${XCODEBUILDMCP_AUTHORIZED:-0}" == "1" ]]; then
  exit 0
fi

# Match the block patterns. The leading group `(^|[;&|]\s*|&&\s*|\|\|\s*|\(\s*)`
# detects sub-command boundaries (start of line, after shell separators, or
# after a subshell-open paren). The trailing group `(\s|$)` makes sure
# `xcodebuild` and `simctl` match as whole tokens — `xcodebuildmcp` and
# `simctlhelper` do not trigger the block.

# (1) Raw `xcodebuild` (bare or path-prefixed).
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*|&&\s*|\|\|\s*|\(\s*)(\S*/)?xcodebuild(\s|$)'; then
  cat <<'HOOKJSON'
{"decision":"block","reason":"Raw `xcodebuild` is prohibited (HOMEBASE-SOP-015). Use the `xcodebuildmcp` CLI: `xcodebuildmcp --help` to discover commands, or invoke the simulator/device/ui-automation/debugging workflow you need (e.g. `xcodebuildmcp simulator build-run`). The `xcodebuildmcp-cli` skill at ~/.claude/skills/xcodebuildmcp-cli/SKILL.md primes you with the discovery flow.\n\nEscape hatch: `XCODEBUILDMCP_AUTHORIZED=1` (captured at Claude fork time — set via .claude/settings.local.json `env` block + relaunch; inline env-var prefix and mid-session `export` do NOT work).\n\nFull SOP: ~/code/homebase/sops/HOMEBASE-SOP-015-APPLE_TOOLCHAIN.md"}
HOOKJSON
  exit 0
fi

# (2) `xcrun simctl ...` (any subcommand).
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*|&&\s*|\|\|\s*|\(\s*)xcrun\s+simctl(\s|$)'; then
  cat <<'HOOKJSON'
{"decision":"block","reason":"Raw `xcrun simctl` is prohibited (HOMEBASE-SOP-015). Use `xcodebuildmcp simulator-management` for sim boot/erase/list/io, or `xcodebuildmcp ui-automation` for tap/swipe/type/screenshot/view-hierarchy on a running sim.\n\nEscape hatch: `XCODEBUILDMCP_AUTHORIZED=1` (captured at Claude fork time — set via .claude/settings.local.json `env` block + relaunch).\n\nFull SOP: ~/code/homebase/sops/HOMEBASE-SOP-015-APPLE_TOOLCHAIN.md"}
HOOKJSON
  exit 0
fi

# (3) Bare `simctl` (rare — usually invoked via xcrun, but possible if PATH
#     is set up to expose simctl directly).
if echo "$COMMAND" | grep -qE '(^|[;&|]\s*|&&\s*|\|\|\s*|\(\s*)simctl(\s|$)'; then
  cat <<'HOOKJSON'
{"decision":"block","reason":"Raw `simctl` is prohibited (HOMEBASE-SOP-015). Use `xcodebuildmcp simulator-management` or `xcodebuildmcp ui-automation`.\n\nEscape hatch: `XCODEBUILDMCP_AUTHORIZED=1` (captured at Claude fork time — set via .claude/settings.local.json `env` block + relaunch).\n\nFull SOP: ~/code/homebase/sops/HOMEBASE-SOP-015-APPLE_TOOLCHAIN.md"}
HOOKJSON
  exit 0
fi

exit 0
