#!/usr/bin/env bash
# scripts/hooks/_test_ui_pattern.sh — tests for scripts/lib/ui-pattern.sh
# and the warn-only SOP-007 path that commit-sop-check.sh adds (HMB-59).
#
# Two layers:
#   1. Lib-level unit tests (no git): exercise the regex constants and
#      helper functions directly against synthetic file lists / messages.
#   2. Integration tests: build a synthetic repo in /tmp, stage files,
#      pipe a commit message into commit-sop-check.sh, and check both
#      the exit code (must remain 0) and stderr (warning present/absent).
#
# Usage:  bash scripts/hooks/_test_ui_pattern.sh [--keep]
#
# Exit codes:
#   0  all tests passed
#   1  at least one test failed

set -uo pipefail

HOMEBASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
LIB="$HOMEBASE/scripts/lib/ui-pattern.sh"
HOOK="$HOMEBASE/scripts/hooks/commit-sop-check.sh"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

FIXTURE="${TMPDIR:-/tmp}/ui-pattern-test-$$"
trap 'rc=$?; if [[ "$KEEP" -eq 0 ]]; then rm -rf "$FIXTURE"; fi; exit $rc' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ok: $*"; PASS=$((PASS + 1)); }

# ── Layer 1: lib-level unit tests ─────────────────────────────────────────
# Source the lib in this shell, then exercise its functions against
# in-memory fixtures (no git, no /tmp repo needed for these).

# shellcheck source=../lib/ui-pattern.sh
. "$LIB"

# UI_PATTERN_RE positives — each of these SHOULD match.
positives=(
  "app/views/users/show.html.erb"
  "apps/studio-web/views/dashboard.html.erb"
  "apps/studio-web/templates/index.gohtml"
  "apps/acme-co/web/templates/home.html.tmpl"
  "ShopOS/app/views/customers/_medical_update_diff.html.erb"
  "iOS/Apps/GasCalc/Views/PlanningView.swift"
  "iOS/Apps/GasCalc/Screens/HomeScreen.swift"
  "iOS/Apps/LogApp/Components/DiveCell.swift"
  "src/components/Header.tsx"
  "frontend/pages/index.vue"
  "docs/_layouts/post.html"
  "app/assets/stylesheets/application.scss"
  "app/javascript/controllers/medical_explanation_toggle_controller.js"
  "anywhere/SomeView.swift"
  "anywhere/HeroLayout.tsx"
  "path/with/ui/SomeScreen.kt"
  "iOS/Apps/GasCalc/gascalc/ui/gasproperties/GasPropertiesScreen.kt"
  "android/feature/screens/LoginScreen.kt"
  "apps/web/views/home/index.tsx"
)
for path in "${positives[@]}"; do
  if printf '%s\n' "$path" | grep -Eq "$UI_PATTERN_RE"; then
    pass "UI_PATTERN_RE matches '$path'"
  else
    fail "UI_PATTERN_RE should match '$path' but does not"
  fi
done

# UI_PATTERN_RE negatives — each of these SHOULD NOT match.
negatives=(
  "app/models/customer.rb"
  "app/services/medical/validate_self_update.rb"
  "app/controllers/sessions_controller.rb"
  "iOS/Apps/GasCalc/DaltonApp.swift"
  "iOS/Apps/GasCalc/Repositories/DiveRepository.swift"
  "iOS/Apps/LogApp/Services/SyncService.swift"
  "config/routes.rb"
  "db/migrate/20260512_create_medical_self_update_events.rb"
  "test/models/customer_test.rb"
  "scripts/hooks/commit-sop-check.sh"
  "governance/WORKFLOW_QUICKREF.md"
  "README.md"
  "src/lib/util.ts"
  "templates/project.yml.tmpl"
  "templates/workflow.yml.tmpl"
)
for path in "${negatives[@]}"; do
  if printf '%s\n' "$path" | grep -Eq "$UI_PATTERN_RE"; then
    fail "UI_PATTERN_RE should NOT match '$path' but does"
  else
    pass "UI_PATTERN_RE skips '$path'"
  fi
done

# UI_EXCLUDE_PATTERN_RE — universal exclusions.
excluded=(
  "spec/fixtures/sample.html"
  "test/fixtures/page.html"
  "vendor/jquery.js"
  "node_modules/react/index.js"
)
for path in "${excluded[@]}"; do
  if printf '%s\n' "$path" | grep -Eq "$UI_EXCLUDE_PATTERN_RE"; then
    pass "UI_EXCLUDE_PATTERN_RE catches '$path'"
  else
    fail "UI_EXCLUDE_PATTERN_RE should catch '$path' but does not"
  fi
done

# homebase_ui_msg_has_trailer — trailer detection.
trailer_yes=(
  "feat(x): subject

body

Verified in browser: rendered the page; everything looks right.

Refs HMB-1"
  "feat: subject

Verified by XCUITest: PlanningViewTests.testDecoBoundary — iOS sim.

Refs HMB-1"
  "subject

verified IN BROWSER: case insensitive match.

Refs HMB-1"
  "subject

UI verification skipped: this is a hotfix to a service file (no rendered surface).

Refs HMB-1"
)
for msg in "${trailer_yes[@]}"; do
  if homebase_ui_msg_has_trailer "$msg"; then
    short=$(printf '%s' "$msg" | grep -Ei '^(verified|ui verification)' | head -1)
    pass "homebase_ui_msg_has_trailer detects '$short'"
  else
    fail "homebase_ui_msg_has_trailer should detect a trailer in: $msg"
  fi
done

trailer_no=(
  "feat(x): subject

body without trailer.

Refs HMB-1"
  "subject

verified manually by me  (missing 'in browser' suffix)

Refs HMB-1"
  "subject

  Verified in browser: indented trailer should NOT match (line-anchored)

Refs HMB-1"
)
for msg in "${trailer_no[@]}"; do
  if homebase_ui_msg_has_trailer "$msg"; then
    fail "homebase_ui_msg_has_trailer should NOT detect a trailer in: $msg"
  else
    pass "homebase_ui_msg_has_trailer correctly rejects malformed msg"
  fi
done

# ── Layer 2: integration tests against commit-sop-check.sh ────────────────
# Build a tiny repo, stage UI / non-UI files, pipe a commit message into
# the hook, and assert exit code + stderr behaviour.

mkdir -p "$FIXTURE/app/views/users" "$FIXTURE/app/models"
cd "$FIXTURE"
git init -q -b main >/dev/null 2>&1
git config user.email "test@test"; git config user.name "Test"
printf 'placeholder\n' > app/views/users/show.html.erb
printf 'placeholder\n' > app/models/user.rb
git add -A; git commit -q -m "seed" --no-verify >/dev/null

# Helper: stage <file>, then run hook with <msg> piped on stdin.
# Captures both exit code and stderr.
run_hook() {
  local staged_files="$1"
  local msg="$2"
  # Reset stage
  git reset -q
  # shellcheck disable=SC2086
  git add $staged_files

  local stderr_file="$FIXTURE/.stderr"
  local rc=0
  printf '%s\n' "$msg" | "$HOOK" 2>"$stderr_file" >/dev/null || rc=$?
  STDERR_CAPTURE="$(cat "$stderr_file")"
  return "$rc"
}

# Make a small change to each staged file every run so `git diff --cached
# --name-only` actually reports it (otherwise re-staging an unchanged file
# is a no-op).
touch_change() {
  local path="$1"
  printf 'touched %s\n' "$(date +%s%N)" >> "$path"
}

# --- T1: UI commit, no trailer → exit 0, stderr CONTAINS warning ---
touch_change "app/views/users/show.html.erb"
run_hook "app/views/users/show.html.erb" "feat(x): tweak the show view

Refs HMB-99"
rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$STDERR_CAPTURE" == *"HOMEBASE-SOP-007 WARNING"* ]]; then
  pass "T1: UI commit without trailer → exit 0 + warning printed"
else
  fail "T1: expected exit 0 + SOP-007 warning, got rc=$rc; stderr=$STDERR_CAPTURE"
fi

# --- T2: UI commit, WITH trailer → exit 0, no warning ---
touch_change "app/views/users/show.html.erb"
run_hook "app/views/users/show.html.erb" "feat(x): tweak the show view

Verified in browser: rendered /users/<id>; the new copy reads correctly.

Refs HMB-99"
rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$STDERR_CAPTURE" != *"HOMEBASE-SOP-007 WARNING"* ]]; then
  pass "T2: UI commit with trailer → exit 0 + no warning"
else
  fail "T2: expected exit 0 + no warning, got rc=$rc; stderr=$STDERR_CAPTURE"
fi

# --- T3: non-UI commit, no trailer → exit 0, no warning ---
touch_change "app/models/user.rb"
run_hook "app/models/user.rb" "feat(x): rename a method

Refs HMB-99"
rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$STDERR_CAPTURE" != *"HOMEBASE-SOP-007 WARNING"* ]]; then
  pass "T3: non-UI commit without trailer → exit 0 + no warning"
else
  fail "T3: expected exit 0 + no warning, got rc=$rc; stderr=$STDERR_CAPTURE"
fi

# --- T4: chore commit touching UI → exempt from issue check; no warning ---
# (chore: subject exits early before the UI warn block runs; verify that
# remains the case so we don't accidentally warn on legitimate
# chore-prefixed UI tweaks like dependency bumps.)
touch_change "app/views/users/show.html.erb"
run_hook "app/views/users/show.html.erb" "chore: bump dependency that changes generated view"
rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$STDERR_CAPTURE" != *"HOMEBASE-SOP-007 WARNING"* ]]; then
  pass "T4: chore-prefixed UI commit → exit 0 + no SOP-007 warning"
else
  fail "T4: chore exemption broken; got rc=$rc; stderr=$STDERR_CAPTURE"
fi

# --- T5: HOMEBASE_UI_VERIFICATION=off suppresses warning ---
touch_change "app/views/users/show.html.erb"
HOMEBASE_UI_VERIFICATION=off run_hook "app/views/users/show.html.erb" "feat(x): another view tweak

Refs HMB-99"
rc=$?
if [[ "$rc" -eq 0 ]] && [[ "$STDERR_CAPTURE" != *"HOMEBASE-SOP-007 WARNING"* ]]; then
  pass "T5: HOMEBASE_UI_VERIFICATION=off suppresses warning"
else
  fail "T5: env-var escape hatch broken; got rc=$rc; stderr=$STDERR_CAPTURE"
fi

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "ui-pattern tests: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
