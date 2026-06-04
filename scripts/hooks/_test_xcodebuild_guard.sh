#!/usr/bin/env bash
# scripts/hooks/_test_xcodebuild_guard.sh — tests for
# scripts/hooks/xcodebuild-cli-guard-hook.sh (HMB-60).
#
# Strategy: feed JSON payloads on stdin (matching Claude Code's PreToolUse
# format), capture stdout, and assert whether the block JSON appears.
#
# Block contract:
#   - On block: hook emits a single-line JSON blob starting with
#     `{"decision":"block"` and exits 0.
#   - On allow: hook emits no stdout and exits 0.
#
# Usage:  bash scripts/hooks/_test_xcodebuild_guard.sh
#
# Exit codes:
#   0  all tests passed
#   1  at least one test failed

set -uo pipefail

HOMEBASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$HOMEBASE/scripts/hooks/xcodebuild-cli-guard-hook.sh"

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ok: $*"; PASS=$((PASS + 1)); }

# Run the hook with a Bash command payload and an optional env-var assignment.
# Returns the hook's stdout. The hook always exits 0 — block vs allow is
# distinguished by stdout content.
run_hook() {
  local cmd="$1"
  local env_assign="${2:-}"

  local payload
  payload=$(python3 -c "
import json, sys
print(json.dumps({
  'tool_name': 'Bash',
  'tool_input': {'command': sys.argv[1]},
  'hook_event_name': 'PreToolUse',
}))
" "$cmd")

  if [[ -n "$env_assign" ]]; then
    env -i HOME="$HOME" PATH="$PATH" "$env_assign" bash "$HOOK" <<< "$payload"
  else
    env -i HOME="$HOME" PATH="$PATH" bash "$HOOK" <<< "$payload"
  fi
}

assert_blocked() {
  local label="$1"
  local cmd="$2"
  local env_assign="${3:-}"
  local out
  out=$(run_hook "$cmd" "$env_assign")
  if [[ "$out" == *'"decision":"block"'* ]]; then
    pass "$label — blocked"
  else
    fail "$label — expected block, got: ${out:-<empty>}"
  fi
}

assert_allowed() {
  local label="$1"
  local cmd="$2"
  local env_assign="${3:-}"
  local out
  out=$(run_hook "$cmd" "$env_assign")
  if [[ -z "$out" ]]; then
    pass "$label — allowed"
  else
    fail "$label — expected allow (empty stdout), got: $out"
  fi
}

# ── Allow cases ────────────────────────────────────────────────────────────
assert_allowed "xcodebuildmcp wrapper"              "xcodebuildmcp build --help"
assert_allowed "xcodebuildmcp with sub-workflow"    "xcodebuildmcp simulator build-run --scheme Foo"
assert_allowed "xcrun --find tool discovery"        "xcrun --find xcodebuild"
assert_allowed "xcrun lipo"                         "xcrun lipo -info foo.framework/foo"
assert_allowed "xcrun otool"                        "xcrun otool -L /usr/bin/git"
assert_allowed "xcrun codesign"                     "xcrun codesign --verify Foo.app"
assert_allowed "xcrun swift"                        "xcrun swift --version"
assert_allowed "pkill -f xcodebuild"                "pkill -f xcodebuild"
assert_allowed "killall xcodebuild"                 "killall xcodebuild"
assert_allowed "which xcodebuild"                   "which xcodebuild"
assert_allowed "command -v xcodebuild"              "command -v xcodebuild"
assert_allowed "type xcodebuild"                    "type xcodebuild"
assert_allowed "echo containing word xcodebuild"    "echo 'how to use xcodebuild here'"

# ── Block cases — raw xcodebuild ──────────────────────────────────────────
assert_blocked "bare xcodebuild -list"              "xcodebuild -list -project Foo.xcodeproj"
assert_blocked "xcodebuild test"                    "xcodebuild test -scheme Foo -destination 'platform=iOS Simulator'"
assert_blocked "xcodebuild build (compound)"        "cd Foo && xcodebuild build"
assert_blocked "xcodebuild after ;"                 "cd Foo; xcodebuild build"
assert_blocked "xcodebuild after pipe"              "echo build | xcodebuild"
assert_blocked "path-prefixed xcodebuild"           "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -list"
assert_blocked "path-prefixed /usr/bin/xcodebuild"  "/usr/bin/xcodebuild build"

# ── Block cases — xcrun simctl ────────────────────────────────────────────
assert_blocked "xcrun simctl list"                  "xcrun simctl list devices"
assert_blocked "xcrun simctl boot"                  "xcrun simctl boot 'iPhone 17 Pro'"
assert_blocked "xcrun simctl io screenshot"         "xcrun simctl io booted screenshot /tmp/foo.png"
assert_blocked "xcrun simctl (compound)"            "rm -rf /tmp/foo && xcrun simctl erase booted"

# ── Block cases — bare simctl ─────────────────────────────────────────────
assert_blocked "bare simctl boot"                   "simctl boot 'iPhone 17 Pro'"
assert_blocked "bare simctl after ;"                "echo go; simctl list"

# ── Escape hatch ──────────────────────────────────────────────────────────
assert_allowed "xcodebuild w/ AUTHORIZED=1"         "xcodebuild -list -project Foo.xcodeproj" "XCODEBUILDMCP_AUTHORIZED=1"
assert_allowed "xcrun simctl w/ AUTHORIZED=1"       "xcrun simctl list devices"               "XCODEBUILDMCP_AUTHORIZED=1"
assert_allowed "bare simctl w/ AUTHORIZED=1"        "simctl boot 'iPhone 17 Pro'"             "XCODEBUILDMCP_AUTHORIZED=1"

# AUTHORIZED=0 should NOT bypass — only `1` is the escape value.
assert_blocked "AUTHORIZED=0 does not bypass"       "xcodebuild -list" "XCODEBUILDMCP_AUTHORIZED=0"

# ── HMB-76: tool names mentioned in cat-heredoc commit messages ──────────────
# A `git commit -m "$(cat <<'EOF' ... EOF)"` whose body documents the Apple
# toolchain must NOT trip the guard — the heredoc body is inert text, not an
# invocation. (The real-world false positive: commit bodies describing what a
# new fastlane lane does, citing xcodebuild's exportArchive step.)
read -r -d '' COMMIT_HEREDOC <<'CMD' || true
git commit -m "$(cat <<'EOF'
Add fastlane lane wrapping the xcodebuild exportArchive step

xcodebuild is invoked by fastlane internally; documented here for clarity.
EOF
)"
CMD
assert_allowed "commit cat-heredoc mentioning xcodebuild" "$COMMIT_HEREDOC"

# Same, mentioning simctl in the body.
read -r -d '' COMMIT_HEREDOC_SIMCTL <<'CMD' || true
git commit -m "$(cat <<'EOF'
Document the simctl boot flow we replaced with xcodebuildmcp
EOF
)"
CMD
assert_allowed "commit cat-heredoc mentioning simctl" "$COMMIT_HEREDOC_SIMCTL"

# A REAL invocation on the command line is still blocked even when a
# cat-heredoc is also present — only the heredoc *body* is stripped, never the
# command lines.
read -r -d '' REAL_PLUS_HEREDOC <<'CMD' || true
xcodebuild -list
cat <<'EOF'
just documentation, nothing executed
EOF
CMD
assert_blocked "real xcodebuild line still blocked despite a later cat-heredoc" "$REAL_PLUS_HEREDOC"

# ── Summary ────────────────────────────────────────────────────────────────
echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "RESULTS: $PASS passed, $FAIL failed" >&2
  exit 1
fi
echo "RESULTS: $PASS passed, 0 failed"
