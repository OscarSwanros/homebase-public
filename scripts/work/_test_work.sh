#!/usr/bin/env bash
# scripts/work/_test_work.sh — fixture tests for `homebase work` verbs.
#
# Exercises the help, argument parsing, state-file lifecycle, and pure-shell
# gate logic against a synthetic /tmp project. Does NOT exercise Linear/gh
# mutations — those require LINEAR_TPM_AUTHORIZED / TPM_AUTHORIZED and live
# credentials, validated end-to-end in Phase 4 (homebase self-host) and CI.
#
# Usage: bash scripts/work/_test_work.sh [--keep]
#   --keep   Don't tear down the /tmp fixture on exit (for debugging)
#
# Exit codes:
#   0   all tests passed
#   1   test failure (stderr names the failing test)

set -uo pipefail

HOMEBASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

# Use a unique fixture dir per run so concurrent CI shards don't collide.
FIXTURE="${TMPDIR:-/tmp}/work-cli-test-$$"
trap 'rc=$?; if [[ "$KEEP" -eq 0 ]]; then rm -rf "$FIXTURE"; fi; exit $rc' EXIT INT TERM

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

# ── Setup ─────────────────────────────────────────────────────────────────────

mkdir -p "$FIXTURE/.homebase" "$FIXTURE/apps/myapp"
cd "$FIXTURE"
git init -q
git config user.email test@example.com
git config user.name "Test User"

cat > .homebase/project.yml <<EOF
name: testproj
display_name: Test Project
description: Fixture for work-cli tests
kind: monorepo
domains: [web]
apps:
  - name: myapp
    path: apps/myapp
    platforms: [web]
    status: active
    summary: Test app.
EOF

# Initial commit so HEAD exists.
echo "test" > README.md
echo ".homebase/work-state.json" > .gitignore
echo ".homebase/work-state.json.lock" >> .gitignore
echo ".homebase/work-state.*.json" >> .gitignore
echo ".homebase/work-state.*.json.lock" >> .gitignore
echo ".homebase/work-state.audit.log" >> .gitignore
echo ".homebase/work-finish-*.log" >> .gitignore
git add README.md .gitignore
git commit -q -m "Initial fixture commit"
git checkout -q -b main 2>/dev/null || true

echo "── fixture: $FIXTURE"
echo

# Symlink homebase scripts so /tmp/.../scripts/work/* resolve.
mkdir -p scripts
ln -sf "$HOMEBASE/scripts/work" scripts/work
ln -sf "$HOMEBASE/scripts/lib" scripts/lib
ln -sf "$HOMEBASE/scripts/roadmap" scripts/roadmap
ln -sf "$HOMEBASE/scripts/hooks" scripts/hooks
ln -sf "$HOMEBASE/templates" templates
ln -sf "$HOMEBASE/schemas" schemas

# ── Test: help ────────────────────────────────────────────────────────────────

OUT="$("$HOMEBASE/bin/homebase" work help 2>&1)"
assert_contains "$OUT" "homebase work" "help: header"
assert_contains "$OUT" "start <ISSUE-KEY>" "help: start verb listed"
assert_contains "$OUT" "finish [opts]" "help: finish verb listed"
assert_contains "$OUT" "WORKFLOW_CONTRACT.md" "help: standard reference"

# ── Test: init scaffolds workflow.yml ────────────────────────────────────────

OUT="$("$HOMEBASE/bin/homebase" work init 2>&1)"
assert_contains "$OUT" "scaffolded" "init: scaffold message"
[[ -f .homebase/workflow.yml ]] && pass "init: workflow.yml exists" || fail "init: workflow.yml missing"

# Idempotent: second init no-ops.
OUT="$("$HOMEBASE/bin/homebase" work init 2>&1)"
assert_contains "$OUT" "already exists" "init: idempotent on re-run"

# ── Test: status with no active work-state ───────────────────────────────────

OUT="$("$HOMEBASE/bin/homebase" work status 2>&1)"
assert_contains "$OUT" "no active work-state" "status: no-state message"

OUT="$("$HOMEBASE/bin/homebase" work status --json 2>&1)"
INFLIGHT="$(printf '%s' "$OUT" | jq -r '.in_flight')"
assert_eq "$INFLIGHT" "false" "status: --json reports in_flight=false"

# ── Test: cancel with no work-state exits 3 ──────────────────────────────────

OUT="$("$HOMEBASE/bin/homebase" work cancel 2>&1)"
RC=$?
assert_contains "$OUT" "no work-state" "cancel: no-op message"

# Commit the init output (workflow.yml + any .gitignore tweaks) so subsequent
# tree-clean checks see a clean tree.
git add -A
git commit -q -m "Scaffold workflow.yml" 2>/dev/null || true

# ── Test: state.sh + workflow-loader against fixture ─────────────────────────

bash -c "
source '$HOMEBASE/scripts/work/lib/state.sh'
state_init --issue HMB-99 --app myapp --branch test/hmb-99 --kind chore --base-sha abc1234
state_active && echo OK1
state_summary
state_append_checkpoint --note testing --commit-sha def5678
# HMB-87 B.11: state_path now returns the SHA-keyed per-worktree central
# path; use it for the existence check instead of the legacy hardcoded path.
[[ \$(jq -r '.checkpoints | length' \"\$(state_path)\") == 1 ]] && echo OK2
state_set_gate_passed 4
[[ \$(state_last_gate_passed) == 4 ]] && echo OK3
state_finalize in_review --pr 42 --last-commit def5678
state_finished && echo OK4
state_clear --reason fixture
state_exists || echo OK5
" >/dev/null 2>&1
SET_RC=$?
[[ "$SET_RC" -eq 0 ]] && pass "state.sh: lifecycle round-trip" || fail "state.sh: round-trip exit=$SET_RC"

# ── Test: status reports active state once initialized ───────────────────────

bash -c "
source '$HOMEBASE/scripts/work/lib/state.sh'
state_init --issue HMB-99 --app myapp --branch main --kind chore --base-sha \$(git rev-parse HEAD)
" >/dev/null

OUT="$("$HOMEBASE/bin/homebase" work status --json 2>&1)"
INFLIGHT="$(printf '%s' "$OUT" | jq -r '.in_flight')"
ISSUE="$(printf '%s' "$OUT" | jq -r '.issue')"
assert_eq "$INFLIGHT" "true" "status: in_flight=true after state_init"
assert_eq "$ISSUE" "HMB-99" "status: issue=HMB-99"

# Cancel cleans up.
"$HOMEBASE/bin/homebase" work cancel >/dev/null 2>&1
[[ ! -f .homebase/work-state.json ]] && pass "cancel: removed state file" || fail "cancel: state file still present"

# ── Test: start refuses bad issue identifier ─────────────────────────────────

OUT="$("$HOMEBASE/bin/homebase" work start "not-a-key" 2>&1)" || true
assert_contains "$OUT" "must match" "start: rejects malformed issue id"

# ── Test: start with existing active state refuses ──────────────────────────

bash -c "
source '$HOMEBASE/scripts/work/lib/state.sh'
state_init --issue HMB-99 --app myapp --branch main --kind chore --base-sha \$(git rev-parse HEAD)
" >/dev/null
OUT="$("$HOMEBASE/bin/homebase" work start ZZ-100 2>&1)" || true
assert_contains "$OUT" "already exists" "start: refuses when work-state exists"
"$HOMEBASE/bin/homebase" work cancel >/dev/null 2>&1

# ── Test: gates.sh — pure-shell gates against current branch ─────────────────

# Init a fake state pointing at HEAD so branch-on-track passes.
bash -c "
source '$HOMEBASE/scripts/work/lib/state.sh'
state_init --issue HMB-99 --app myapp --branch \$(git rev-parse --abbrev-ref HEAD) --kind feature --base-sha \$(git rev-parse HEAD)
" >/dev/null

GATE_OUT="$(GATE_REPO_ROOT="$FIXTURE" bash -c "
. '$HOMEBASE/scripts/work/lib/gates.sh'
gate_state_loaded || true
gate_branch_on_track || true
gate_tree_clean || true
" 2>&1)" || true
assert_contains "$GATE_OUT" "[ok]   state-loaded" "gates: state-loaded passes"
assert_contains "$GATE_OUT" "[ok]   branch-on-track" "gates: branch-on-track passes"
assert_contains "$GATE_OUT" "[ok]   tree-clean" "gates: tree-clean passes"

# Tear down state.
"$HOMEBASE/bin/homebase" work cancel >/dev/null 2>&1

# ── Worktree-mode tests (HMB-27) ──────────────────────────────────────────────
#
# Build a separate fixture with `worktree.enabled: true` and exercise the
# parallel-worktree flow against it. The Linear gates inside `start.sh`
# require LINEAR_API_KEY for live lookups, so we drive the worktree
# library directly here (the same code path start.sh splices in).

WT_FIXTURE="${TMPDIR:-/tmp}/work-cli-test-wt-$$"
trap 'rc=$?; if [[ "$KEEP" -eq 0 ]]; then rm -rf "$FIXTURE" "$WT_FIXTURE"; fi; exit $rc' EXIT INT TERM

mkdir -p "$WT_FIXTURE/.homebase"
cd "$WT_FIXTURE"
git init -q
git config user.email test@example.com
git config user.name "Test User"
cat > .homebase/project.yml <<EOF
name: wtproj
display_name: Worktree fixture
description: HMB-27 worktree-mode tests
kind: monorepo
domains: [web]
apps:
  - name: wtapp
    path: apps/wtapp
    platforms: [web]
    status: active
    summary: Test app.
worktree:
  enabled: true
  share: []
  setup_command: "touch .setup-ran"
  teardown_command: "touch ../../.teardown-ran"
EOF
echo "wt" > README.md
echo ".worktrees/" > .gitignore
echo ".homebase/work-state.json" >> .gitignore
echo ".homebase/work-state.json.lock" >> .gitignore
echo ".homebase/work-state.*.json" >> .gitignore
echo ".homebase/work-state.*.json.lock" >> .gitignore
echo ".homebase/work-state.audit.log" >> .gitignore
echo ".homebase/work-finish-*.log" >> .gitignore
git add README.md .gitignore .homebase/project.yml
git commit -q -m "Initial fixture commit"
git checkout -q -b main 2>/dev/null || git switch -q main 2>/dev/null || true

# Drive the worktree library directly. Avoids needing live Linear creds.
WT_OUT="$(bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
if worktree_enabled '$WT_FIXTURE'; then echo 'enabled-yes'; else echo 'enabled-no'; fi
git -C '$WT_FIXTURE' branch wtproj/test-1 main 2>/dev/null
worktree_create '$WT_FIXTURE' wtproj/test-1
worktree_run_setup '$WT_FIXTURE/.worktrees/wtproj/test-1' WT-1
" 2>&1)"

assert_contains "$WT_OUT" "enabled-yes" "worktree: enabled flag picked up from project.yml"
assert_contains "$WT_OUT" "worktree: created $WT_FIXTURE/.worktrees/wtproj/test-1" "worktree: created on first call"
[[ -f "$WT_FIXTURE/.worktrees/wtproj/test-1/.setup-ran" ]] && \
  pass "worktree: setup_command ran inside the new worktree" || \
  fail "worktree: setup_command marker missing"
[[ -d "$WT_FIXTURE/.worktrees/wtproj/test-1/.homebase" ]] && \
  pass "worktree: .homebase dir auto-created" || \
  fail "worktree: .homebase dir missing"

# Second invocation is a no-op (idempotent).
WT_OUT2="$(bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
worktree_create '$WT_FIXTURE' wtproj/test-1
" 2>&1)"
assert_contains "$WT_OUT2" "reusing" "worktree: reuses existing path on second call"

# Two parallel worktrees on the same project don't collide on state.
bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
git -C '$WT_FIXTURE' branch wtproj/test-2 main 2>/dev/null
worktree_create '$WT_FIXTURE' wtproj/test-2 >/dev/null 2>&1
" 2>&1

# HMB-87 B.11: state files now live at the MAIN checkout's .homebase/, keyed by
# sha1(realpath(worktree-root)). Drive state.sh from inside each worktree so
# the SHA resolves to that worktree's path. Each invocation runs in its own
# shell so cwd doesn't leak between worktrees.
bash -c "
cd '$WT_FIXTURE/.worktrees/wtproj/test-1'
. '$HOMEBASE/scripts/work/lib/state.sh'
state_init --issue WT-1 --app wtapp --branch wtproj/test-1 --kind feature --linear-state-now 'In Progress'
"
bash -c "
cd '$WT_FIXTURE/.worktrees/wtproj/test-2'
. '$HOMEBASE/scripts/work/lib/state.sh'
state_init --issue WT-2 --app wtapp --branch wtproj/test-2 --kind feature --linear-state-now 'In Progress'
"

LIST_OUT="$(bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
worktree_list '$WT_FIXTURE'
" 2>&1)"
assert_contains "$LIST_OUT" "WT-1" "list: surfaces worktree 1's issue key from central state"
assert_contains "$LIST_OUT" "WT-2" "list: surfaces worktree 2's issue key from central state"

# HMB-87 B.11: verify two distinct SHA-keyed state files exist at the central
# location. This is the structural invariant — multiple worktrees, multiple
# state files, no collision on a single shared filename.
STATE_FILE_COUNT="$(ls "$WT_FIXTURE/.homebase/"work-state.*.json 2>/dev/null | grep -v '\.lock$' | wc -l | tr -d ' ')"
assert_eq "$STATE_FILE_COUNT" "2" "HMB-87 B.11: two parallel worktrees produce two central SHA-keyed state files"

# Each worktree's state.sh resolution returns its own state when invoked from
# inside that worktree. This proves the per-worktree SHA keying isolates state.
WT1_ISSUE="$(bash -c "
cd '$WT_FIXTURE/.worktrees/wtproj/test-1'
. '$HOMEBASE/scripts/work/lib/state.sh'
state_issue
")"
WT2_ISSUE="$(bash -c "
cd '$WT_FIXTURE/.worktrees/wtproj/test-2'
. '$HOMEBASE/scripts/work/lib/state.sh'
state_issue
")"
assert_eq "$WT1_ISSUE" "WT-1" "HMB-87 B.11: state.sh inside wt1 resolves to WT-1's state"
assert_eq "$WT2_ISSUE" "WT-2" "HMB-87 B.11: state.sh inside wt2 resolves to WT-2's state"

# HMB-87 B.11: legacy migration. Materialise a legacy single-file
# `<worktree>/.homebase/work-state.json` in a fresh third worktree, then
# resolve via state.sh and verify the file moved to the SHA-keyed central
# location with content intact.
bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
git -C '$WT_FIXTURE' branch wtproj/test-3 main 2>/dev/null
worktree_create '$WT_FIXTURE' wtproj/test-3 >/dev/null 2>&1
" 2>&1
mkdir -p "$WT_FIXTURE/.worktrees/wtproj/test-3/.homebase"
cat > "$WT_FIXTURE/.worktrees/wtproj/test-3/.homebase/work-state.json" <<'LEGACY_JSON'
{
  "schema_version": 1,
  "issue": "WT-3",
  "app": "wtapp",
  "branch": "wtproj/test-3",
  "kind": "feature",
  "linear_state_now": "In Progress",
  "started_at": "2026-05-19T00:00:00Z",
  "finished": false,
  "last_gate_passed": 0,
  "checkpoints": []
}
LEGACY_JSON
# Confirm the legacy file exists at the worktree's tree before migration.
[[ -f "$WT_FIXTURE/.worktrees/wtproj/test-3/.homebase/work-state.json" ]] && \
  pass "HMB-87 B.11 migration: legacy file created in worktree tree" || \
  fail "HMB-87 B.11 migration: legacy fixture file missing"

# Trigger migration via any read-side state helper.
WT3_ISSUE_AFTER_MIGRATE="$(bash -c "
cd '$WT_FIXTURE/.worktrees/wtproj/test-3'
. '$HOMEBASE/scripts/work/lib/state.sh'
state_issue
")"
assert_eq "$WT3_ISSUE_AFTER_MIGRATE" "WT-3" "HMB-87 B.11 migration: state_issue returns the migrated issue key"

# Legacy file should be gone from the worktree's tree.
if [[ -f "$WT_FIXTURE/.worktrees/wtproj/test-3/.homebase/work-state.json" ]]; then
  fail "HMB-87 B.11 migration: legacy file still present in worktree tree after migration"
else
  pass "HMB-87 B.11 migration: legacy file removed from worktree tree"
fi

# SHA-keyed file should now exist at the central location.
NEW_CENTRAL_COUNT="$(ls "$WT_FIXTURE/.homebase/"work-state.*.json 2>/dev/null | grep -v '\.lock$' | wc -l | tr -d ' ')"
assert_eq "$NEW_CENTRAL_COUNT" "3" "HMB-87 B.11 migration: third central state file exists after migration"

# HMB-87 B.9: start.sh skips the tree-clean gate when worktree mode is on.
# Drive the gate-evaluation code path against a dirty main checkout. The
# Linear-API gates will fail (no LINEAR_API_KEY) but the tree-clean line
# is what we're inspecting — it should emit `[skip] tree clean (worktree
# mode …)` rather than `[ok]` or `[fail]`.
#
# Setup: WT_FIXTURE needs workflow.yml (start.sh requires it), and wt-1's
# state must be cleared (otherwise start refuses on the active-state guard).
( cd "$WT_FIXTURE" && "$HOMEBASE/bin/homebase" work init >/dev/null 2>&1 || true )
git -C "$WT_FIXTURE" add -A >/dev/null 2>&1
git -C "$WT_FIXTURE" commit -q -m "Scaffold workflow.yml for B.9 test" 2>/dev/null || true
bash -c "
cd '$WT_FIXTURE/.worktrees/wtproj/test-1'
. '$HOMEBASE/scripts/work/lib/state.sh'
state_clear --reason b9-test
" >/dev/null 2>&1
echo "dirty-content-for-b9" >> "$WT_FIXTURE/README.md"
B9_OUT="$(cd "$WT_FIXTURE" && LINEAR_API_KEY="" "$HOMEBASE/bin/homebase" work start ZZ-100 --app wtapp 2>&1 || true)"
assert_contains "$B9_OUT" "[skip] tree clean" "HMB-87 B.9: tree-clean gate skipped in worktree mode"
# And the legacy-shaped failure line should not fire.
if echo "$B9_OUT" | grep -qE '\[fail\] tree clean'; then
  fail "HMB-87 B.9: tree-clean gate FAILED when it should have been skipped (worktree mode)"
else
  pass "HMB-87 B.9: tree-clean gate did not fail under dirty main + worktree mode"
fi
# Clean up: start.sh may have materialised a worktree at wtapp/100-work
# under WT_FIXTURE/.worktrees/. Tear it down so later tests aren't confused.
bash -c "
cd '$WT_FIXTURE'
. '$HOMEBASE/scripts/work/lib/worktree.sh'
worktree_destroy '$WT_FIXTURE/.worktrees/wtapp/100-work' ZZ-100 >/dev/null 2>&1 || true
" 2>/dev/null
git -C "$WT_FIXTURE" checkout -- README.md 2>/dev/null || true
# Re-init wt-1's state for the goto + destroy tests that follow.
bash -c "
cd '$WT_FIXTURE/.worktrees/wtproj/test-1'
. '$HOMEBASE/scripts/work/lib/state.sh'
state_init --issue WT-1 --app wtapp --branch wtproj/test-1 --kind feature --linear-state-now 'In Progress'
" >/dev/null 2>&1

# goto resolves to the right path.
GOTO_OUT="$(bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
worktree_for_issue WT-2 '$WT_FIXTURE'
" 2>&1)"
# git worktree list canonicalises macOS /var/folders → /private/var/folders;
# match against canonicalised fixture path so the test passes on both
# Linux and macOS.
WT_FIXTURE_CANON="$(cd "$WT_FIXTURE" && pwd -P)"
assert_eq "$GOTO_OUT" "$WT_FIXTURE_CANON/.worktrees/wtproj/test-2" "goto: maps WT-2 to its worktree path"

# Teardown.
DESTROY_OUT="$(bash -c "
cd '$WT_FIXTURE/.worktrees/wtproj/test-1'
. '$HOMEBASE/scripts/work/lib/worktree.sh'
worktree_destroy '$WT_FIXTURE/.worktrees/wtproj/test-1' WT-1
" 2>&1)"
assert_contains "$DESTROY_OUT" "removed $WT_FIXTURE/.worktrees/wtproj/test-1" "worktree: destroy removes the worktree dir"
[[ ! -d "$WT_FIXTURE/.worktrees/wtproj/test-1" ]] && \
  pass "worktree: filesystem dir gone after destroy" || \
  fail "worktree: filesystem dir still present after destroy"

# HMB-36: destroy must also delete the local branch ref so the project
# main checkout doesn't accumulate stale per-task branches.
assert_contains "$DESTROY_OUT" "deleted branch wtproj/test-1" "worktree: destroy deletes the local branch ref"
if git -C "$WT_FIXTURE" rev-parse --verify "wtproj/test-1" >/dev/null 2>&1; then
  fail "worktree: local branch ref still exists after destroy"
else
  pass "worktree: local branch ref gone after destroy"
fi

# DB suffix derivation.
SUFFIX="$(bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
worktree_db_suffix_for_issue HMB-27
")"
assert_eq "$SUFFIX" "_hmb_27" "worktree: db_suffix HMB-27 → _hmb_27"

# ── HMB-98: session-end-cleanup is a documented no-op ────────────────────────
#
# Tier-2 simplification removed the Stop-hook worktree destruction (was
# HMB-87 B.12). The hook must now NEVER destroy a worktree or branch — even
# an empty session-worktree with the session env vars set. Worktrees are
# disposed only by the explicit `homebase work finish` / `cancel` verbs.

NOOP_ID="20260519-noop1"
NOOP_WT="$WT_FIXTURE/.worktrees/session-$NOOP_ID"
NOOP_BR="session/$NOOP_ID"
git -C "$WT_FIXTURE" worktree add "$NOOP_WT" -b "$NOOP_BR" main >/dev/null 2>&1
( cd "$WT_FIXTURE" && \
  HOMEBASE_SESSION_WORKTREE="$NOOP_WT" \
  HOMEBASE_SESSION_BRANCH="$NOOP_BR" \
  bash "$HOMEBASE/scripts/hooks/session-end-cleanup.sh" </dev/null >/dev/null 2>&1 ) || true
[[ -d "$NOOP_WT" ]] && \
  pass "HMB-98: session-end-cleanup no-op — empty session-worktree preserved" || \
  fail "HMB-98: session-end-cleanup destroyed a worktree (must never destroy post-Tier-2)"
if git -C "$WT_FIXTURE" rev-parse --verify "$NOOP_BR" >/dev/null 2>&1; then
  pass "HMB-98: session-end-cleanup no-op — session branch preserved"
else
  fail "HMB-98: session-end-cleanup deleted a branch (must never delete post-Tier-2)"
fi
# Cleanup by hand.
HOMEBASE_WORK_AUTHORIZED=1 git -C "$WT_FIXTURE" worktree remove --force "$NOOP_WT" 2>/dev/null || true
HOMEBASE_WORK_AUTHORIZED=1 git -C "$WT_FIXTURE" branch -D "$NOOP_BR" 2>/dev/null || true

# ── HMB-87 B.10: edit-main-checkout-guard PreToolUse hook ─────────────────────
#
# Belt-and-suspenders gate. Denies Edit/Write/MultiEdit/NotebookEdit
# against files in a worktree-enabled project's main checkout when no
# active work-state exists and HOMEBASE_OFF_CONTRACT=1 is unset. Tests
# exercise the deny + 3 allow paths against the WT_FIXTURE setup.
#
# Note: claude-precommit.sh's bypass-flag check fires on any command
# string containing `git commit` AND `-n`. We avoid jq -n + git commit
# in the same Bash invocation to dodge that false-positive when running
# under Claude Code.

# Helper: synthesise a Claude PreToolUse JSON payload for a given target.
make_payload() {
  local target="$1"
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s","old_string":"x","new_string":"y"}}' "$target"
}

# Ensure WT_FIXTURE has no active state for the project main itself
# (the worktree-state files for wt-2/wt-3 are still around, but they're
# keyed to those worktrees' SHAs, not to the main).
# Compute main's own SHA-keyed state path; should NOT exist.
WT_MAIN_SHA="$(printf '%s' "$WT_FIXTURE" | shasum | cut -c1-8)"
WT_MAIN_STATE="$WT_FIXTURE/.homebase/work-state.$WT_MAIN_SHA.json"
[[ -f "$WT_MAIN_STATE" ]] && rm -f "$WT_MAIN_STATE"

# Detach the worktrees' state files temporarily so the hook can't find
# ANY active state (its glob walks the central .homebase/ directory).
STASH_DIR="$WT_FIXTURE/.homebase/.b10-stash"
mkdir -p "$STASH_DIR"
mv "$WT_FIXTURE/.homebase/"work-state.*.json "$STASH_DIR/" 2>/dev/null || true
mv "$WT_FIXTURE/.homebase/"work-state.*.json.lock "$STASH_DIR/" 2>/dev/null || true

# Case 1: target in main, no active state, no opt-out → DENY.
PAYLOAD="$(make_payload "$WT_FIXTURE/README.md")"
HOOK_OUT="$(printf '%s' "$PAYLOAD" | bash "$HOMEBASE/scripts/hooks/edit-main-checkout-guard.sh" 2>&1)"
HOOK_RC=$?
assert_eq "$HOOK_RC" "0" "HMB-87 B.10: hook exits 0 on deny (per Claude Code hook contract)"
assert_contains "$HOOK_OUT" "permissionDecision" "HMB-87 B.10: hook emits hookSpecificOutput on deny"
assert_contains "$HOOK_OUT" "edit-main-checkout-guard" "HMB-87 B.10: deny reason names the hook"
assert_contains "$HOOK_OUT" "homebase work start" "HMB-87 B.10: deny reason names work start"
assert_contains "$HOOK_OUT" "homebase work chore" "HMB-87 B.10: deny reason names work chore"
assert_contains "$HOOK_OUT" "HOMEBASE_OFF_CONTRACT" "HMB-87 B.10: deny reason names OFF_CONTRACT"

# Case 2: HOMEBASE_OFF_CONTRACT=1 → ALLOW (silent).
HOOK_OUT="$(HOMEBASE_OFF_CONTRACT=1 printf '%s' "$PAYLOAD" | HOMEBASE_OFF_CONTRACT=1 bash "$HOMEBASE/scripts/hooks/edit-main-checkout-guard.sh" 2>&1)"
HOOK_RC=$?
assert_eq "$HOOK_RC" "0" "HMB-87 B.10: hook exits 0 with OFF_CONTRACT"
assert_eq "$HOOK_OUT" "" "HMB-87 B.10: hook is silent with OFF_CONTRACT=1"

# Case 3: target inside a worktree dir → ALLOW (silent).
PAYLOAD2="$(make_payload "$WT_FIXTURE/.worktrees/wtproj/test-2/some-file")"
HOOK_OUT="$(printf '%s' "$PAYLOAD2" | bash "$HOMEBASE/scripts/hooks/edit-main-checkout-guard.sh" 2>&1)"
assert_eq "$HOOK_OUT" "" "HMB-87 B.10: hook is silent for edits inside a worktree"

# Case 4: target in a non-homebase project → ALLOW (silent).
PAYLOAD3="$(make_payload "/tmp/some-arbitrary/file.txt")"
HOOK_OUT="$(printf '%s' "$PAYLOAD3" | bash "$HOMEBASE/scripts/hooks/edit-main-checkout-guard.sh" 2>&1)"
assert_eq "$HOOK_OUT" "" "HMB-87 B.10: hook is silent for non-homebase paths"

# Restore the worktrees' state files for later tests.
mv "$STASH_DIR/"work-state.*.json "$WT_FIXTURE/.homebase/" 2>/dev/null || true
mv "$STASH_DIR/"work-state.*.json.lock "$WT_FIXTURE/.homebase/" 2>/dev/null || true
rmdir "$STASH_DIR" 2>/dev/null || true

# Case 5: with active state restored → ALLOW (silent), even on main-target.
HOOK_OUT="$(printf '%s' "$PAYLOAD" | bash "$HOMEBASE/scripts/hooks/edit-main-checkout-guard.sh" 2>&1)"
assert_eq "$HOOK_OUT" "" "HMB-87 B.10: hook is silent when an active work-state exists in the project"

# ── HMB-86: chore verb (chore.sh + cmd_work routing + work-cli-guard B.4) ────
#
# Detach the worktrees' states so chore.sh's state_active check passes
# (otherwise the chore.sh verb would refuse with "active work-state").
mkdir -p "$STASH_DIR"
mv "$WT_FIXTURE/.homebase/"work-state.*.json "$STASH_DIR/" 2>/dev/null || true
mv "$WT_FIXTURE/.homebase/"work-state.*.json.lock "$STASH_DIR/" 2>/dev/null || true

# B.1: chore.sh derives a kebab-case slug from <desc>, creates a worktree
# and writes a kind:chore state with issue:null.
CHORE_OUT="$(cd "$WT_FIXTURE" && "$HOMEBASE/bin/homebase" work chore "Fix SOP-001 typo" 2>&1 || true)"
assert_contains "$CHORE_OUT" "slug:     fix-sop-001-typo" "HMB-86 B.1: chore.sh derives kebab-case slug from desc"
assert_contains "$CHORE_OUT" "branch:   created chore/fix-sop-001-typo" "HMB-86 B.1: chore.sh creates chore/<slug> branch"
assert_contains "$CHORE_OUT" "worktree: created" "HMB-86 B.1: chore.sh creates worktree"
[[ -d "$WT_FIXTURE/.worktrees/chore/fix-sop-001-typo" ]] && \
  pass "HMB-86 B.1: chore.sh filesystem path .worktrees/chore/<slug> materialised" || \
  fail "HMB-86 B.1: chore.sh filesystem path missing"

# Verify the state file has kind:chore and issue:null.
CHORE_WT="$WT_FIXTURE/.worktrees/chore/fix-sop-001-typo"
CHORE_SHA="$(printf '%s' "$(cd "$CHORE_WT" && pwd -P)" | shasum | cut -c1-8)"
CHORE_STATE="$WT_FIXTURE/.homebase/work-state.$CHORE_SHA.json"
[[ -f "$CHORE_STATE" ]] && \
  pass "HMB-86 B.1: chore.sh writes SHA-keyed central work-state for the chore worktree" || \
  fail "HMB-86 B.1: chore state file missing at $CHORE_STATE"
CHORE_KIND="$(jq -r '.kind' "$CHORE_STATE" 2>/dev/null)"
CHORE_ISSUE="$(jq -r '.issue' "$CHORE_STATE" 2>/dev/null)"
assert_eq "$CHORE_KIND" "chore" "HMB-86 B.1: state.kind == chore"
assert_eq "$CHORE_ISSUE" "null" "HMB-86 B.1: state.issue == null (JSON null)"

# B.2: chore is routed through bin/homebase (cmd_work case).
HELP_OUT="$("$HOMEBASE/bin/homebase" work help 2>&1)"
assert_contains "$HELP_OUT" "chore \"<desc>\"" "HMB-86 B.2: bin/homebase work help lists the chore verb"

# B.4: work-cli-guard-hook denies bare chore: direct-to-main commits when
# worktree.enabled: true and no active state and HOMEBASE_OFF_CONTRACT unset.
# Use a heredoc to construct the JSON payload — bash double-quote-driven
# printf interpolation drops the inner quote escaping and silently produces
# malformed JSON that the hook's Python parser then rejects.
GUARD_PAYLOAD_FILE="$(mktemp)"
cat > "$GUARD_PAYLOAD_FILE" <<'PAYLOAD_JSON'
{"tool_name":"Bash","tool_input":{"command":"git commit -m \"chore: tweak\""}}
PAYLOAD_JSON

# Teardown the chore-worktree first so the next check sees no active state.
HOMEBASE_WORK_AUTHORIZED=1 git -C "$WT_FIXTURE" worktree remove --force "$CHORE_WT" 2>/dev/null || true
HOMEBASE_WORK_AUTHORIZED=1 git -C "$WT_FIXTURE" branch -D chore/fix-sop-001-typo 2>/dev/null || true
rm -f "$CHORE_STATE" "$CHORE_STATE.lock"

# Bare chore: commit when worktree mode is on and no state → DENY.
GUARD_OUT="$(cd "$WT_FIXTURE" && bash "$HOMEBASE/scripts/hooks/work-cli-guard-hook.sh" < "$GUARD_PAYLOAD_FILE" 2>&1)"
assert_contains "$GUARD_OUT" "homebase work chore" "HMB-86 B.4: guard deny names the chore-verb"
assert_contains "$GUARD_OUT" "HOMEBASE_OFF_CONTRACT" "HMB-86 B.4: guard deny names the OFF_CONTRACT escape"
assert_contains "$GUARD_OUT" "rule 6" "HMB-86 B.4: guard deny references contract rule 6"

# Bare chore: commit with HOMEBASE_OFF_CONTRACT=1 → ALLOW (silent).
GUARD_OUT="$(cd "$WT_FIXTURE" && HOMEBASE_OFF_CONTRACT=1 bash "$HOMEBASE/scripts/hooks/work-cli-guard-hook.sh" < "$GUARD_PAYLOAD_FILE" 2>&1)"
assert_eq "$GUARD_OUT" "" "HMB-86 B.4: guard is silent with HOMEBASE_OFF_CONTRACT=1"
rm -f "$GUARD_PAYLOAD_FILE"

# Restore the worktrees' states for later tests.
mv "$STASH_DIR/"work-state.*.json "$WT_FIXTURE/.homebase/" 2>/dev/null || true
mv "$STASH_DIR/"work-state.*.json.lock "$WT_FIXTURE/.homebase/" 2>/dev/null || true
rmdir "$STASH_DIR" 2>/dev/null || true


cd "$FIXTURE"

# ── Test: roadmap render guard refuses on main (HMB-45 F4) ───────────────────
# The render.sh wrapper must refuse when HEAD is on main without
# --allow-on-main; honour the override; pass through on any other branch.
# We invoke render.sh directly (not via `homebase roadmap render`) because
# the wrapper is the unit under test and we need the failure path observable
# without requiring Linear API connectivity.

RENDER_FIXTURE="${TMPDIR:-/tmp}/work-cli-render-guard-$$"
mkdir -p "$RENDER_FIXTURE"
git -C "$RENDER_FIXTURE" init -q
git -C "$RENDER_FIXTURE" config user.email test@example.com
git -C "$RENDER_FIXTURE" config user.name "Test User"
echo "stub" > "$RENDER_FIXTURE/README.md"
git -C "$RENDER_FIXTURE" add README.md
git -C "$RENDER_FIXTURE" commit -q -m "chore: stub commit"
git -C "$RENDER_FIXTURE" branch -m main 2>/dev/null || git -C "$RENDER_FIXTURE" checkout -q -b main

# Copy (not symlink) render.sh into the fixture so SCRIPT_DIR resolves
# inside the fixture. A symlink would have `cd "$(dirname …)"` chase back
# to homebase and our stub linear.rb would never be reached.
mkdir -p "$RENDER_FIXTURE/scripts/roadmap"
cp "$HOMEBASE/scripts/roadmap/render.sh" "$RENDER_FIXTURE/scripts/roadmap/render.sh"
chmod +x "$RENDER_FIXTURE/scripts/roadmap/render.sh"

# Case 1: on main + clean tree, no flag → refuse with exit 2.
set +e
RENDER_OUT="$(cd "$RENDER_FIXTURE" && bash "$RENDER_FIXTURE/scripts/roadmap/render.sh" 2>&1)"
RENDER_RC=$?
set -e
assert_eq "$RENDER_RC" "2" "render-guard: refuses on main with exit 2"
assert_contains "$RENDER_OUT" "refused on 'main'" "render-guard: message names branch"
assert_contains "$RENDER_OUT" "--allow-on-main" "render-guard: message points at override"

# Case 2: on a feature branch → wrapper proceeds past the guard. We can't
# test the full exec ruby ... render path without Linear creds, but we can
# verify the guard is bypassed by inspecting the wrapper's behaviour up to
# the exec — substitute a stub linear.rb that prints and exits 0.
git -C "$RENDER_FIXTURE" checkout -q -b feature/test
cat > "$RENDER_FIXTURE/scripts/roadmap/linear.rb" <<'STUB'
#!/usr/bin/env ruby
# Test stub for render guard — proves render.sh reached exec.
puts "STUB-RENDER-OK arg0=#{ARGV[0]}"
exit 0
STUB
chmod +x "$RENDER_FIXTURE/scripts/roadmap/linear.rb"

set +e
RENDER_OUT="$(cd "$RENDER_FIXTURE" && bash "$RENDER_FIXTURE/scripts/roadmap/render.sh" 2>&1)"
RENDER_RC=$?
set -e
assert_eq "$RENDER_RC" "0" "render-guard: feature branch passes through (exit 0)"
assert_contains "$RENDER_OUT" "STUB-RENDER-OK arg0=render" "render-guard: forwards 'render' arg to linear.rb"

# Case 3: --allow-on-main on main → guard waived, wrapper proceeds.
git -C "$RENDER_FIXTURE" checkout -q main
set +e
RENDER_OUT="$(cd "$RENDER_FIXTURE" && bash "$RENDER_FIXTURE/scripts/roadmap/render.sh" --allow-on-main 2>&1)"
RENDER_RC=$?
set -e
assert_eq "$RENDER_RC" "0" "render-guard: --allow-on-main on main passes through"
assert_contains "$RENDER_OUT" "STUB-RENDER-OK" "render-guard: --allow-on-main forwards"
# The flag must not appear in the forwarded args (stripped before exec).
if [[ "$RENDER_OUT" == *"--allow-on-main"* ]]; then
  fail "render-guard: --allow-on-main leaked into forwarded args"
else
  pass "render-guard: --allow-on-main stripped from forwarded args"
fi

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$RENDER_FIXTURE"; fi

# ── Test: ui-verified hook accepts trailer in body and trailer block (HMB-45 F5)
# Defensive armor — if anyone refactors ui-verification-check.sh to use
# git-style trailer parsing, this test catches the regression. The hook
# is line-anchored, so both placements must pass; only a missing trailer
# (or a misspelt prefix) blocks.

UIV_FIXTURE="${TMPDIR:-/tmp}/work-cli-uiv-$$"
mkdir -p "$UIV_FIXTURE"
git -C "$UIV_FIXTURE" init -q
git -C "$UIV_FIXTURE" config user.email test@example.com
git -C "$UIV_FIXTURE" config user.name "Test User"
mkdir -p "$UIV_FIXTURE/app/views"
# Five stub commits so HEAD~5 exists for the hook's fallback range.
for i in 1 2 3 4 5; do
  echo "$i" > "$UIV_FIXTURE/stub$i"
  git -C "$UIV_FIXTURE" add "stub$i"
  git -C "$UIV_FIXTURE" commit -q -m "chore: stub $i"
done

# Case A: Verified-in-browser in the body, above a final trailer block.
echo '<div>case-a</div>' > "$UIV_FIXTURE/app/views/case_a.erb"
git -C "$UIV_FIXTURE" add app/views/case_a.erb
git -C "$UIV_FIXTURE" commit -q -m "feat(stub): F5 case A body placement

Some descriptive paragraph here.

Verified in browser: case A page renders without layout shift

The final trailer block follows after another blank line.

Refs HMB-45"
set +e
(cd "$UIV_FIXTURE" && bash "$HOMEBASE/scripts/hooks/ui-verification-check.sh") >/dev/null 2>&1
UIV_A_RC=$?
set -e
assert_eq "$UIV_A_RC" "0" "ui-verified: trailer in body (above blank-line + trailer block) accepted"

# Case B: Verified-in-browser in the trailer block.
echo '<div>case-b</div>' > "$UIV_FIXTURE/app/views/case_b.erb"
git -C "$UIV_FIXTURE" add app/views/case_b.erb
git -C "$UIV_FIXTURE" commit -q -m "feat(stub): F5 case B trailer-block placement

Some descriptive paragraph here.

Refs HMB-45
Verified in browser: case B page renders without layout shift"
set +e
(cd "$UIV_FIXTURE" && bash "$HOMEBASE/scripts/hooks/ui-verification-check.sh") >/dev/null 2>&1
UIV_B_RC=$?
set -e
assert_eq "$UIV_B_RC" "0" "ui-verified: trailer in trailer block accepted"

# Case C: No Verified trailer at all — strict mode must block.
echo '<div>case-c</div>' > "$UIV_FIXTURE/app/views/case_c.erb"
git -C "$UIV_FIXTURE" add app/views/case_c.erb
git -C "$UIV_FIXTURE" commit -q -m "feat(stub): F5 case C control no trailer

body

Refs HMB-45"
set +e
(cd "$UIV_FIXTURE" && bash "$HOMEBASE/scripts/hooks/ui-verification-check.sh") >/dev/null 2>&1
UIV_C_RC=$?
set -e
assert_eq "$UIV_C_RC" "2" "ui-verified: missing trailer blocks (control)"

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$UIV_FIXTURE"; fi

# ── Test: worktree_trust_mise (HMB-45 F6) ────────────────────────────────────
# The function must be idempotent and silent. Behaviour-coverage:
#   - missing path → no-op, returns 0
#   - mise absent from PATH → no-op, returns 0
#   - mise present, path exists → calls `mise trust` (we stub mise to record
#     the invocation; we don't assert against the real mise binary because
#     CI machines may not have it).

MISE_FIXTURE="${TMPDIR:-/tmp}/work-cli-mise-$$"
mkdir -p "$MISE_FIXTURE/wt"
mkdir -p "$MISE_FIXTURE/bin"

# Stub `mise` that records its arguments to a log file.
cat > "$MISE_FIXTURE/bin/mise" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$MISE_LOG"
exit 0
STUB
chmod +x "$MISE_FIXTURE/bin/mise"

# Case 1: missing path → no-op
TRUST_RC="$(bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
worktree_trust_mise '/nonexistent/path/that/does/not/exist'
echo \$?
")"
assert_eq "$TRUST_RC" "0" "worktree_trust_mise: missing path returns 0 (no-op)"

# Case 2: mise absent from PATH → no-op
TRUST_RC="$(env PATH=/usr/bin:/bin bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
worktree_trust_mise '$MISE_FIXTURE/wt'
echo \$?
" 2>/dev/null)"
assert_eq "$TRUST_RC" "0" "worktree_trust_mise: mise not on PATH returns 0 (no-op)"

# Case 3: mise present (stubbed) → invokes `mise trust <wt>`
export MISE_LOG="$MISE_FIXTURE/mise.log"
: > "$MISE_LOG"
TRUST_RC="$(env PATH="$MISE_FIXTURE/bin:/usr/bin:/bin" MISE_LOG="$MISE_LOG" bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
worktree_trust_mise '$MISE_FIXTURE/wt'
echo \$?
")"
assert_eq "$TRUST_RC" "0" "worktree_trust_mise: returns 0 when mise stub succeeds"
TRUST_LOG="$(cat "$MISE_LOG" 2>/dev/null || echo '')"
assert_contains "$TRUST_LOG" "trust $MISE_FIXTURE/wt" "worktree_trust_mise: invokes 'mise trust <wt>'"
# install MUST NOT run when MISE_AUTO_INSTALL is unset.
if [[ "$TRUST_LOG" == *"install"* ]]; then
  fail "worktree_trust_mise: ran 'mise install' without MISE_AUTO_INSTALL=1"
else
  pass "worktree_trust_mise: skips 'mise install' when MISE_AUTO_INSTALL unset"
fi

# Case 4: MISE_AUTO_INSTALL=1 → invokes both trust and install
: > "$MISE_LOG"
env PATH="$MISE_FIXTURE/bin:/usr/bin:/bin" MISE_LOG="$MISE_LOG" MISE_AUTO_INSTALL=1 bash -c "
. '$HOMEBASE/scripts/work/lib/worktree.sh'
worktree_trust_mise '$MISE_FIXTURE/wt'
" >/dev/null 2>&1
TRUST_LOG="$(cat "$MISE_LOG" 2>/dev/null || echo '')"
assert_contains "$TRUST_LOG" "trust $MISE_FIXTURE/wt" "worktree_trust_mise (auto-install): trust still ran"
assert_contains "$TRUST_LOG" "install" "worktree_trust_mise (auto-install): install ran when MISE_AUTO_INSTALL=1"

unset MISE_LOG
if [[ "$KEEP" -eq 0 ]]; then rm -rf "$MISE_FIXTURE"; fi

# ── Test: workflow.yml staleness warning logic (HMB-45 F2) ───────────────────
# The exact bash snippet inlined into scripts/work/start.sh emits a stderr
# warning when origin/main has commits since BRANCH_BASE that touched
# .homebase/workflow.yml. Tested via a fixture with a bare-repo "origin"
# and a clone whose local main is intentionally behind.

STALE_FIXTURE="${TMPDIR:-/tmp}/work-cli-stale-$$"
mkdir -p "$STALE_FIXTURE"
ORIGIN_REPO="$STALE_FIXTURE/origin.git"
LOCAL_REPO="$STALE_FIXTURE/clone"

git init -q --bare "$ORIGIN_REPO"
git clone -q "$ORIGIN_REPO" "$LOCAL_REPO"
git -C "$LOCAL_REPO" config user.email test@example.com
git -C "$LOCAL_REPO" config user.name "Test User"
git -C "$LOCAL_REPO" checkout -q -b main 2>/dev/null || true
mkdir -p "$LOCAL_REPO/.homebase"
echo "version: 1" > "$LOCAL_REPO/.homebase/workflow.yml"
git -C "$LOCAL_REPO" add .homebase/workflow.yml
git -C "$LOCAL_REPO" commit -q -m "chore: initial workflow.yml"
git -C "$LOCAL_REPO" push -q origin main

# Snapshot the SHA we'll branch from (the "stale" base).
STALE_BASE_FOR_TEST="$(git -C "$LOCAL_REPO" rev-parse HEAD)"

# Advance origin/main with a workflow.yml change.
echo "version: 1
changed: true" > "$LOCAL_REPO/.homebase/workflow.yml"
git -C "$LOCAL_REPO" add .homebase/workflow.yml
git -C "$LOCAL_REPO" commit -q -m "chore: bump workflow.yml gates"
git -C "$LOCAL_REPO" push -q origin main

# Rewind local main to the stale base (simulates the operator's branch
# base predating origin/main's workflow.yml change).
git -C "$LOCAL_REPO" reset -q --hard "$STALE_BASE_FOR_TEST"
git -C "$LOCAL_REPO" fetch -q origin main:refs/remotes/origin/main 2>/dev/null || true

# Inline the exact check from start.sh and capture stderr.
STALE_OUT="$(bash -c '
PROJECT_ROOT="'$LOCAL_REPO'"
BRANCH_BASE="main"
NO_BRANCH=0
if [[ "$NO_BRANCH" -eq 0 ]]; then
  STALE_BASE_SHA="$(git -C "$PROJECT_ROOT" rev-parse "$BRANCH_BASE" 2>/dev/null || echo "")"
  if [[ -n "$STALE_BASE_SHA" ]] && \
     git -C "$PROJECT_ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
    STALE_COMMITS="$(git -C "$PROJECT_ROOT" log --oneline \
      "$STALE_BASE_SHA..origin/main" -- .homebase/workflow.yml 2>/dev/null || true)"
    if [[ -n "$STALE_COMMITS" ]]; then
      echo "  [warn] .homebase/workflow.yml on origin/main has changes since branch base ($BRANCH_BASE):" >&2
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "         $line" >&2
      done <<< "$STALE_COMMITS"
    fi
  fi
fi
' 2>&1 1>/dev/null)"
assert_contains "$STALE_OUT" "[warn] .homebase/workflow.yml on origin/main has changes" "stale-yml: warning emitted when origin/main moved"
assert_contains "$STALE_OUT" "bump workflow.yml gates" "stale-yml: warning lists the offending commit"

# Now bring local main current with origin and re-run — warning must NOT appear.
git -C "$LOCAL_REPO" reset -q --hard origin/main
NO_STALE_OUT="$(bash -c '
PROJECT_ROOT="'$LOCAL_REPO'"
BRANCH_BASE="main"
STALE_BASE_SHA="$(git -C "$PROJECT_ROOT" rev-parse "$BRANCH_BASE" 2>/dev/null || echo "")"
if [[ -n "$STALE_BASE_SHA" ]] && \
   git -C "$PROJECT_ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
  STALE_COMMITS="$(git -C "$PROJECT_ROOT" log --oneline \
    "$STALE_BASE_SHA..origin/main" -- .homebase/workflow.yml 2>/dev/null || true)"
  if [[ -n "$STALE_COMMITS" ]]; then
    echo "  [warn] stale" >&2
  fi
fi
' 2>&1 1>/dev/null)"
if [[ -z "$NO_STALE_OUT" ]]; then
  pass "stale-yml: silent when local main matches origin/main"
else
  fail "stale-yml: false-positive warning when up to date — got: $NO_STALE_OUT"
fi

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$STALE_FIXTURE"; fi

# ── Test: gate_commits_present (HMB-45 F9) ───────────────────────────────────
# Refuses on empty commit range (base_sha == HEAD). Pure unit test against
# the gate function — sourced from gates.sh + state.sh against a synthetic
# repo and a stub work-state.json.

CP_FIXTURE="${TMPDIR:-/tmp}/work-cli-cp-$$"
mkdir -p "$CP_FIXTURE/.homebase"
git -C "$CP_FIXTURE" init -q
git -C "$CP_FIXTURE" config user.email test@example.com
git -C "$CP_FIXTURE" config user.name "Test User"
echo seed > "$CP_FIXTURE/seed"
git -C "$CP_FIXTURE" add seed
git -C "$CP_FIXTURE" commit -q -m "chore: seed"
CP_BASE_SHA="$(git -C "$CP_FIXTURE" rev-parse HEAD)"
git -C "$CP_FIXTURE" branch -m main 2>/dev/null || git -C "$CP_FIXTURE" checkout -q -b main

# Stub work-state.json with base_sha == HEAD (empty range).
cat > "$CP_FIXTURE/.homebase/work-state.json" <<EOF
{
  "schema_version": 1,
  "issue": "WT-99",
  "branch": "main",
  "base_sha": "$CP_BASE_SHA",
  "kind": "feature",
  "finished": false,
  "checkpoints": [],
  "last_gate_passed": 3
}
EOF

set +e
CP_OUT="$(GATE_REPO_ROOT="$CP_FIXTURE" bash -c "
. '$HOMEBASE/scripts/work/lib/state.sh'
. '$HOMEBASE/scripts/work/lib/gates.sh'
gate_commits_present
" 2>&1)"
CP_RC=$?
set -e
assert_eq "$CP_RC" "2" "commits-present: empty range returns GATE_FAIL=2"
assert_contains "$CP_OUT" "[fail] commits-present" "commits-present: emits [fail] line"
assert_contains "$CP_OUT" "No commits between base" "commits-present: message names empty range"
assert_contains "$CP_OUT" "wrong branch" "commits-present: message points at the wrong-branch failure mode"

# Now add a commit to make the range non-empty, re-run.
echo more > "$CP_FIXTURE/feature"
git -C "$CP_FIXTURE" add feature
git -C "$CP_FIXTURE" commit -q -m "feat(stub): real work

Refs WT-99"

set +e
CP_OUT="$(GATE_REPO_ROOT="$CP_FIXTURE" bash -c "
. '$HOMEBASE/scripts/work/lib/state.sh'
. '$HOMEBASE/scripts/work/lib/gates.sh'
gate_commits_present
" 2>&1)"
CP_RC=$?
set -e
assert_eq "$CP_RC" "0" "commits-present: non-empty range returns 0 (pass)"
assert_contains "$CP_OUT" "[ok]" "commits-present: emits [ok] when commits present"

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$CP_FIXTURE"; fi

# ── Test: commit-sop-check wrong-branch gate (HMB-45 F8) ─────────────────────
# Pipes a valid message into commit-sop-check.sh from inside a fixture repo
# and asserts the gate's behaviour against four state combinations.

WB_FIXTURE="${TMPDIR:-/tmp}/work-cli-wb-$$"
mkdir -p "$WB_FIXTURE/.homebase"
git -C "$WB_FIXTURE" init -q
git -C "$WB_FIXTURE" config user.email test@example.com
git -C "$WB_FIXTURE" config user.name "Test User"
echo seed > "$WB_FIXTURE/seed"
git -C "$WB_FIXTURE" add seed
git -C "$WB_FIXTURE" commit -q -m "chore: seed"
git -C "$WB_FIXTURE" branch -m main 2>/dev/null || git -C "$WB_FIXTURE" checkout -q -b main
git -C "$WB_FIXTURE" checkout -q -b feature/wb-test

# A valid message that satisfies the trailer/anti-pattern checks so the
# wrong-branch check is the only thing that can fail.
WB_MSG='feat(stub): F8 wrong-branch test

body

Refs WT-99'

# Case 1: state.branch matches current_branch → exit 0
cat > "$WB_FIXTURE/.homebase/work-state.json" <<EOF
{"schema_version":1,"issue":"WT-99","branch":"feature/wb-test","finished":false,"checkpoints":[],"last_gate_passed":0,"base_sha":"$(git -C "$WB_FIXTURE" rev-parse HEAD)"}
EOF
set +e
WB_OUT="$(cd "$WB_FIXTURE" && printf '%s\n' "$WB_MSG" | bash "$HOMEBASE/scripts/hooks/commit-sop-check.sh" 2>&1)"
WB_RC=$?
set -e
assert_eq "$WB_RC" "0" "wrong-branch: matching branch passes"

# Case 2: state.branch != current_branch → exit 1
cat > "$WB_FIXTURE/.homebase/work-state.json" <<EOF
{"schema_version":1,"issue":"WT-99","branch":"shopos/1393-rewrite-seeds","finished":false,"checkpoints":[],"last_gate_passed":0,"base_sha":"$(git -C "$WB_FIXTURE" rev-parse HEAD)"}
EOF
set +e
WB_OUT="$(cd "$WB_FIXTURE" && printf '%s\n' "$WB_MSG" | bash "$HOMEBASE/scripts/hooks/commit-sop-check.sh" 2>&1)"
WB_RC=$?
set -e
assert_eq "$WB_RC" "1" "wrong-branch: mismatched branch blocks (exit 1)"
assert_contains "$WB_OUT" "wrong-branch commit" "wrong-branch: emits the violation header"
assert_contains "$WB_OUT" "shopos/1393-rewrite-seeds" "wrong-branch: names the expected branch"
assert_contains "$WB_OUT" "feature/wb-test" "wrong-branch: names the current branch"
assert_contains "$WB_OUT" "homebase work goto WT-99" "wrong-branch: points at homebase work goto recovery"
assert_contains "$WB_OUT" "HOMEBASE_OFF_CONTRACT=1" "wrong-branch: documents the escape hatch"

# Case 3: HOMEBASE_OFF_CONTRACT=1 with mismatched branch → exit 0
set +e
WB_OUT="$(cd "$WB_FIXTURE" && HOMEBASE_OFF_CONTRACT=1 printf '%s\n' "$WB_MSG" | HOMEBASE_OFF_CONTRACT=1 bash "$HOMEBASE/scripts/hooks/commit-sop-check.sh" 2>&1)"
WB_RC=$?
set -e
assert_eq "$WB_RC" "0" "wrong-branch: HOMEBASE_OFF_CONTRACT=1 escape allows"

# Case 4: state.finished == true → exit 0 (work-state closed)
cat > "$WB_FIXTURE/.homebase/work-state.json" <<EOF
{"schema_version":1,"issue":"WT-99","branch":"shopos/1393-rewrite-seeds","finished":true,"checkpoints":[],"last_gate_passed":14,"base_sha":"$(git -C "$WB_FIXTURE" rev-parse HEAD)"}
EOF
set +e
WB_OUT="$(cd "$WB_FIXTURE" && printf '%s\n' "$WB_MSG" | bash "$HOMEBASE/scripts/hooks/commit-sop-check.sh" 2>&1)"
WB_RC=$?
set -e
assert_eq "$WB_RC" "0" "wrong-branch: finished work-state allows"

# Case 5: no work-state.json → exit 0
rm -f "$WB_FIXTURE/.homebase/work-state.json"
set +e
WB_OUT="$(cd "$WB_FIXTURE" && printf '%s\n' "$WB_MSG" | bash "$HOMEBASE/scripts/hooks/commit-sop-check.sh" 2>&1)"
WB_RC=$?
set -e
assert_eq "$WB_RC" "0" "wrong-branch: no work-state allows"

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$WB_FIXTURE"; fi

# ── Test: project-resolver helpers (HMB-45 F7) ───────────────────────────────
# Synthetic homebase root with two projects; verifies app_to_project_path,
# linear_project_name_to_project_path, and cwd_in_project_path against
# both the matching and non-matching cases.

PR_FIXTURE="${TMPDIR:-/tmp}/work-cli-pr-$$"
mkdir -p "$PR_FIXTURE/registry"
mkdir -p "$PR_FIXTURE/proj-a/.homebase"
mkdir -p "$PR_FIXTURE/proj-b/.homebase"
mkdir -p "$PR_FIXTURE/proj-b/sub/dir"

cat > "$PR_FIXTURE/registry/projects.paths" <<EOF
$PR_FIXTURE/proj-a
$PR_FIXTURE/proj-b
EOF

cat > "$PR_FIXTURE/proj-a/.homebase/project.yml" <<'EOF'
name: proja
display_name: Project A
kind: monorepo
domains: [web]
apps:
  - name: studio-web
    path: apps/studio-web
EOF

cat > "$PR_FIXTURE/proj-b/.homebase/project.yml" <<'EOF'
name: projb
display_name: Project B
kind: monorepo
domains: [web]
apps:
  - name: shopos
    path: ShopOS
  - name: gascalc
    path: iOS/Apps/GasCalc
EOF

# app_to_project_path
RES="$(HOMEBASE_ROOT="$PR_FIXTURE" bash -c "
. '$HOMEBASE/scripts/lib/project-resolver.sh'
app_to_project_path 'shopos'
" 2>&1)"
assert_eq "$RES" "$PR_FIXTURE/proj-b" "project-resolver: app_to_project_path resolves shopos → proj-b"

set +e
RES="$(HOMEBASE_ROOT="$PR_FIXTURE" bash -c "
. '$HOMEBASE/scripts/lib/project-resolver.sh'
app_to_project_path 'nonexistent'
" 2>&1)"
RC=$?
set -e
assert_eq "$RC" "1" "project-resolver: app_to_project_path returns 1 on no-match"
assert_eq "$RES" "" "project-resolver: app_to_project_path empty stdout on no-match"

# linear_project_name_to_project_path — case + whitespace insensitive
RES="$(HOMEBASE_ROOT="$PR_FIXTURE" bash -c "
. '$HOMEBASE/scripts/lib/project-resolver.sh'
linear_project_name_to_project_path 'ShopOS'
" 2>&1)"
assert_eq "$RES" "$PR_FIXTURE/proj-b" "project-resolver: linear name 'ShopOS' → proj-b"

RES="$(HOMEBASE_ROOT="$PR_FIXTURE" bash -c "
. '$HOMEBASE/scripts/lib/project-resolver.sh'
linear_project_name_to_project_path 'StudioWeb'
" 2>&1)"
assert_eq "$RES" "$PR_FIXTURE/proj-a" "project-resolver: linear name 'StudioWeb' → proj-a"

# cwd_in_project_path
RC="$(cd "$PR_FIXTURE/proj-b" && bash -c "
. '$HOMEBASE/scripts/lib/project-resolver.sh'
cwd_in_project_path '$PR_FIXTURE/proj-b' && echo 0 || echo 1
")"
assert_eq "$RC" "0" "project-resolver: cwd == project-path returns 0"

RC="$(cd "$PR_FIXTURE/proj-b/sub/dir" && bash -c "
. '$HOMEBASE/scripts/lib/project-resolver.sh'
cwd_in_project_path '$PR_FIXTURE/proj-b' && echo 0 || echo 1
")"
assert_eq "$RC" "0" "project-resolver: cwd descendant returns 0"

RC="$(cd "$PR_FIXTURE/proj-a" && bash -c "
. '$HOMEBASE/scripts/lib/project-resolver.sh'
cwd_in_project_path '$PR_FIXTURE/proj-b' && echo 0 || echo 1
")"
assert_eq "$RC" "1" "project-resolver: sibling cwd returns 1 (not in project)"

# Path-boundary safety: cwd "/foo-bar" must not match "/foo".
mkdir -p "$PR_FIXTURE/proj-b-twin"
RC="$(cd "$PR_FIXTURE/proj-b-twin" && bash -c "
. '$HOMEBASE/scripts/lib/project-resolver.sh'
cwd_in_project_path '$PR_FIXTURE/proj-b' && echo 0 || echo 1
")"
assert_eq "$RC" "1" "project-resolver: 'proj-b-twin' does NOT match 'proj-b' (path-boundary check)"

# ── HMB-111: start.sh app-ownership guard (cross-repo misroute prevention) ───
# start.sh must never carve a worktree for an app the cwd project doesn't own —
# the bug was a Briefing/TBL issue started from ~/code/homebase scaffolding a
# homebase worktree, even with `--app briefing` passed. Exercise the decision the
# guard makes (app_to_project_path + cwd_in_project_path — the same calls
# start.sh layers (a) and (c) make) against the fixture registry.
hmb111_guard() {  # <cwd> <app> -> REFUSE | PROCEED
  ( cd "$1" && HOMEBASE_ROOT="$PR_FIXTURE" bash -c "
    . '$HOMEBASE/scripts/lib/project-resolver.sh'
    owner=\"\$(app_to_project_path '$2' 2>/dev/null || true)\"
    if [[ -n \"\$owner\" ]] && ! cwd_in_project_path \"\$owner\"; then echo REFUSE; else echo PROCEED; fi
  " )
}
assert_eq "$(hmb111_guard "$PR_FIXTURE/proj-a" gascalc)" "REFUSE" \
  "HMB-111: --app gascalc from proj-a (owned by proj-b) → refuse, no cross-repo carve"
assert_eq "$(hmb111_guard "$PR_FIXTURE/proj-b" gascalc)" "PROCEED" \
  "HMB-111: --app gascalc from proj-b (its owner) → proceed"
assert_eq "$(hmb111_guard "$PR_FIXTURE/proj-a" studio-web)" "PROCEED" \
  "HMB-111: --app studio-web from proj-a (its owner) → proceed"
assert_eq "$(hmb111_guard "$PR_FIXTURE/proj-b/sub/dir" studio-web)" "REFUSE" \
  "HMB-111: --app studio-web from a proj-b descendant → refuse"
assert_eq "$(hmb111_guard "$PR_FIXTURE/proj-a" unregistered-app)" "PROCEED" \
  "HMB-111: unregistered app → guard no-ops (downstream gates apply), no false refuse"

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$PR_FIXTURE"; fi

# ── Test: homebase auth status (HMB-45 F11) ──────────────────────────────────
# Verifies the auth status verb runs, lists each known auth env var with
# its set/unset state, and emits the LINEAR_TPM_AUTHORIZED guidance only
# when the var is unset.

set +e
AUTH_OUT="$(env -i HOME=/tmp PATH="$PATH" PWD=/tmp "$HOMEBASE/scripts/auth/status.sh" 2>&1)"
AUTH_RC=$?
set -e
assert_eq "$AUTH_RC" "0" "auth-status: returns 0 on success"
assert_contains "$AUTH_OUT" "homebase auth status" "auth-status: prints header"
assert_contains "$AUTH_OUT" "LINEAR_TPM_AUTHORIZED" "auth-status: lists LINEAR_TPM_AUTHORIZED"
assert_contains "$AUTH_OUT" "HOMEBASE_WORK_AUTHORIZED" "auth-status: lists HOMEBASE_WORK_AUTHORIZED"
assert_contains "$AUTH_OUT" "HOMEBASE_OFF_CONTRACT" "auth-status: lists HOMEBASE_OFF_CONTRACT"
assert_contains "$AUTH_OUT" "LINEAR_MCP_PLUGIN" "auth-status: lists LINEAR_MCP_PLUGIN"
assert_contains "$AUTH_OUT" "= unset" "auth-status: marks unset vars"
assert_contains "$AUTH_OUT" "Mid-session" "auth-status: emits the launch-time-only guidance when LINEAR_TPM_AUTHORIZED is unset"

# When LINEAR_TPM_AUTHORIZED is set, the guidance block must not appear.
set +e
AUTH_OUT="$(env -i HOME=/tmp PATH="$PATH" PWD=/tmp LINEAR_TPM_AUTHORIZED=1 "$HOMEBASE/scripts/auth/status.sh" 2>&1)"
AUTH_RC=$?
set -e
assert_eq "$AUTH_RC" "0" "auth-status: returns 0 with LINEAR_TPM_AUTHORIZED=1"
assert_contains "$AUTH_OUT" "= set" "auth-status: marks set vars"
if [[ "$AUTH_OUT" == *"Mid-session"* ]]; then
  fail "auth-status: emitted guidance even when LINEAR_TPM_AUTHORIZED is set"
else
  pass "auth-status: silent guidance when LINEAR_TPM_AUTHORIZED is set"
fi

# ── Test: known-main-failures allowlist (HMB-45 F3) ──────────────────────────
# Validates the gate_validate_passes allowlist consultation logic via
# fixture: a stub required_check whose command emits a known marker
# string and exits 1, plus a known_main_failures.yml entry matching
# that marker. The gate must demote to a warning.
#
# Three scenarios: matching entry within expiry → demote;
# matching entry expired → hard fail with renewal message; no allowlist
# match → hard fail with the canonical "fix and retry" message.

KMF_FIXTURE="${TMPDIR:-/tmp}/work-cli-kmf-$$"
mkdir -p "$KMF_FIXTURE/.homebase"
git -C "$KMF_FIXTURE" init -q
git -C "$KMF_FIXTURE" config user.email test@example.com
git -C "$KMF_FIXTURE" config user.name "Test User"
echo seed > "$KMF_FIXTURE/seed"
git -C "$KMF_FIXTURE" add seed
git -C "$KMF_FIXTURE" commit -q -m "chore: seed"
KMF_BASE_SHA="$(git -C "$KMF_FIXTURE" rev-parse HEAD)"
git -C "$KMF_FIXTURE" branch -m main 2>/dev/null || git -C "$KMF_FIXTURE" checkout -q -b main
git -C "$KMF_FIXTURE" checkout -q -b feature/kmf
echo more > "$KMF_FIXTURE/feature.txt"
git -C "$KMF_FIXTURE" add feature.txt
git -C "$KMF_FIXTURE" commit -q -m "feat(stub): add feature

Refs WT-99"

cat > "$KMF_FIXTURE/.homebase/work-state.json" <<EOF
{"schema_version":1,"issue":"WT-99","branch":"feature/kmf","app":"stubapp","kind":"feature","finished":false,"checkpoints":[],"last_gate_passed":3,"base_sha":"$KMF_BASE_SHA"}
EOF

# Minimal workflow.yml with a required_check that always fails with a
# known marker string in its output.
cat > "$KMF_FIXTURE/.homebase/workflow.yml" <<'EOF'
version: 1
primary_tracker: linear
linear:
  state_kinds:
    backlog: ["Backlog"]
    in_progress: ["In Progress"]
    in_review: ["In Review"]
    done: ["Done"]
start_gates:
  ac_present: true
finish_gates:
  changelog_updated_for_feat_fix: false
  ui_verification_present: false
required_checks:
  - name: stub_failing_check
    command: 'printf "FAIL_MARKER_FOR_TEST: KnownFailingTest#test_baseline\n" >&2; exit 1'
    when: on_finish
    blocking: true
required_agents: {}
branch:
  base: main
  naming_pattern: "{scope}/{issue}-{slug}"
hard_rules:
  no_no_verify: true
session_end:
  block_on_uncommitted: true
EOF

# Minimal project.yml so read_effective_workflow_for_app can resolve.
cat > "$KMF_FIXTURE/.homebase/project.yml" <<'EOF'
name: kmftest
display_name: KMF Test
kind: single-app
domains: [web]
apps:
  - name: stubapp
    path: .
    platforms: [web]
    status: active
    summary: KMF test stub
EOF

# Case 1: matching allowlist entry, future expiry → demote to [warn]
FUTURE_DATE="$(date -v +30d +%Y-%m-%d 2>/dev/null || date -d '+30 days' +%Y-%m-%d)"
cat > "$KMF_FIXTURE/.homebase/known_main_failures.yml" <<EOF
failures:
  - check_name: stub_failing_check
    test_id: "FAIL_MARKER_FOR_TEST"
    tracking_issue: WT-99
    expires_at: ${FUTURE_DATE}
    reason: "Test stub for HMB-45 F3 allowlist coverage."
EOF

set +e
KMF_OUT="$(GATE_REPO_ROOT="$KMF_FIXTURE" bash -c "
. '$HOMEBASE/scripts/work/lib/state.sh'
. '$HOMEBASE/scripts/work/lib/gates.sh'
gate_validate_passes
" 2>&1)"
KMF_RC=$?
set -e
assert_eq "$KMF_RC" "0" "kmf-allowlist: matching entry within expiry → gate passes"
assert_contains "$KMF_OUT" "[warn] stub_failing_check" "kmf-allowlist: emits [warn] for demoted check"
assert_contains "$KMF_OUT" "FAIL_MARKER_FOR_TEST" "kmf-allowlist: warning names matched test_id"
assert_contains "$KMF_OUT" "WT-99" "kmf-allowlist: warning names tracking issue"

# Case 2: matching entry, expired → hard fail with renewal message
PAST_DATE="$(date -v -30d +%Y-%m-%d 2>/dev/null || date -d '-30 days' +%Y-%m-%d)"
cat > "$KMF_FIXTURE/.homebase/known_main_failures.yml" <<EOF
failures:
  - check_name: stub_failing_check
    test_id: "FAIL_MARKER_FOR_TEST"
    tracking_issue: WT-99
    expires_at: ${PAST_DATE}
    reason: "Expired entry — should fail."
EOF

set +e
KMF_OUT="$(GATE_REPO_ROOT="$KMF_FIXTURE" bash -c "
. '$HOMEBASE/scripts/work/lib/state.sh'
. '$HOMEBASE/scripts/work/lib/gates.sh'
gate_validate_passes
" 2>&1)"
KMF_RC=$?
set -e
assert_eq "$KMF_RC" "2" "kmf-allowlist: expired entry returns GATE_FAIL=2"
assert_contains "$KMF_OUT" "expired" "kmf-allowlist: failure message names expiry"
assert_contains "$KMF_OUT" "renew" "kmf-allowlist: failure message names renew option"

# Case 3: no allowlist → hard fail with canonical message
rm -f "$KMF_FIXTURE/.homebase/known_main_failures.yml"
set +e
KMF_OUT="$(GATE_REPO_ROOT="$KMF_FIXTURE" bash -c "
. '$HOMEBASE/scripts/work/lib/state.sh'
. '$HOMEBASE/scripts/work/lib/gates.sh'
gate_validate_passes
" 2>&1)"
KMF_RC=$?
set -e
assert_eq "$KMF_RC" "2" "kmf-allowlist: no allowlist → GATE_FAIL=2"
assert_contains "$KMF_OUT" "Fix the failure" "kmf-allowlist: canonical failure message preserved"
assert_contains "$KMF_OUT" "known_main_failures.yml" "kmf-allowlist: failure message documents the allowlist option"

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$KMF_FIXTURE"; fi

# ── Test: gate 11 transport fallback (HMB-54) ────────────────────────────────
# Three scenarios for gate_landed_to_main against synthetic repos:
#   A) real git, real bare origin → existing happy path, no fallback.
#   B) git transport broken, gh api ok → fallback succeeds with [warn] line
#      and a PATCH call recorded.
#   C) git transport broken, gh api also broken → terminal "dual-transport"
#      failure with GATE_FAIL=2.
#
# git and gh are intercepted via PATH-overridden shim scripts. The git shim
# fails only on transport-touching subcommands (fetch/push/pull origin) and
# delegates everything else to the real git binary captured at shim-write
# time. The gh shim writes argv to a log file the test inspects.

REAL_GIT_FOR_G11="$(command -v git)"

# Common fixture builder for B/C: local repo with feature/g11 branch and a
# fake github.com origin URL (so _gate_owner_repo resolves) plus a planted
# refs/remotes/origin/main (no network).
g11_setup_bc_repo() {
  local dir="$1"
  mkdir -p "$dir/.homebase"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name "Test User"
  echo seed > "$dir/seed"
  git -C "$dir" add seed
  git -C "$dir" commit -q -m "chore: seed"
  local base; base="$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" branch -m main 2>/dev/null || git -C "$dir" checkout -q -b main
  git -C "$dir" checkout -q -b feature/g11
  echo more > "$dir/feature.txt"
  git -C "$dir" add feature.txt
  git -C "$dir" commit -q -m "feat(stub): work
Refs HMB-54"
  git -C "$dir" remote add origin "git@github.com:Test/test.git"
  git -C "$dir" update-ref refs/remotes/origin/main "$base"
  cat > "$dir/.homebase/work-state.json" <<EOF
{"schema_version":1,"issue":"HMB-54","branch":"feature/g11","finished":false,"checkpoints":[],"last_gate_passed":10,"base_sha":"$base"}
EOF
}

# Writes a git shim at <bindir>/git that fails transport subcommands and
# delegates everything else to the real git binary.
g11_install_git_shim() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/git" <<EOF
#!/usr/bin/env bash
all="\$*"
case "\$all" in
  *"fetch origin main"*|*"push origin main"*|*"push origin HEAD:main"*|*"push origin --delete "*|*"pull --ff-only"*)
    echo "fatal: connect failed: Bad file descriptor (test shim)" >&2
    exit 128
    ;;
esac
exec "$REAL_GIT_FOR_G11" "\$@"
EOF
  chmod +x "$bindir/git"
}

# Writes a gh shim that records argv to <bindir>/../gh-calls.log and either
# (mode=ok) returns the planted SHA on GET / 0 on PATCH+DELETE, or (mode=bad)
# exits 1 on every call.
g11_install_gh_shim() {
  local bindir="$1" mode="$2" sha="$3"
  mkdir -p "$bindir"
  cat > "$bindir/gh" <<EOF
#!/usr/bin/env bash
log="$(dirname "$bindir")/gh-calls.log"
echo "argv: \$*" >> "\$log"
if [[ "$mode" == "bad" ]]; then
  echo "(test shim) gh api offline" >&2
  exit 1
fi
# mode=ok: rudimentary arg parser.
[[ "\$1" == "api" ]] || { echo "shim only handles 'api'" >&2; exit 2; }
shift
method="GET"; endpoint=""; sha_val=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -X) method="\$2"; shift 2;;
    -f) if [[ "\$2" == sha=* ]]; then sha_val="\${2#sha=}"; fi; shift 2;;
    -F) shift 2;;
    --jq) shift 2;;
    -*) shift;;
    *) endpoint="\$1"; shift;;
  esac
done
echo "method=\$method endpoint=\$endpoint sha=\$sha_val" >> "\$log"
case "\$method" in
  GET) echo "$sha"; exit 0;;
  PATCH|DELETE) exit 0;;
  *) echo "unhandled method \$method" >&2; exit 1;;
esac
EOF
  chmod +x "$bindir/gh"
}

# ── Case A — happy git path (real bare origin, no shims) ─────────────────────
GATE11_A="${TMPDIR:-/tmp}/work-cli-gate11a-$$"
mkdir -p "$GATE11_A/origin.git" "$GATE11_A/repo/.homebase"
git -C "$GATE11_A/origin.git" init -q --bare
git -C "$GATE11_A/repo" init -q
git -C "$GATE11_A/repo" config user.email test@example.com
git -C "$GATE11_A/repo" config user.name "Test User"
echo seed > "$GATE11_A/repo/seed"
git -C "$GATE11_A/repo" add seed
git -C "$GATE11_A/repo" commit -q -m "chore: seed"
git -C "$GATE11_A/repo" branch -m main 2>/dev/null || git -C "$GATE11_A/repo" checkout -q -b main
git -C "$GATE11_A/repo" remote add origin "file://$GATE11_A/origin.git"
git -C "$GATE11_A/repo" push -q origin main
A_BASE_SHA="$(git -C "$GATE11_A/repo" rev-parse HEAD)"
git -C "$GATE11_A/repo" checkout -q -b feature/g11
echo more > "$GATE11_A/repo/feature.txt"
git -C "$GATE11_A/repo" add feature.txt
git -C "$GATE11_A/repo" commit -q -m "feat(stub): work
Refs HMB-54"
cat > "$GATE11_A/repo/.homebase/work-state.json" <<EOF
{"schema_version":1,"issue":"HMB-54","branch":"feature/g11","finished":false,"checkpoints":[],"last_gate_passed":10,"base_sha":"$A_BASE_SHA"}
EOF

set +e
A_OUT="$(GATE_REPO_ROOT="$GATE11_A/repo" bash -c "
cd '$GATE11_A/repo'
. '$HOMEBASE/scripts/work/lib/state.sh'
. '$HOMEBASE/scripts/work/lib/gates.sh'
gate_landed_to_main
" 2>&1)"
A_RC=$?
set -e
assert_eq "$A_RC" "0" "g11-fallback: case A (real git) returns 0"
assert_contains "$A_OUT" "[ok]" "g11-fallback: case A emits [ok]"
if [[ "$A_OUT" == *"falling back to gh api"* ]]; then
  fail "g11-fallback: case A unexpectedly emitted fallback warning"
else
  pass "g11-fallback: case A did not emit fallback warning"
fi

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$GATE11_A"; fi

# ── Case B — git transport broken, gh api ok → fallback succeeds ─────────────
GATE11_B="${TMPDIR:-/tmp}/work-cli-gate11b-$$"
mkdir -p "$GATE11_B/bin"
g11_setup_bc_repo "$GATE11_B"
B_BASE_SHA="$(git -C "$GATE11_B" rev-parse refs/remotes/origin/main)"
g11_install_git_shim "$GATE11_B/bin"
g11_install_gh_shim  "$GATE11_B/bin" ok "$B_BASE_SHA"

set +e
B_OUT="$(GATE_REPO_ROOT="$GATE11_B" PATH="$GATE11_B/bin:$PATH" bash -c "
cd '$GATE11_B'
. '$HOMEBASE/scripts/work/lib/state.sh'
. '$HOMEBASE/scripts/work/lib/gates.sh'
gate_landed_to_main
" 2>&1)"
B_RC=$?
set -e
assert_eq "$B_RC" "0" "g11-fallback: case B (git broken, gh ok) returns 0"
assert_contains "$B_OUT" "[warn] gate 11: git transport failed, falling back to gh api" "g11-fallback: case B emits the warn line"
assert_contains "$B_OUT" "via gh api fallback" "g11-fallback: case B's [ok] line names the fallback path"
if [[ -f "$GATE11_B/gh-calls.log" ]] \
    && grep -q "method=PATCH endpoint=repos/Test/test/git/refs/heads/main sha=" "$GATE11_B/gh-calls.log"; then
  pass "g11-fallback: case B invoked gh api PATCH refs/heads/main"
else
  fail "g11-fallback: case B did not invoke the PATCH (log: $(cat "$GATE11_B/gh-calls.log" 2>/dev/null))"
fi

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$GATE11_B"; fi

# ── Case C — git broken AND gh broken → terminal dual-transport failure ──────
GATE11_C="${TMPDIR:-/tmp}/work-cli-gate11c-$$"
mkdir -p "$GATE11_C/bin"
g11_setup_bc_repo "$GATE11_C"
g11_install_git_shim "$GATE11_C/bin"
g11_install_gh_shim  "$GATE11_C/bin" bad "deadbeef"

set +e
C_OUT="$(GATE_REPO_ROOT="$GATE11_C" PATH="$GATE11_C/bin:$PATH" bash -c "
cd '$GATE11_C'
. '$HOMEBASE/scripts/work/lib/state.sh'
. '$HOMEBASE/scripts/work/lib/gates.sh'
gate_landed_to_main
" 2>&1)"
C_RC=$?
set -e
assert_eq "$C_RC" "2" "g11-fallback: case C (git+gh broken) returns GATE_FAIL=2"
assert_contains "$C_OUT" "[fail] landed-to-main" "g11-fallback: case C emits [fail]"
assert_contains "$C_OUT" "dual-transport failure" "g11-fallback: case C names dual-transport failure"

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$GATE11_C"; fi

# ── Test: gate 11 threads WORK_STATE into the push (HMB-129) ──────────────────
# A chore work-state (issue=null, no closing keyword on HEAD) only finishes if
# the pre-push hook can read kind=chore from $WORK_STATE — so gate_landed_to_main
# must pass WORK_STATE into the push env. The real hook isn't wired in synthetic
# fixtures, so we assert the env directly: a recording git shim logs $WORK_STATE
# on the FF push, and we verify the logged path resolves to kind=chore. Before
# the fix the push prefix omitted WORK_STATE and this logs an empty value.
GATE11_D="${TMPDIR:-/tmp}/work-cli-gate11d-$$"
mkdir -p "$GATE11_D/origin.git" "$GATE11_D/repo/.homebase" "$GATE11_D/bin"
git -C "$GATE11_D/origin.git" init -q --bare
git -C "$GATE11_D/repo" init -q
git -C "$GATE11_D/repo" config user.email test@example.com
git -C "$GATE11_D/repo" config user.name "Test User"
echo seed > "$GATE11_D/repo/seed"
git -C "$GATE11_D/repo" add seed
git -C "$GATE11_D/repo" commit -q -m "chore: seed"
git -C "$GATE11_D/repo" branch -m main 2>/dev/null || git -C "$GATE11_D/repo" checkout -q -b main
git -C "$GATE11_D/repo" remote add origin "file://$GATE11_D/origin.git"
git -C "$GATE11_D/repo" push -q origin main
D_BASE_SHA="$(git -C "$GATE11_D/repo" rev-parse HEAD)"
git -C "$GATE11_D/repo" checkout -q -b chore/g11d
echo more > "$GATE11_D/repo/chore.txt"
git -C "$GATE11_D/repo" add chore.txt
git -C "$GATE11_D/repo" commit -q -m "chore: stub work (no closing keyword)"
cat > "$GATE11_D/repo/.homebase/work-state.json" <<EOF
{"schema_version":1,"issue":null,"kind":"chore","branch":"chore/g11d","finished":false,"checkpoints":[],"last_gate_passed":10,"base_sha":"$D_BASE_SHA"}
EOF

# Recording git shim: delegate every subcommand to real git, but log \$WORK_STATE
# on the FF push so we can assert gate_landed_to_main supplied it.
cat > "$GATE11_D/bin/git" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"push origin HEAD:main"*) echo "WORK_STATE=\${WORK_STATE:-}" >> "$GATE11_D/push-env.log" ;;
esac
exec "$REAL_GIT_FOR_G11" "\$@"
EOF
chmod +x "$GATE11_D/bin/git"

set +e
D_OUT="$(GATE_REPO_ROOT="$GATE11_D/repo" PATH="$GATE11_D/bin:$PATH" bash -c "
cd '$GATE11_D/repo'
. '$HOMEBASE/scripts/work/lib/state.sh'
. '$HOMEBASE/scripts/work/lib/gates.sh'
gate_landed_to_main
" 2>&1)"
D_RC=$?
set -e
assert_eq "$D_RC" "0" "g11-chore-workstate: gate returns 0 (chore push succeeded)"
D_WS="$(grep -m1 '^WORK_STATE=' "$GATE11_D/push-env.log" 2>/dev/null | cut -d= -f2-)"
if [[ -n "$D_WS" && -f "$D_WS" ]] && [[ "$(jq -r '.kind // ""' "$D_WS" 2>/dev/null)" == "chore" ]]; then
  pass "g11-chore-workstate: FF push carried WORK_STATE resolving to kind=chore"
else
  fail "g11-chore-workstate: push WORK_STATE missing or not kind=chore (got '$D_WS'; log: $(cat "$GATE11_D/push-env.log" 2>/dev/null))"
fi

if [[ "$KEEP" -eq 0 ]]; then rm -rf "$GATE11_D"; fi

# ── Test: ship.sh — target parsing + tier gate + dry-run (HMB-69) ──────────────
#
# Builds a synthetic fixture project that declares a ship: stanza for an iOS
# app with both yellow- and red-tier targets (matching the GasCalc shape).
# All tests use --dry-run so fastlane is never invoked.

SHIP_FIXTURE="${TMPDIR:-/tmp}/work-cli-ship-$$"
mkdir -p "$SHIP_FIXTURE/.homebase" "$SHIP_FIXTURE/apps/calc"
(
  cd "$SHIP_FIXTURE"
  git init -q
  git config user.email test@example.com
  git config user.name "Test User"

  cat > .homebase/project.yml <<'YAML'
name: shipproj
display_name: Ship Test Project
description: Fixture for ship-verb tests
kind: monorepo
domains: [ios]
apps:
  - name: calc
    path: apps/calc
    platforms: [ios, macos]
    status: active
    summary: Test calculator app.
    ship:
      tool: fastlane
      fastlane_root: fastlane
      version_file:
        path: apps/calc/Calc.xcconfig
        language: xcconfig
        key: MARKETING_VERSION
      targets:
        testflight:
          fastlane_app: calc
          platform: ios
          track: testflight
          tier: yellow
        appstore:
          fastlane_app: calc
          platform: ios
          track: appstore
          tier: red
        mac-appstore:
          fastlane_app: calc-mac
          platform: ios
          track: appstore
          tier: red
          tag_platform: macos
  - name: calcpb
    path: apps/calcpb
    platforms: [ios]
    status: active
    summary: pbxproj version-file fixture (HMB-71).
    ship:
      tool: fastlane
      fastlane_root: fastlane
      version_file:
        path: apps/calcpb/Calc.xcodeproj/project.pbxproj
        language: pbxproj
        key: MARKETING_VERSION
      targets:
        testflight:
          fastlane_app: calcpb
          platform: ios
          track: testflight
          tier: yellow
YAML

  cat > apps/calc/CHANGELOG.md <<'MD'
# Calc Changelog

## [1.0.0] - 2026-05-15

### Added
- Initial release.
MD

  cat > apps/calc/Calc.xcconfig <<'CFG'
MARKETING_VERSION = 1.0.0
CURRENT_PROJECT_VERSION = 1
CFG

  # HMB-71: pbxproj version-file fixture. Xcode writes MARKETING_VERSION into
  # EVERY build configuration, so the file carries N identical lines.
  mkdir -p apps/calcpb/Calc.xcodeproj
  cat > apps/calcpb/Calc.xcodeproj/project.pbxproj <<'PBX'
// !$*UTF8*$!
{
	objects = {
		13A /* Debug */ = {
			buildSettings = {
				MARKETING_VERSION = 1.2.0;
			};
		};
		13B /* Release */ = {
			buildSettings = {
				MARKETING_VERSION = 1.2.0;
			};
		};
	};
}
PBX
  cat > apps/calcpb/CHANGELOG.md <<'MD'
# Calcpb Changelog

## [1.2.0] - 2026-05-22

### Added
- pbxproj fixture release.
MD

  echo ".homebase/work-state.json" > .gitignore
  echo ".homebase/work-state.json.lock" >> .gitignore
  echo ".homebase/work-state.*.json" >> .gitignore
  echo ".homebase/work-state.*.json.lock" >> .gitignore
  git add .
  git commit -q -m "Initial fixture"
  git checkout -q -b main 2>/dev/null || true
)

ship_run() {
  ( cd "$SHIP_FIXTURE" && bash "$HOMEBASE/scripts/work/ship.sh" "$@" )
}

# Case 1 — no TARGET on a ship-adopting app
set +e
S1_OUT="$(ship_run calc 1.0.0 2>&1)"
S1_RC=$?
set -e
assert_eq "$S1_RC" "2" "ship: no TARGET on ship-adopting app exits 2"
assert_contains "$S1_OUT" "no TARGET specified" "ship: no-TARGET error names the gap"
assert_contains "$S1_OUT" "testflight" "ship: no-TARGET error lists testflight"
assert_contains "$S1_OUT" "appstore" "ship: no-TARGET error lists appstore"
assert_contains "$S1_OUT" "mac-appstore" "ship: no-TARGET error lists mac-appstore"

# Case 2 — invalid TARGET
set +e
S2_OUT="$(ship_run calc 1.0.0 bogus 2>&1)"
S2_RC=$?
set -e
assert_eq "$S2_RC" "2" "ship: invalid TARGET exits 2"
assert_contains "$S2_OUT" "is not declared" "ship: invalid-TARGET error names rejection"
assert_contains "$S2_OUT" "testflight" "ship: invalid-TARGET error lists testflight"

# Case 3 — yellow-tier --dry-run succeeds
set +e
S3_OUT="$(ship_run calc 1.0.0 testflight --dry-run 2>&1)"
S3_RC=$?
set -e
assert_eq "$S3_RC" "0" "ship: yellow-tier --dry-run exits 0"
assert_contains "$S3_OUT" "yellow-tier" "ship: testflight named yellow-tier"
assert_contains "$S3_OUT" "dry-run: would run" "ship: --dry-run announces preview"
assert_contains "$S3_OUT" "bundle exec fastlane deploy app:calc platform:ios track:testflight" "ship: yellow dry-run prints full fastlane command (app + platform + track)"
# HMB-122: testflight is yellow-tier (non-production) → NO tag is cut.
assert_contains "$S3_OUT" "testflight is non-production" "ship: yellow-tier dry-run announces the tag is skipped (HMB-122)"
if echo "$S3_OUT" | grep -q "git tag -a calc/ios/1.0.0"; then
  fail "ship: yellow-tier dry-run must NOT cut a tag (HMB-122)"
else
  pass "ship: yellow-tier dry-run does not cut a tag (HMB-122)"
fi
# HMB-77: the dry-run preview delegates the milestone close to the TPM and no
# longer cites the retired `homebase roadmap project ship` verb.
assert_contains "$S3_OUT" "delegate Milestone v1.0.0" "ship: dry-run delegates milestone close to TPM (HMB-77)"
if echo "$S3_OUT" | grep -q "roadmap project ship"; then
  fail "ship: dry-run still cites retired 'roadmap project ship' verb (HMB-77)"
else
  pass "ship: dry-run no longer cites retired 'roadmap project ship' verb (HMB-77)"
fi

# Case 4 — red-tier --dry-run without HOMEBASE_SHIP_CONFIRMED (preview still works)
set +e
S4_OUT="$(ship_run calc 1.0.0 appstore --dry-run 2>&1)"
S4_RC=$?
set -e
assert_eq "$S4_RC" "0" "ship: red-tier --dry-run without confirm still exits 0"
assert_contains "$S4_OUT" "red-tier" "ship: appstore named red-tier"
assert_contains "$S4_OUT" "dry-run: would run" "ship: red --dry-run announces preview"

# Case 5 — red-tier real run without HOMEBASE_SHIP_CONFIRMED → refused
set +e
S5_OUT="$(ship_run calc 1.0.0 appstore 2>&1)"
S5_RC=$?
set -e
assert_eq "$S5_RC" "2" "ship: red-tier without HOMEBASE_SHIP_CONFIRMED exits 2"
assert_contains "$S5_OUT" "HOMEBASE_SHIP_CONFIRMED=1" "ship: red-tier refusal names the env var"
assert_contains "$S5_OUT" "production-grade stores" "ship: red-tier refusal explains why"

# Case 6 — red-tier with HOMEBASE_SHIP_CONFIRMED=1 + --dry-run
set +e
S6_OUT="$( cd "$SHIP_FIXTURE" && HOMEBASE_SHIP_CONFIRMED=1 bash "$HOMEBASE/scripts/work/ship.sh" calc 1.0.0 appstore --dry-run 2>&1 )"
S6_RC=$?
set -e
assert_eq "$S6_RC" "0" "ship: red-tier --dry-run with confirm exits 0"
assert_contains "$S6_OUT" "track:appstore" "ship: red dry-run prints appstore track"
# HMB-122: appstore is red-tier (production) → tag IS cut.
assert_contains "$S6_OUT" "git tag -a calc/ios/1.0.0" "ship: red-tier (appstore) dry-run DOES cut a tag (HMB-122)"
assert_contains "$S6_OUT" "production release" "ship: red-tier banner labels the tag a production release (HMB-122)"

# Case 7 — version-file mismatch fails pre-flight
set +e
S7_OUT="$(ship_run calc 2.0.0 testflight --dry-run 2>&1)"
S7_RC=$?
set -e
assert_eq "$S7_RC" "2" "ship: version-file mismatch fails pre-flight"
assert_contains "$S7_OUT" "MARKETING_VERSION" "ship: pre-flight names the version_file key"
assert_contains "$S7_OUT" "Bump the constant" "ship: pre-flight names the remediation"

# Case 8 — mac-appstore uses tag_platform override
set +e
S8_OUT="$( cd "$SHIP_FIXTURE" && HOMEBASE_SHIP_CONFIRMED=1 bash "$HOMEBASE/scripts/work/ship.sh" calc 1.0.0 mac-appstore --dry-run 2>&1 )"
S8_RC=$?
set -e
assert_eq "$S8_RC" "0" "ship: mac-appstore --dry-run with confirm exits 0"
assert_contains "$S8_OUT" "calc/macos/1.0.0" "ship: mac-appstore tag uses tag_platform=macos"
assert_contains "$S8_OUT" "app:calc-mac" "ship: mac-appstore uses the per-target fastlane_app"

# Case 9 — backward compat: app without a ship: stanza falls back to checklist.
# Reuses the original $FIXTURE myapp from the main setup at the top of this file —
# myapp has no ship: stanza, so this path still prints the SOP-005 checklist.
set +e
S9_OUT="$( cd "$FIXTURE" && bash "$HOMEBASE/scripts/work/ship.sh" myapp 1.0.0 2>&1 )"
set -e
assert_contains "$S9_OUT" "guided checklist (SOP-005)" "ship: app without ship: stanza prints SOP-005 checklist"

# Case 10 — HMB-78: the tag push self-authorizes for the pre-push hook.
# ship.sh's own tag push is intentional work, not off-contract chore territory;
# without HOMEBASE_WORK_AUTHORIZED=1 the pre-push hook on adopting projects
# (TFD/Studio) blocks it and the verb can't complete end-to-end. Asserted
# statically: the dry-run path never reaches the real push, and standing up a
# fake remote + fastlane to drive the live push is out of scope for this layer.
assert_contains "$(cat "$HOMEBASE/scripts/work/ship.sh")" 'HOMEBASE_WORK_AUTHORIZED=1 git -C "$ROOT" push origin "$tag"' "ship: tag push self-authorizes for pre-push hook (HMB-78)"

# Case 11 — HMB-71: pbxproj version_file. calcpb's pbxproj carries two matching
# MARKETING_VERSION = 1.2.0; lines (one per build config). A dry-run at the
# matching version passes the version-file pre-flight.
set +e
S11_OUT="$(ship_run calcpb 1.2.0 testflight --dry-run 2>&1)"
S11_RC=$?
set -e
assert_eq "$S11_RC" "0" "ship: pbxproj version_file matches → dry-run exits 0 (HMB-71)"
assert_contains "$S11_OUT" "MARKETING_VERSION in apps/calcpb/Calc.xcodeproj/project.pbxproj = 1.2.0" "ship: pbxproj reader returns the agreed MARKETING_VERSION"

# Case 12 — HMB-71: pbxproj with a wrong version → version-file mismatch.
set +e
S12_OUT="$(ship_run calcpb 9.9.9 testflight --dry-run 2>&1)"
S12_RC=$?
set -e
assert_eq "$S12_RC" "2" "ship: pbxproj version mismatch fails pre-flight (HMB-71)"

# Case 13 — HMB-71: pbxproj whose configs DISAGREE → divergence is an error,
# never silently papered over. Rewrite the fixture pbxproj with split values.
cat > "$SHIP_FIXTURE/apps/calcpb/Calc.xcodeproj/project.pbxproj" <<'PBX'
// !$*UTF8*$!
{
	objects = {
		13A /* Debug */ = {
			buildSettings = {
				MARKETING_VERSION = 1.2.0;
			};
		};
		13B /* Release */ = {
			buildSettings = {
				MARKETING_VERSION = 1.2.1;
			};
		};
	};
}
PBX
set +e
S13_OUT="$( cd "$SHIP_FIXTURE" && git add -A >/dev/null 2>&1; ship_run calcpb 1.2.0 testflight --dry-run 2>&1)"
S13_RC=$?
set -e
assert_eq "$S13_RC" "2" "ship: pbxproj divergent configs fail pre-flight (HMB-71)"
assert_contains "$S13_OUT" "diverges across pbxproj build configurations" "ship: pbxproj divergence names the split-version error (HMB-71)"

# ── HMB-121: ship.sh sources ~/.config/homebase/env before fastlane ──────────
# Case 13 left the fixture tree dirty (rewrote calcpb's pbxproj + staged it);
# restore a clean tree so these cases exercise the env logic, not Gate A.
# Env fixtures live OUTSIDE the repo so they don't themselves dirty the tree.
( cd "$SHIP_FIXTURE" && git reset -q --hard HEAD >/dev/null 2>&1 )
SHIP_ENV_OK="${TMPDIR:-/tmp}/ship-env-ok-$$"
SHIP_ENV_BAD="${TMPDIR:-/tmp}/ship-env-bad-$$"
printf 'export SHIP_TEST_SENTINEL=hmb121\n' > "$SHIP_ENV_OK"; chmod 600 "$SHIP_ENV_OK"
printf 'export SHIP_TEST_SENTINEL=hmb121\n' > "$SHIP_ENV_BAD"; chmod 644 "$SHIP_ENV_BAD"

# Case 14 — a present, mode-600 env file is detected + would be sourced.
# (Dry-run reports intent without sourcing secrets into a throwaway process.)
set +e
S14_OUT="$( cd "$SHIP_FIXTURE" && HOMEBASE_ENV_FILE="$SHIP_ENV_OK" bash "$HOMEBASE/scripts/work/ship.sh" calc 1.0.0 testflight --dry-run 2>&1 )"
S14_RC=$?
set -e
assert_eq "$S14_RC" "0" "ship: HMB-121 present env file → dry-run exits 0"
assert_contains "$S14_OUT" "would source $SHIP_ENV_OK" "ship: HMB-121 reports it would source a present, mode-600 env file"

# Case 15 — a missing env file is reported but does NOT block the ship.
set +e
S15_OUT="$( cd "$SHIP_FIXTURE" && HOMEBASE_ENV_FILE="${TMPDIR:-/tmp}/ship-env-absent-$$" bash "$HOMEBASE/scripts/work/ship.sh" calc 1.0.0 testflight --dry-run 2>&1 )"
S15_RC=$?
set -e
assert_eq "$S15_RC" "0" "ship: HMB-121 missing env file does not block (dry-run)"
assert_contains "$S15_OUT" "not found" "ship: HMB-121 names the missing env file"

# Case 16 — a group/world-readable env file is refused, not sourced.
set +e
S16_OUT="$( cd "$SHIP_FIXTURE" && HOMEBASE_ENV_FILE="$SHIP_ENV_BAD" bash "$HOMEBASE/scripts/work/ship.sh" calc 1.0.0 testflight --dry-run 2>&1 )"
set -e
assert_contains "$S16_OUT" "must be 600" "ship: HMB-121 refuses a non-600 env file with a clear message"

rm -f "$SHIP_ENV_OK" "$SHIP_ENV_BAD"
if [[ "$KEEP" -eq 0 ]]; then rm -rf "$SHIP_FIXTURE"; fi

# ── HMB-93: finish.sh defers worktree destruction when CLAUDECODE=1 ──────────
#
# In a live Claude Code session, finish.sh's worktree-teardown block must
# preserve the worktree — destroying it would invalidate the parent Claude
# process's CWD, breaking the statusline and every subsequent Bash spawn
# with `posix_spawn '/bin/sh'` ENOENT. The Stop hook
# (`session-end-cleanup.sh`) is responsible for actual removal at session
# end. Detection signal: CLAUDECODE=1 (exported by the Claude CLI in every
# Bash-tool subprocess).
#
# Direct end-to-end testing of `homebase work finish` requires every gate
# (1–14) to pass, including Linear transition, push, and trailer
# validation. Out of scope for this unit-test layer. Test the conditional
# branch directly: stand up a real git worktree, simulate the
# `in_worktree=true` path, and assert that with CLAUDECODE=1 the
# WORKTREE_RETAINED variable is set and the worktree dir survives; with
# CLAUDECODE unset the worktree is removed (matching legacy behaviour).
HMB93_FIX="$WT_FIXTURE"
HMB93_BR_CLAUDE="hmb-93-claude"
HMB93_WT_CLAUDE="$HMB93_FIX/.worktrees/wtproj/hmb-93-claude"
HMB93_BR_TERM="hmb-93-terminal"
HMB93_WT_TERM="$HMB93_FIX/.worktrees/wtproj/hmb-93-terminal"
git -C "$HMB93_FIX" worktree add "$HMB93_WT_CLAUDE" -b "$HMB93_BR_CLAUDE" main >/dev/null 2>&1
git -C "$HMB93_FIX" worktree add "$HMB93_WT_TERM" -b "$HMB93_BR_TERM" main >/dev/null 2>&1

# Canonicalise paths for assertion comparison: macOS resolves
# /var/folders/<…> through symlinks, so the path that worktree_destroy
# prints can differ from the literal $HMB93_WT_* string the test built.
HMB93_WT_CLAUDE_CANON="$(cd "$HMB93_WT_CLAUDE" && pwd -P)"
HMB93_WT_TERM_CANON="$(cd "$HMB93_WT_TERM" && pwd -P)"

# Case A — CLAUDECODE=1: worktree must be retained. cd into the worktree
# so the snippet runs from inside it (matches finish.sh's runtime context).
H93_CLAUDE_OUT="$(CLAUDECODE=1 bash -c "
cd '$HMB93_WT_CLAUDE'
. '$HOMEBASE/scripts/work/lib/worktree.sh'
WT=\"\$(pwd -P)\"
ISSUE='HMB-93'
WORKTREE_REMOVED=''
WORKTREE_RETAINED=''
if [[ \"\${CLAUDECODE:-}\" == '1' ]]; then
  WORKTREE_RETAINED=\"\$WT\"
elif worktree_destroy \"\$WT\" \"\$ISSUE\" >/dev/null 2>&1; then
  WORKTREE_REMOVED=\"\$WT\"
fi
echo \"retained=\$WORKTREE_RETAINED\"
echo \"removed=\$WORKTREE_REMOVED\"
" 2>&1)"
assert_contains "$H93_CLAUDE_OUT" "retained=$HMB93_WT_CLAUDE_CANON" "HMB-93: CLAUDECODE=1 sets WORKTREE_RETAINED"
assert_contains "$H93_CLAUDE_OUT" "removed=" "HMB-93: CLAUDECODE=1 does NOT set WORKTREE_REMOVED"
[[ -d "$HMB93_WT_CLAUDE" ]] && \
  pass "HMB-93: CLAUDECODE=1 — worktree dir survives" || \
  fail "HMB-93: CLAUDECODE=1 — worktree dir was destroyed (should have been retained)"

# Case B — CLAUDECODE unset: worktree must be removed (legacy behaviour).
H93_TERM_OUT="$(unset CLAUDECODE; bash -c "
cd '$HMB93_WT_TERM'
. '$HOMEBASE/scripts/work/lib/worktree.sh'
WT=\"\$(pwd -P)\"
ISSUE='HMB-93'
WORKTREE_REMOVED=''
WORKTREE_RETAINED=''
if [[ \"\${CLAUDECODE:-}\" == '1' ]]; then
  WORKTREE_RETAINED=\"\$WT\"
elif worktree_destroy \"\$WT\" \"\$ISSUE\" >/dev/null 2>&1; then
  WORKTREE_REMOVED=\"\$WT\"
fi
echo \"retained=\$WORKTREE_RETAINED\"
echo \"removed=\$WORKTREE_REMOVED\"
" 2>&1)"
assert_contains "$H93_TERM_OUT" "removed=$HMB93_WT_TERM_CANON" "HMB-93: CLAUDECODE unset removes worktree (legacy behaviour preserved)"
[[ ! -d "$HMB93_WT_TERM" ]] && \
  pass "HMB-93: CLAUDECODE unset — worktree dir destroyed (legacy behaviour preserved)" || \
  fail "HMB-93: CLAUDECODE unset — worktree dir still present (legacy behaviour broken)"

# Cleanup: the retained worktree from Case A is still on disk.
HOMEBASE_WORK_AUTHORIZED=1 git -C "$HMB93_FIX" worktree remove --force "$HMB93_WT_CLAUDE" 2>/dev/null || true
HOMEBASE_WORK_AUTHORIZED=1 git -C "$HMB93_FIX" branch -D "$HMB93_BR_CLAUDE" 2>/dev/null || true
HOMEBASE_WORK_AUTHORIZED=1 git -C "$HMB93_FIX" branch -D "$HMB93_BR_TERM" 2>/dev/null || true

# ── HMB-95: in_linked_worktree discriminates ALL linked worktrees ─────────────
#
# gate_landed_to_main keys its cleanup-path choice off in_linked_worktree (not
# in_worktree), so an in-place `--no-branch` start inside a Claude Code
# `.claude/worktrees/<id>` checkout skips the legacy `git switch main` — which
# can't run while main is checked out by the project root — and finish reaches
# gate 13 (Linear transition) instead of aborting with the issue stranded In
# Progress. Verify the discriminator across the three checkout shapes, and that
# in_worktree() stays narrow (finish.sh teardown must never destroy a Claude
# session worktree).
HMB95_HB_WT="$WT_FIXTURE/.worktrees/wtproj/hmb95-hb"
HMB95_CL_WT="$WT_FIXTURE/.claude/worktrees/hmb95-cl"
git -C "$WT_FIXTURE" worktree add "$HMB95_HB_WT" -b hmb95-hb main >/dev/null 2>&1
mkdir -p "$WT_FIXTURE/.claude/worktrees"
git -C "$WT_FIXTURE" worktree add "$HMB95_CL_WT" -b hmb95-cl main >/dev/null 2>&1

hmb95_probe() {  # <dir> -> "in_worktree=<Y/N> in_linked=<Y/N>"
  bash -c "
cd '$1'
. '$HOMEBASE/scripts/work/lib/worktree.sh'
if in_worktree; then iw=Y; else iw=N; fi
if in_linked_worktree; then il=Y; else il=N; fi
echo \"in_worktree=\$iw in_linked=\$il\"
" 2>&1
}

assert_eq "$(hmb95_probe "$HMB95_HB_WT")" "in_worktree=Y in_linked=Y" \
  "HMB-95: homebase .worktrees/ checkout is both in_worktree and in_linked_worktree"
assert_eq "$(hmb95_probe "$HMB95_CL_WT")" "in_worktree=N in_linked=Y" \
  "HMB-95: Claude .claude/worktrees/ checkout is in_linked_worktree but NOT in_worktree (no-switch path; not torn down)"
assert_eq "$(hmb95_probe "$WT_FIXTURE")" "in_worktree=N in_linked=N" \
  "HMB-95: main checkout is neither (legacy switch-main path unchanged)"

HOMEBASE_WORK_AUTHORIZED=1 git -C "$WT_FIXTURE" worktree remove --force "$HMB95_HB_WT" 2>/dev/null || true
HOMEBASE_WORK_AUTHORIZED=1 git -C "$WT_FIXTURE" worktree remove --force "$HMB95_CL_WT" 2>/dev/null || true
HOMEBASE_WORK_AUTHORIZED=1 git -C "$WT_FIXTURE" branch -D hmb95-hb 2>/dev/null || true
HOMEBASE_WORK_AUTHORIZED=1 git -C "$WT_FIXTURE" branch -D hmb95-cl 2>/dev/null || true

# ── HMB-103: chore-with-issue still transitions Linear (should_skip_gate) ─────
#
# The pure decision lives in gates.sh. An issue-bearing chore must RUN the
# Linear gates (8 in-progress, 13 transitioned); an issue-less chore skips them.
# Decisions are computed in a subshell that sources gates.sh; results stream
# back as PASS:/FAIL: lines consumed in the MAIN shell (here-string, not a
# pipe — so the pass/fail counters actually increment).
SKIP_OUT="$(
  . "$HOMEBASE/scripts/work/lib/gates.sh"
  emit() { if "$@"; then echo "Y"; else echo "N"; fi; }
  echo "chore_issue_g13=$(emit should_skip_gate chore gate13_linear TBL-1)"
  echo "chore_issue_g8=$(emit should_skip_gate chore gate8_linear TBL-1)"
  echo "chore_noissue_g13=$(emit should_skip_gate chore gate13_linear '')"
  echo "chore_noissue_g8=$(emit should_skip_gate chore gate8_linear '')"
  echo "chore_g6=$(emit should_skip_gate chore gate6_closing TBL-1)"
  echo "feature_g13=$(emit should_skip_gate feature gate13_linear TBL-1)"
  echo "hotfix_g13=$(emit should_skip_gate hotfix gate13_linear TBL-1)"
)"
# Y = should_skip returned 0 (skip); N = returned 1 (run).
chk() { local key="$1" want="$2" msg="$3"; local got; got="$(printf '%s\n' "$SKIP_OUT" | sed -n "s/^$key=//p")"; assert_eq "$got" "$want" "$msg"; }
chk chore_issue_g13   N "HMB-103: chore+issue RUNS gate13_linear (the fix — transitions to Done)"
chk chore_issue_g8    N "HMB-103: chore+issue RUNS gate8_linear"
chk chore_noissue_g13 Y "HMB-103: issue-less chore SKIPS gate13_linear (HMB-86 preserved)"
chk chore_noissue_g8  Y "HMB-103: issue-less chore SKIPS gate8_linear"
chk chore_g6          Y "HMB-103: chore always skips gate6_closing"
chk feature_g13       N "HMB-103: feature never skips gate13_linear"
chk hotfix_g13        Y "HMB-103: hotfix skips gate13_linear (P0 fast path)"

# ── HMB-103: `work rescue` detects stuck states (report mode, hermetic) ───────
RESCUE_FIX="$(mktemp -d)"
mkdir -p "$RESCUE_FIX/proj/.homebase"
cat > "$RESCUE_FIX/proj/.homebase/work-state.stuck.json" <<'JSON'
{ "schema_version": 1, "issue": "ZZ-777", "kind": "chore", "finished": true,
  "finish_outcome": "done", "linear_state_now": "In Progress",
  "finished_at": "2026-05-19T12:00:00Z" }
JSON
cat > "$RESCUE_FIX/proj/.homebase/work-state.clean.json" <<'JSON'
{ "schema_version": 1, "issue": "ZZ-888", "kind": "feature", "finished": true,
  "finish_outcome": "done", "linear_state_now": "Done",
  "finished_at": "2026-05-19T12:00:00Z" }
JSON
echo "$RESCUE_FIX/proj" > "$RESCUE_FIX/paths"
RESCUE_OUT="$(HOMEBASE_PROJECTS_PATHS="$RESCUE_FIX/paths" bash "$HOMEBASE/scripts/work/rescue.sh" 2>&1 || true)"
assert_contains "$RESCUE_OUT" "ZZ-777" "HMB-103: rescue report lists the stuck issue"
if echo "$RESCUE_OUT" | grep -q "ZZ-888"; then
  fail "HMB-103: rescue report wrongly listed a clean (Done) issue"
else
  pass "HMB-103: rescue report excludes the clean (Done) issue"
fi
assert_contains "$RESCUE_OUT" "report only" "HMB-103: rescue defaults to report mode (no --apply)"
rm -rf "$RESCUE_FIX"

# ── HMB-84: gate-ID uniqueness in finish.sh ───────────────────────────────────
#
# Two run_gate calls sharing an integer ID is the bug class behind HMB-84: the
# ID is the "already passed in a prior run" dedup key, so a collision lets one
# gate inherit the other's skip. The original defect had both `ui-verified`
# and `landed-to-main` claiming gate 11, which skipped the push on retry and
# transitioned Linear → Done with unpushed code (hard rule 8 violation).
# This static check fails the moment any run_gate ID maps to two gate names —
# the same invariant the runtime guard in finish.sh enforces, here caught in
# CI regardless of which gate paths execute at runtime.
GATE_ID_DUPES="$(grep -oE 'run_gate [0-9]+ "[^"]+"' "$HOMEBASE/scripts/work/finish.sh" \
  | sed -E 's/run_gate ([0-9]+) "([^"]+)"/\1 \2/' \
  | awk '{ if (($1 in seen) && (seen[$1] != $2)) print $1": "seen[$1]" vs "$2; seen[$1]=$2 }')"
assert_eq "$GATE_ID_DUPES" "" "HMB-84: every run_gate ID in finish.sh maps to exactly one gate"

# HMB-84: landed-to-main must NOT be memoized — it is the hard-rule-8 integrity
# boundary and must re-verify the commit is on origin/main on every attempt.
# Assert it is invoked directly (idempotent gate), not skippable via run_gate's
# already-passed shortcut.
if grep -qE 'run_gate +[0-9]+ +"landed-to-main"' "$HOMEBASE/scripts/work/finish.sh"; then
  fail "HMB-84: landed-to-main is memoized via run_gate (must run unconditionally every attempt)"
else
  pass "HMB-84: landed-to-main runs unmemoized (re-verifies origin/main every attempt)"
fi

# ── HMB-73: finish summary prints the captured issue key, not a stale re-read ──
#
# By the time the "done. outcome=… issue=…" summary prints, gate 14 has
# finalised the work-state and teardown may have removed the worktree, so a
# fresh `state_issue` read returns "?" (seen on the HMB-69 and TFD-1445
# finishes). The summary must print the $ISSUE captured at the top of the run.
SUMMARY_LINE="$(grep -E 'echo "done\. outcome=' "$HOMEBASE/scripts/work/finish.sh")"
assert_contains "$SUMMARY_LINE" 'issue=${ISSUE' "HMB-73: finish summary prints the captured \$ISSUE key"
if echo "$SUMMARY_LINE" | grep -q 'state_issue'; then
  fail "HMB-73: finish summary still re-reads state_issue (returns '?' after teardown)"
else
  pass "HMB-73: finish summary does not re-read state_issue after teardown"
fi

# ── HMB-118: finish.sh is bash-3.2 clean (no associative arrays) ──────────────
#
# macOS system bash is 3.2 (what `#!/usr/bin/env bash` resolves to) and has no
# associative arrays; `declare -A` errors to stderr on every finish. HMB-84's
# gate-ID guard introduced one — now a plain indexed array (gate IDs are
# integers). Guard against re-introduction: the rest of scripts/ avoids
# associative arrays for exactly this reason.
# Anchored at line-start (after indentation) so a `declare -A` mentioned in a
# comment doesn't false-positive — only a real declaration statement matches.
if grep -qE '^[[:space:]]*(declare|local)[[:space:]]+-A' "$HOMEBASE/scripts/work/finish.sh"; then
  fail "HMB-118: finish.sh uses an associative array (declare/local -A) — breaks on bash 3.2"
else
  pass "HMB-118: finish.sh is bash-3.2 clean (no declare -A)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo "── results: $PASS pass, $FAIL fail"
if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
exit 0
