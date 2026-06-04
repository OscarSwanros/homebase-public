#!/bin/sh
# Agent progress signaling — writes status for the statusline to display.
#
# Usage:
#   agent-signal.sh <phase> "<task>" [app] [detail]
#   agent-signal.sh clear
#
# Phases: exploring, planning, implementing, testing, done, blocked
#
# Examples:
#   agent-signal.sh exploring "#570 Gas Plans" gascalc
#   agent-signal.sh implementing "#570 Gas Plans" gascalc "Adding GasBlendView"
#   agent-signal.sh done "#570 Gas Plans" gascalc
#   agent-signal.sh clear

STATUS_DIR="$HOME/.claude/agent-status"

# Derive a key from the current working directory (same encoding as Claude project dirs)
cwd_key=$(pwd | tr '/' '-' | sed 's/^-//')
status_file="${STATUS_DIR}/${cwd_key}.json"

if [ "$1" = "clear" ]; then
  rm -f "$status_file"
  exit 0
fi

phase="$1"
task="$2"
app="${3:-}"
detail="${4:-}"

if [ -z "$phase" ] || [ -z "$task" ]; then
  echo "Usage: agent-signal.sh <phase> \"<task>\" [app] [detail]" >&2
  echo "       agent-signal.sh clear" >&2
  exit 1
fi

# Validate phase
case "$phase" in
  exploring|planning|implementing|testing|done|blocked) ;;
  *) echo "Invalid phase: $phase (use exploring|planning|implementing|testing|done|blocked)" >&2; exit 1 ;;
esac

mkdir -p "$STATUS_DIR"

updated=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Build JSON (no jq dependency — pure shell)
json="{\"phase\":\"${phase}\",\"task\":\"${task}\""
[ -n "$app" ] && json="${json},\"app\":\"${app}\""
[ -n "$detail" ] && json="${json},\"detail\":\"${detail}\""
json="${json},\"updated\":\"${updated}\"}"

printf '%s\n' "$json" > "$status_file"
