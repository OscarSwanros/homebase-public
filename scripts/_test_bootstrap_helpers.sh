#!/usr/bin/env bash
# scripts/_test_bootstrap_helpers.sh — unit tests for the HMB-87 B.12
# bootstrap fragments. Exercises `_bootstrap_pick_rc_file` and
# `_bootstrap_remove_claude_fn` in isolation against a temp rc file —
# without running the full `homebase bootstrap` (which has external
# dependencies on brew, gh, ssh, git config).
#
# Exit 0 on all-pass; exit 1 with stderr names on any fail.

set -uo pipefail

HOMEBASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=lib/bootstrap-helpers.sh
. "$HOMEBASE/scripts/lib/bootstrap-helpers.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ok: $*"; PASS=$((PASS + 1)); }
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"
  else fail "$name (got='$got' want='$want')"
  fi
}
assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if [[ "$hay" == *"$needle"* ]]; then pass "$name"
  else fail "$name — '$needle' not in output"
  fi
}

# ── pick_rc_file ─────────────────────────────────────────────────────────────

# Zsh default.
RC_OUT="$(SHELL=/bin/zsh _bootstrap_pick_rc_file)"
assert_eq "$RC_OUT" "$HOME/.zshrc" "pick_rc_file: SHELL=/bin/zsh → ~/.zshrc"

# Bash default.
RC_OUT="$(SHELL=/bin/bash _bootstrap_pick_rc_file)"
assert_eq "$RC_OUT" "$HOME/.bashrc" "pick_rc_file: SHELL=/bin/bash → ~/.bashrc"

# Unknown shell on macOS — fallback to ~/.zshrc.
if [[ "$(uname -s)" == "Darwin" ]]; then
  RC_OUT="$(SHELL=/usr/local/bin/fish _bootstrap_pick_rc_file)"
  assert_eq "$RC_OUT" "$HOME/.zshrc" "pick_rc_file: unknown shell on macOS → ~/.zshrc"
fi

# ── remove_claude_fn (HMB-98: Tier-2 uninstall of the auto-spawn function) ────

FIXTURE_RC="$(mktemp "${TMPDIR:-/tmp}/test-rc-XXXXX")"
trap 'rm -f "$FIXTURE_RC"' EXIT INT TERM
SENTINEL_OPEN="# >>> homebase: claude session-spawn (HMB-87 B.12) >>>"
SENTINEL_CLOSE="# <<< homebase: claude session-spawn (HMB-87 B.12) <<<"

# rc with a pre-existing claude() block surrounded by operator content.
{
  echo "# operator's existing rc content"
  echo "export FOO=bar"
  echo "$SENTINEL_OPEN"
  echo 'claude() { "/some/path/bin/homebase-claude" "$@"; }'
  echo "$SENTINEL_CLOSE"
  echo "export BAR=baz"
} > "$FIXTURE_RC"

OUT="$(_bootstrap_remove_claude_fn "$FIXTURE_RC")"
RC=$?
assert_eq "$RC" "0" "remove_claude_fn: removal returns 0"
assert_contains "$OUT" "removed" "remove_claude_fn: message says removed"
if grep -qF ">>> homebase: claude session-spawn" "$FIXTURE_RC"; then
  fail "remove_claude_fn: sentinel block still present after removal"
else
  pass "remove_claude_fn: sentinel block gone after removal"
fi
assert_contains "$(cat "$FIXTURE_RC")" "# operator's existing rc content" "remove_claude_fn: content above block preserved"
assert_contains "$(cat "$FIXTURE_RC")" "export FOO=bar" "remove_claude_fn: export above block preserved"
assert_contains "$(cat "$FIXTURE_RC")" "export BAR=baz" "remove_claude_fn: content below block preserved"

# Idempotent: second run (block already gone) is a clean no-op.
OUT="$(_bootstrap_remove_claude_fn "$FIXTURE_RC")"
RC=$?
assert_eq "$RC" "0" "remove_claude_fn: second run returns 0"
assert_contains "$OUT" "already removed" "remove_claude_fn: second run reports already-removed"

# Absent rc file → clean no-op (not an error).
OUT="$(_bootstrap_remove_claude_fn "${FIXTURE_RC}.nonexistent")"
RC=$?
assert_eq "$RC" "0" "remove_claude_fn: absent rc file returns 0"
assert_contains "$OUT" "nothing to remove" "remove_claude_fn: absent rc names the condition"

# Read-only rc that DOES contain the block → exit 2.
printf '%s\nclaude() { :; }\n%s\n' "$SENTINEL_OPEN" "$SENTINEL_CLOSE" > "$FIXTURE_RC"
chmod 444 "$FIXTURE_RC" 2>/dev/null || true
if [[ -w "$FIXTURE_RC" ]]; then
  echo "  skip: remove_claude_fn: read-only path test (chmod 444 doesn't deny owner on this system)"
else
  set +e
  OUT="$(_bootstrap_remove_claude_fn "$FIXTURE_RC" 2>&1)"
  RC=$?
  set -e
  assert_eq "$RC" "2" "remove_claude_fn: read-only rc with block returns exit 2"
  assert_contains "$OUT" "not writable" "remove_claude_fn: read-only message names the condition"
fi
chmod 644 "$FIXTURE_RC" 2>/dev/null || true

echo
echo "── results: $PASS pass, $FAIL fail"
exit $(( FAIL > 0 ? 1 : 0 ))
