#!/usr/bin/env bash
# _test_plan_approval_reminder.sh — HMB-105.
# Asserts post-plan-approval-reminder.sh emits valid PostToolUse additionalContext
# carrying the "act, don't re-ask" rule. Guards against the hook silently
# breaking (bad JSON / empty context) and no longer surfacing to the model.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOOK="$DIR/post-plan-approval-reminder.sh"
PASS=0; FAIL=0
pass() { echo "  ok: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "skip: jq not available"; exit 0; }
[[ -x "$HOOK" ]] || fail "hook is not executable"

OUT="$(printf '{"tool_name":"ExitPlanMode"}' | bash "$HOOK" 2>/dev/null)"

if printf '%s' "$OUT" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' >/dev/null 2>&1; then
  pass "emits PostToolUse hookSpecificOutput"
else
  fail "did not emit a PostToolUse hookSpecificOutput object"
fi

CTX="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
[[ -n "$CTX" ]] && pass "additionalContext is non-empty" || fail "additionalContext is empty"
printf '%s' "$CTX" | grep -qi "don't re-ask" && pass "reminder states the act/don't-re-ask rule" || fail "reminder missing the act/don't-re-ask rule"
printf '%s' "$CTX" | grep -q "Rule" && pass "reminder cites the contract rules" || fail "reminder doesn't cite the contract rules"

echo "── results: $PASS pass, $FAIL fail"
[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
