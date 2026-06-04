#!/usr/bin/env bash
# scripts/deploy/_test_push_recovery.sh — fixture tests for HMB-123's
# push_with_rebase_recovery helper in scripts/deploy/lib.sh.
#
# Scenarios:
#   1. clean push (no origin-side change) — returns 0, push succeeded.
#   2. non-fast-forward with non-conflicting concurrent commit on origin —
#      helper fetches, rebases, retries; returns 0; both commits present
#      after push.
#   3. non-fast-forward with conflicting concurrent commit on origin —
#      helper aborts the rebase, prints the remediation block, returns 2;
#      working tree is clean post-recovery (no half-applied rebase).
#
# Uses a /tmp pair of bare+working git repos as a synthetic origin. Does
# NOT touch real GitHub. Does NOT honour HOMEBASE_WORK_AUTHORIZED at the
# parent shell — the helper sets its own env vars per call.

set -uo pipefail

HOMEBASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
LIB="$HOMEBASE/scripts/deploy/lib.sh"

if [[ ! -f "$LIB" ]]; then
  echo "FAIL: lib.sh not found at $LIB" >&2
  exit 1
fi

FIXTURE="${TMPDIR:-/tmp}/push-recovery-test-$$"
trap 'rc=$?; rm -rf "$FIXTURE"; exit $rc' EXIT INT TERM

PASS=0
FAIL=0
pass() { echo "  ok: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
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

# Source the helper. lib.sh has phase-prefixed log helpers; those are
# fine inside test output, just look noisy. Suppress nothing — the test
# output captures expected `info`/`warn`/`err` text per scenario.
DEPLOY_PHASE="test/push-recovery"
# shellcheck source=/dev/null
source "$LIB"

# ── Fixture setup ─────────────────────────────────────────────────────────────

mkdir -p "$FIXTURE/origin.git" "$FIXTURE/local"
git -C "$FIXTURE/origin.git" init --bare -q --initial-branch=main

cd "$FIXTURE/local"
git init -q -b main
git config user.email test@example.com
git config user.name "HMB-123 Test"
# Avoid the parent project's commit-msg hook firing on test commits.
git config core.hooksPath /dev/null
git remote add origin "$FIXTURE/origin.git"

# Seed an initial commit + push so origin has a base.
echo "# fixture" > README.md
git add README.md
git commit -q -m "initial commit"
git push -q origin main

# ── Scenario 1: clean push, no origin-side change ──────────────────────────────

echo "test/push-recovery"
echo "  scenario 1: clean push (no concurrent commit on origin)"

echo "1" >> README.md
git add README.md
git commit -q -m "release-bump simulation"

# Capture output so the function's logs land in a variable rather than
# polluting test pass output.
out_s1=$(push_with_rebase_recovery main 2>&1)
rc_s1=$?
assert_eq "$rc_s1" "0" "scenario-1: push_with_rebase_recovery returns 0"

# Confirm origin now has both commits.
origin_log=$(git -C "$FIXTURE/origin.git" log --oneline)
assert_contains "$origin_log" "release-bump simulation" "scenario-1: origin has the release-bump commit"

# ── Scenario 2: non-fast-forward, non-conflicting concurrent commit ──────────

echo "  scenario 2: non-fast-forward + non-conflicting rebase"

# Simulate a concurrent commit on origin by cloning a second working
# directory, committing a different file, and pushing.
git clone -q "$FIXTURE/origin.git" "$FIXTURE/other"
git -C "$FIXTURE/other" config user.email other@example.com
git -C "$FIXTURE/other" config user.name "Other Operator"
git -C "$FIXTURE/other" config core.hooksPath /dev/null
echo "concurrent" > "$FIXTURE/other/UNRELATED.md"
git -C "$FIXTURE/other" add UNRELATED.md
git -C "$FIXTURE/other" commit -q -m "concurrent unrelated commit"
git -C "$FIXTURE/other" push -q origin main

# Now in $FIXTURE/local, create a new release-bump commit that doesn't
# touch UNRELATED.md so rebase has no conflict.
echo "2" >> README.md
git add README.md
git commit -q -m "release-bump 2"

out_s2=$(push_with_rebase_recovery main 2>&1)
rc_s2=$?
assert_eq "$rc_s2" "0" "scenario-2: push_with_rebase_recovery returns 0 after rebase"
assert_contains "$out_s2" "rejected non-fast-forward" "scenario-2: classified the failure as non-FF"
assert_contains "$out_s2" "rebase complete" "scenario-2: rebase succeeded"

# Confirm origin has BOTH the concurrent commit and our release-bump 2.
origin_log_s2=$(git -C "$FIXTURE/origin.git" log --oneline)
assert_contains "$origin_log_s2" "concurrent unrelated commit" "scenario-2: origin retains concurrent commit"
assert_contains "$origin_log_s2" "release-bump 2" "scenario-2: origin has release-bump 2"

# ── Scenario 3: non-fast-forward + conflicting concurrent commit ─────────────

echo "  scenario 3: non-fast-forward + conflicting rebase"

# Reset $FIXTURE/local back to whatever origin/main is so we start from a
# clean logapp for this scenario.
git fetch -q origin main
git reset -q --hard origin/main

# Both the concurrent commit and ours touch README.md at the same line.
git -C "$FIXTURE/other" pull -q origin main
echo "OTHER-CHANGE" >> "$FIXTURE/other/README.md"
git -C "$FIXTURE/other" add README.md
git -C "$FIXTURE/other" commit -q -m "concurrent CONFLICTING commit"
git -C "$FIXTURE/other" push -q origin main

# Our conflicting change: append to README.md at the same trailing line.
echo "OUR-CHANGE" >> README.md
git add README.md
git commit -q -m "release-bump conflicting"

out_s3=$(push_with_rebase_recovery main 2>&1)
rc_s3=$?
assert_eq "$rc_s3" "2" "scenario-3: returns 2 on rebase conflict"
assert_contains "$out_s3" "reported conflict" "scenario-3: classified as conflict"
assert_contains "$out_s3" "Recover manually" "scenario-3: remediation block printed"

# Working tree should be clean — rebase was aborted.
status_after=$(git status --porcelain)
assert_eq "$status_after" "" "scenario-3: working tree clean after rebase abort"

# ── Tally ─────────────────────────────────────────────────────────────────────

echo
if [[ $FAIL -eq 0 ]]; then
  echo "  ALL OK ($PASS passed)"
  exit 0
fi
echo "  $FAIL failure(s), $PASS passed"
exit 1
