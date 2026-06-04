#!/usr/bin/env bash
# scripts/settings/_test_settings.sh — fixture tests for `homebase settings doctor` (HMB-50).
#
# Exercises the four recovery cases without touching the real ~/.claude or
# the real homebase repo:
#   1. Already a symlink to canonical → [OK], no mutation.
#   2. Symlink to a different target → [WARN] (rc=2), no mutation.
#   3a. Broken symlink → re-symlinked, [OK].
#   3b. Missing file → symlink created, [OK].
#   3c. Regular file identical to canonical → re-symlinked, [OK].
#   3d. Regular file with drift → drift promoted into canonical, file
#       replaced by symlink, backup written, [OK]. Canonical's contents
#       updated. Operator commits separately.
#   4. Missing canonical → [FAIL] (rc=1).
#
# Strategy: build a fake HOMEBASE under /tmp containing a copy of
# scripts/settings/doctor.sh + a .claude/user-settings.json canonical,
# plus a fake HOME under /tmp containing a .claude/ that the doctor will
# operate on. The script under test resolves $HOMEBASE from its own
# location, so running the symlinked copy under the fake HOMEBASE points
# the script at the fixture canonical.
#
# Usage: bash scripts/settings/_test_settings.sh [--keep]
#   --keep   Don't tear down the /tmp fixture on exit (for debugging)
#
# Exit codes:
#   0  all tests passed
#   1  test failure

set -uo pipefail

HOMEBASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

# Normalize $TMPDIR — on macOS it carries a trailing slash, which would
# create `//` in the symlink target literal and fail the doctor's path
# comparison against its own `pwd`-derived $CANONICAL.
TMPROOT="${TMPDIR:-/tmp}"
TMPROOT="${TMPROOT%/}"
FIXTURE="$TMPROOT/settings-doctor-test-$$"
trap 'rc=$?; if [[ "$KEEP" -eq 0 ]]; then rm -rf "$FIXTURE"; fi; exit $rc' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ok: $*"; PASS=$((PASS + 1)); }

# Set up a fake homebase root and a fake $HOME under the fixture. Symlink
# the real doctor.sh into the fake homebase so the script's $HOMEBASE
# resolution lands inside the fixture.
FAKE_HB="$FIXTURE/homebase"
FAKE_HOME="$FIXTURE/home"
mkdir -p "$FAKE_HB/.claude" "$FAKE_HB/scripts/settings" "$FAKE_HOME/.claude"
ln -s "$HOMEBASE/scripts/settings/doctor.sh" "$FAKE_HB/scripts/settings/doctor.sh"

DOCTOR="$FAKE_HB/scripts/settings/doctor.sh"
CANON="$FAKE_HB/.claude/user-settings.json"
USER="$FAKE_HOME/.claude/settings.json"

# Seed canonical with a known fixture payload.
SEED_CANON='{"permissions":{"allow":["Read","Bash(*)"]},"effortLevel":"high"}'
printf '%s\n' "$SEED_CANON" > "$CANON"

reset_fixture() {
  rm -f "$USER" "$USER".bak-* 2>/dev/null || true
  printf '%s\n' "$SEED_CANON" > "$CANON"
}

run_doctor() {
  local rc=0
  HOME="$FAKE_HOME" "$DOCTOR" >"$FIXTURE/last.out" 2>&1 || rc=$?
  echo "$rc"
}

# ── Case 1: already a correct symlink ────────────────────────────────────────

reset_fixture
ln -s "$CANON" "$USER"
RC=$(run_doctor)
[[ "$RC" == "0" ]] && pass "case1: rc=0 on correct symlink" || fail "case1: rc=$RC (want 0)"
[[ -L "$USER" ]] && [[ "$(readlink "$USER")" == "$CANON" ]] \
  && pass "case1: symlink unchanged" \
  || fail "case1: symlink unexpectedly mutated"
grep -q "already linked" "$FIXTURE/last.out" \
  && pass "case1: 'already linked' message" \
  || fail "case1: expected 'already linked' (got: $(cat $FIXTURE/last.out))"

# ── Case 2: symlink to a different target → WARN (rc=2) ─────────────────────

reset_fixture
echo '{"foreign":true}' > "$FIXTURE/foreign.json"
ln -s "$FIXTURE/foreign.json" "$USER"
RC=$(run_doctor)
[[ "$RC" == "2" ]] && pass "case2: rc=2 on wrong-target symlink" || fail "case2: rc=$RC (want 2)"
[[ -L "$USER" ]] && [[ "$(readlink "$USER")" == "$FIXTURE/foreign.json" ]] \
  && pass "case2: refused to clobber wrong-target symlink" \
  || fail "case2: doctor mutated a wrong-target symlink"

# ── Case 3a: broken symlink → re-link silently ──────────────────────────────

reset_fixture
ln -s "$FIXTURE/does-not-exist" "$USER"
RC=$(run_doctor)
[[ "$RC" == "0" ]] && pass "case3a: rc=0 on broken symlink" || fail "case3a: rc=$RC (want 0)"
[[ -L "$USER" ]] && [[ "$(readlink "$USER")" == "$CANON" ]] \
  && pass "case3a: broken symlink replaced with canonical" \
  || fail "case3a: broken symlink not recovered"

# ── Case 3b: missing → create symlink ───────────────────────────────────────

reset_fixture
RC=$(run_doctor)
[[ "$RC" == "0" ]] && pass "case3b: rc=0 on missing file" || fail "case3b: rc=$RC (want 0)"
[[ -L "$USER" ]] && [[ "$(readlink "$USER")" == "$CANON" ]] \
  && pass "case3b: symlink created from absent state" \
  || fail "case3b: symlink not created when settings.json was missing"

# ── Case 3c: regular file, contents identical → re-symlink ──────────────────

reset_fixture
cp "$CANON" "$USER"  # regular file, identical to canonical
RC=$(run_doctor)
[[ "$RC" == "0" ]] && pass "case3c: rc=0 on identical regular file" || fail "case3c: rc=$RC (want 0)"
[[ -L "$USER" ]] && [[ "$(readlink "$USER")" == "$CANON" ]] \
  && pass "case3c: identical regular file replaced by symlink" \
  || fail "case3c: regular file (identical) not converted to symlink"
grep -q "resynced" "$FIXTURE/last.out" \
  && pass "case3c: 'resynced' message" \
  || fail "case3c: expected 'resynced' (got: $(cat $FIXTURE/last.out))"
# Canonical content must be unchanged.
[[ "$(cat "$CANON")" == "$SEED_CANON" ]] \
  && pass "case3c: canonical content unchanged" \
  || fail "case3c: canonical content mutated unexpectedly"

# ── Case 3d: regular file with drift → drift promoted, backup written ──────

reset_fixture
DRIFT_CONTENT='{"permissions":{"allow":["Read","Bash(*)","WebFetch(domain:example.com)"]},"effortLevel":"high"}'
printf '%s\n' "$DRIFT_CONTENT" > "$USER"
RC=$(run_doctor)
[[ "$RC" == "0" ]] && pass "case3d: rc=0 on drift" || fail "case3d: rc=$RC (want 0)"
[[ -L "$USER" ]] && [[ "$(readlink "$USER")" == "$CANON" ]] \
  && pass "case3d: drift file replaced by symlink" \
  || fail "case3d: drift file not converted to symlink"
# Canonical should now contain the drift.
grep -q "example.com" "$CANON" \
  && pass "case3d: drift promoted into canonical" \
  || fail "case3d: canonical does not reflect the drift"
# A .bak-<timestamp> file should exist.
ls "$USER".bak-* >/dev/null 2>&1 \
  && pass "case3d: backup file written" \
  || fail "case3d: no backup file created"
grep -q "preserved drift" "$FIXTURE/last.out" \
  && pass "case3d: 'preserved drift' message" \
  || fail "case3d: expected 'preserved drift' (got: $(cat $FIXTURE/last.out))"

# ── Case 4: missing canonical → FAIL (rc=1) ──────────────────────────────────

reset_fixture
rm -f "$USER" "$USER".bak-* 2>/dev/null || true
rm "$CANON"
RC=$(run_doctor)
[[ "$RC" == "1" ]] && pass "case4: rc=1 on missing canonical" || fail "case4: rc=$RC (want 1)"
grep -q "canonical not found" "$FIXTURE/last.out" \
  && pass "case4: 'canonical not found' message" \
  || fail "case4: expected 'canonical not found' (got: $(cat $FIXTURE/last.out))"

# ── Summary ──────────────────────────────────────────────────────────────────

echo
echo "── results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
