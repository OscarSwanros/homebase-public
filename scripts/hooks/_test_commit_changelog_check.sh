#!/usr/bin/env bash
# scripts/hooks/_test_commit_changelog_check.sh — fixture tests for
# commit-changelog-check.sh. Exercises both enforcement paths
# (Conventional Commits + Linear-key) against a synthetic /tmp git
# repo.
#
# Usage: bash scripts/hooks/_test_commit_changelog_check.sh [--keep]
#
# Exit codes:
#   0  all tests passed
#   1  test failure

set -uo pipefail

HOMEBASE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
HOOK="$HOMEBASE/scripts/hooks/commit-changelog-check.sh"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

FIXTURE="${TMPDIR:-/tmp}/changelog-check-test-$$"
trap 'rc=$?; if [[ "$KEEP" -eq 0 ]]; then rm -rf "$FIXTURE"; fi; exit $rc' EXIT INT TERM

PASS=0
FAIL=0
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ok: $*"; PASS=$((PASS + 1)); }

# Build a synthetic repo with apps/studio-web/CHANGELOG.md.
mkdir -p "$FIXTURE/apps/studio-web" "$FIXTURE/apps/gascalc" "$FIXTURE/scripts"
cd "$FIXTURE"
git init -q -b main >/dev/null 2>&1
git config user.email "test@test"; git config user.name "Test"
printf '# StudioWeb\n\n## [Unreleased]\n' > apps/studio-web/CHANGELOG.md
printf '# GasCalc\n\n## [Unreleased]\n' > apps/gascalc/CHANGELOG.md
printf 'placeholder' > apps/studio-web/foo.rb
printf 'placeholder' > apps/gascalc/bar.swift
printf 'placeholder' > scripts/baz.sh
git add -A; git commit -q -m "seed" >/dev/null

# Run hook with subject + (optional) body, return its exit code.
# Caller is responsible for staging files before invocation.
run_hook() {
  local subject="$1"
  local body="${2:-}"
  local msg
  if [[ -n "$body" ]]; then
    msg=$(printf '%s\n\n%s\n' "$subject" "$body")
  else
    msg=$(printf '%s\n' "$subject")
  fi
  printf '%s' "$msg" | bash "$HOOK"
}

reset() {
  git restore --staged . >/dev/null 2>&1 || true
}

# ── Path 1 — Conventional Commits ──────────────────────────────────────

echo "Path 1 — Conventional Commits"

# Touch foo.rb without staging the CHANGELOG.
echo "edit-1" >> apps/studio-web/foo.rb; git add apps/studio-web/foo.rb
if run_hook "feat(studio-web): add a thing"; then
  fail "feat(studio-web) without CHANGELOG should reject"
else
  pass "feat(studio-web) without CHANGELOG rejects"
fi

# Stage the CHANGELOG too.
echo "- new bullet" >> apps/studio-web/CHANGELOG.md; git add apps/studio-web/CHANGELOG.md
if run_hook "feat(studio-web): add a thing"; then
  pass "feat(studio-web) with CHANGELOG passes"
else
  fail "feat(studio-web) with CHANGELOG should pass"
fi

reset; git restore apps/studio-web/foo.rb apps/studio-web/CHANGELOG.md

# Scope that doesn't map to apps/<scope>/ — exempt.
echo "edit-2" >> scripts/baz.sh; git add scripts/baz.sh
if run_hook "feat(cli): tweak"; then
  pass "feat(cli) on non-app scope is exempt"
else
  fail "feat(cli) on non-app scope should be exempt"
fi
reset; git restore scripts/baz.sh

# ── Path 2 — Linear-key subject (HMB-24) ───────────────────────────────

echo "Path 2 — Linear-key subjects"

# Single-app commit on studio-web without CHANGELOG.
echo "edit-3" >> apps/studio-web/foo.rb; git add apps/studio-web/foo.rb
if run_hook "TBL-26: tweak studio-web"; then
  fail "TBL-26 single-app without CHANGELOG should reject"
else
  pass "TBL-26 single-app without CHANGELOG rejects"
fi

# Same staged state, with skip trailer.
if run_hook "TBL-26: tweak studio-web" "$(printf 'Body explanation.\n\nChangelog skipped: pure refactor, no observable change.\n')"; then
  pass "TBL-26 with 'Changelog skipped:' trailer passes"
else
  fail "TBL-26 with 'Changelog skipped:' trailer should pass"
fi

# Same staged state, with CHANGELOG also staged.
echo "- entry" >> apps/studio-web/CHANGELOG.md; git add apps/studio-web/CHANGELOG.md
if run_hook "TBL-26: tweak studio-web"; then
  pass "TBL-26 with CHANGELOG staged passes"
else
  fail "TBL-26 with CHANGELOG staged should pass"
fi
reset; git restore apps/studio-web/foo.rb apps/studio-web/CHANGELOG.md

# Multi-app commit — exempt.
echo "edit-4" >> apps/studio-web/foo.rb
echo "edit-4" >> apps/gascalc/bar.swift
git add apps/studio-web/foo.rb apps/gascalc/bar.swift
if run_hook "TBL-100: cross-app refactor"; then
  pass "Linear-key cross-app commit is exempt"
else
  fail "Linear-key cross-app commit should be exempt"
fi
reset; git restore apps/studio-web/foo.rb apps/gascalc/bar.swift

# No-app commit (only scripts/) — exempt.
echo "edit-5" >> scripts/baz.sh; git add scripts/baz.sh
if run_hook "HMB-9: tooling tweak"; then
  pass "Linear-key no-app commit is exempt"
else
  fail "Linear-key no-app commit should be exempt"
fi
reset; git restore scripts/baz.sh

# Subject like "Closes TBL-26: ..." — does NOT match Linear-key prefix
# (must start with KEY-N:). Exempt.
echo "edit-6" >> apps/studio-web/foo.rb; git add apps/studio-web/foo.rb
if run_hook "Closes TBL-26"; then
  pass "Plain 'Closes TBL-N' is exempt (no key prefix)"
else
  fail "Plain 'Closes TBL-N' should be exempt"
fi
reset; git restore apps/studio-web/foo.rb

# Subject `chore(studio-web): ...` — matches Conventional Commits but is
# not feat/fix, so first regex doesn't match. Then Linear regex doesn't
# match either. Exempt.
echo "edit-7" >> apps/studio-web/foo.rb; git add apps/studio-web/foo.rb
if run_hook "chore(studio-web): style fix"; then
  pass "chore(studio-web) is exempt"
else
  fail "chore(studio-web) should be exempt"
fi
reset; git restore apps/studio-web/foo.rb

# ── Path 3 — project.yml-driven monorepo-root apps (HMB-26) ─────────────
#
# Synthetic monorepo where the app lives at <root>/<App>/ rather than
# under apps/<X>/, and project.yml declares an explicit changelog
# override. Mirrors the SHOPOS layout (ShopOS at the field-suite
# monorepo root, CHANGELOG at Documentation/Release/CHANGELOG.md).

echo
echo "Path 3 — project.yml-driven monorepo-root apps"

ROOTAPP="${TMPDIR:-/tmp}/changelog-check-test-rootapp-$$"
trap 'rc=$?; if [[ "$KEEP" -eq 0 ]]; then rm -rf "$FIXTURE" "$ROOTAPP"; fi; exit $rc' EXIT INT TERM

mkdir -p "$ROOTAPP/.homebase" "$ROOTAPP/ShopOS/app/models" "$ROOTAPP/ShopOS/Documentation/Release" "$ROOTAPP/SiteDB/app" "$ROOTAPP/scripts"
cd "$ROOTAPP"
git init -q -b main >/dev/null 2>&1
git config user.email "test@test"; git config user.name "Test"

cat > .homebase/project.yml <<'YML'
name: field-suite-fixture
display_name: "Field Suite (test)"
description: "Synthetic monorepo for changelog-check Path 3."
kind: monorepo
domains: [web]
apps:
  - name: shopos
    path: ShopOS
    platforms: [web]
    status: active
    summary: "Synthetic SHOPOS app."
    changelog: ShopOS/Documentation/Release/CHANGELOG.md
  - name: sitedb
    path: SiteDB
    platforms: [web]
    status: active
    summary: "Synthetic SiteDB app (default changelog path)."
YML

printf '# SHOPOS\n\n## [Unreleased]\n' > ShopOS/Documentation/Release/CHANGELOG.md
printf '# SiteDB\n\n## [Unreleased]\n' > SiteDB/CHANGELOG.md
printf 'placeholder' > ShopOS/app/models/widget.rb
printf 'placeholder' > SiteDB/app/router.rb
printf 'placeholder' > scripts/build.sh
git add -A; git commit -q -m "seed" >/dev/null

# Linear-key commit on SHOPOS without staging the changelog → reject.
echo "edit-rootapp-1" >> ShopOS/app/models/widget.rb; git add ShopOS/app/models/widget.rb
if run_hook "TFD-9999: tweak SHOPOS"; then
  fail "TFD-9999 SHOPOS-only without overridden CHANGELOG should reject"
else
  pass "TFD-9999 SHOPOS-only without overridden CHANGELOG rejects"
fi

# Stage the overridden changelog → pass.
echo "- entry" >> ShopOS/Documentation/Release/CHANGELOG.md
git add ShopOS/Documentation/Release/CHANGELOG.md
if run_hook "TFD-9999: tweak SHOPOS"; then
  pass "TFD-9999 SHOPOS-only with overridden CHANGELOG passes"
else
  fail "TFD-9999 SHOPOS-only with overridden CHANGELOG should pass"
fi
git restore --staged . >/dev/null 2>&1 || true
git restore ShopOS/app/models/widget.rb ShopOS/Documentation/Release/CHANGELOG.md

# Linear-key commit on SiteDB without staging the (default-path)
# changelog → reject. Confirms the default `<path>/CHANGELOG.md`
# fallback works for declared apps that don't set `changelog:`.
echo "edit-rootapp-2" >> SiteDB/app/router.rb; git add SiteDB/app/router.rb
if run_hook "TFD-9998: tweak SiteDB"; then
  fail "TFD-9998 SiteDB-only without default CHANGELOG should reject"
else
  pass "TFD-9998 SiteDB-only without default CHANGELOG rejects"
fi
git restore --staged . >/dev/null 2>&1 || true
git restore SiteDB/app/router.rb

# Conventional Commits scope on a project.yml app at non-apps/ path.
echo "edit-rootapp-3" >> ShopOS/app/models/widget.rb; git add ShopOS/app/models/widget.rb
if run_hook "feat(shopos): add widget"; then
  fail "feat(shopos) without overridden CHANGELOG should reject"
else
  pass "feat(shopos) without overridden CHANGELOG rejects"
fi
echo "- entry" >> ShopOS/Documentation/Release/CHANGELOG.md
git add ShopOS/Documentation/Release/CHANGELOG.md
if run_hook "feat(shopos): add widget"; then
  pass "feat(shopos) with overridden CHANGELOG passes"
else
  fail "feat(shopos) with overridden CHANGELOG should pass"
fi
git restore --staged . >/dev/null 2>&1 || true
git restore ShopOS/app/models/widget.rb ShopOS/Documentation/Release/CHANGELOG.md

# Cross-app commit on SHOPOS + SiteDB → exempt (no single covering app).
echo "edit-rootapp-4" >> ShopOS/app/models/widget.rb
echo "edit-rootapp-4" >> SiteDB/app/router.rb
git add ShopOS/app/models/widget.rb SiteDB/app/router.rb
if run_hook "TFD-9997: cross-app refactor"; then
  pass "Cross-app monorepo-root commit is exempt"
else
  fail "Cross-app monorepo-root commit should be exempt"
fi
git restore --staged . >/dev/null 2>&1 || true
git restore ShopOS/app/models/widget.rb SiteDB/app/router.rb

# No-app commit (only scripts/) → exempt.
echo "edit-rootapp-5" >> scripts/build.sh; git add scripts/build.sh
if run_hook "HMB-9999: tooling tweak"; then
  pass "Linear-key no-app monorepo-root commit is exempt"
else
  fail "Linear-key no-app monorepo-root commit should be exempt"
fi
git restore --staged . >/dev/null 2>&1 || true
git restore scripts/build.sh

# Skip-trailer escape hatch still works under project.yml lookup.
echo "edit-rootapp-6" >> ShopOS/app/models/widget.rb; git add ShopOS/app/models/widget.rb
if run_hook "TFD-9996: refactor SHOPOS internals" "$(printf 'Body.\n\nChangelog skipped: pure refactor, no observable change.\n')"; then
  pass "TFD-9996 SHOPOS-only with skip trailer passes"
else
  fail "TFD-9996 SHOPOS-only with skip trailer should pass"
fi
git restore --staged . >/dev/null 2>&1 || true
git restore ShopOS/app/models/widget.rb

# ── Path 4 — extra_paths for multi-platform apps (HMB-26) ────────────────
#
# Synthetic monorepo where a single app (GasCalc) lives at TWO roots
# (iOS/Apps/GasCalc + Android/apps/gascalc), each with its own CHANGELOG.
# Mirrors the real field-suite GasCalc/LogApp setup.

echo
echo "Path 4 — extra_paths for multi-platform apps"

MULTI="${TMPDIR:-/tmp}/changelog-check-test-multi-$$"
trap 'rc=$?; if [[ "$KEEP" -eq 0 ]]; then rm -rf "$FIXTURE" "$ROOTAPP" "$MULTI"; fi; exit $rc' EXIT INT TERM

mkdir -p "$MULTI/.homebase" "$MULTI/iOS/Apps/GasCalc/Sources" "$MULTI/Android/apps/gascalc/src" "$MULTI/scripts"
cd "$MULTI"
git init -q -b main >/dev/null 2>&1
git config user.email "test@test"; git config user.name "Test"

cat > .homebase/project.yml <<'YML'
name: tfd-multi-fixture
display_name: "TFD multi-platform fixture"
description: "Synthetic dual-platform GasCalc."
kind: monorepo
domains: [ios, android]
apps:
  - name: gascalc
    path: iOS/Apps/GasCalc
    platforms: [ios, android]
    status: active
    summary: "Synthetic dual-platform GasCalc."
    extra_paths:
      - path: Android/apps/gascalc
        changelog: Android/apps/gascalc/CHANGELOG.md
YML

printf '# GasCalc iOS\n\n## [Unreleased]\n' > iOS/Apps/GasCalc/CHANGELOG.md
printf '# GasCalc Android\n\n## [Unreleased]\n' > Android/apps/gascalc/CHANGELOG.md
printf 'placeholder' > iOS/Apps/GasCalc/Sources/Calc.swift
printf 'placeholder' > Android/apps/gascalc/src/Calc.kt
printf 'placeholder' > scripts/build.sh
git add -A; git commit -q -m "seed" >/dev/null

# iOS-side commit must update the iOS CHANGELOG.
echo "ios-edit" >> iOS/Apps/GasCalc/Sources/Calc.swift
git add iOS/Apps/GasCalc/Sources/Calc.swift
if run_hook "TFD-9001: tweak GasCalc iOS"; then
  fail "TFD-9001 GasCalc-iOS only without iOS CHANGELOG should reject"
else
  pass "TFD-9001 GasCalc-iOS only without iOS CHANGELOG rejects"
fi
echo "- entry" >> iOS/Apps/GasCalc/CHANGELOG.md
git add iOS/Apps/GasCalc/CHANGELOG.md
if run_hook "TFD-9001: tweak GasCalc iOS"; then
  pass "TFD-9001 GasCalc-iOS with iOS CHANGELOG passes"
else
  fail "TFD-9001 GasCalc-iOS with iOS CHANGELOG should pass"
fi
# Wrong-side CHANGELOG must NOT satisfy: stage Android CHANGELOG only.
git restore --staged . >/dev/null 2>&1 || true
git restore iOS/Apps/GasCalc/CHANGELOG.md
echo "ios-edit-2" >> iOS/Apps/GasCalc/Sources/Calc.swift
echo "- entry" >> Android/apps/gascalc/CHANGELOG.md
git add iOS/Apps/GasCalc/Sources/Calc.swift Android/apps/gascalc/CHANGELOG.md
if run_hook "TFD-9002: tweak GasCalc iOS"; then
  fail "TFD-9002 GasCalc-iOS staging Android CHANGELOG should reject"
else
  pass "TFD-9002 GasCalc-iOS staging Android CHANGELOG rejects"
fi
git restore --staged . >/dev/null 2>&1 || true
git restore iOS/Apps/GasCalc/Sources/Calc.swift Android/apps/gascalc/CHANGELOG.md

# Android-side commit must update the Android CHANGELOG via extra_paths.
echo "android-edit" >> Android/apps/gascalc/src/Calc.kt
git add Android/apps/gascalc/src/Calc.kt
if run_hook "TFD-9003: tweak GasCalc Android"; then
  fail "TFD-9003 GasCalc-Android only without Android CHANGELOG should reject"
else
  pass "TFD-9003 GasCalc-Android only without Android CHANGELOG rejects"
fi
echo "- entry" >> Android/apps/gascalc/CHANGELOG.md
git add Android/apps/gascalc/CHANGELOG.md
if run_hook "TFD-9003: tweak GasCalc Android"; then
  pass "TFD-9003 GasCalc-Android with Android CHANGELOG passes"
else
  fail "TFD-9003 GasCalc-Android with Android CHANGELOG should pass"
fi
git restore --staged . >/dev/null 2>&1 || true
git restore Android/apps/gascalc/src/Calc.kt Android/apps/gascalc/CHANGELOG.md

# Cross-platform commit (touches BOTH iOS + Android sides of GasCalc) →
# exempt, since no single candidate path covers all staged files.
echo "cross-1" >> iOS/Apps/GasCalc/Sources/Calc.swift
echo "cross-2" >> Android/apps/gascalc/src/Calc.kt
git add iOS/Apps/GasCalc/Sources/Calc.swift Android/apps/gascalc/src/Calc.kt
if run_hook "TFD-9004: cross-platform GasCalc refactor"; then
  pass "Cross-platform commit on multi-path app is exempt"
else
  fail "Cross-platform commit on multi-path app should be exempt"
fi
git restore --staged . >/dev/null 2>&1 || true
git restore iOS/Apps/GasCalc/Sources/Calc.swift Android/apps/gascalc/src/Calc.kt

# Conventional Commits scope on a multi-path app: the iOS-side commit
# resolves to the iOS CHANGELOG via the staged-paths disambiguation.
echo "ios-edit-3" >> iOS/Apps/GasCalc/Sources/Calc.swift
git add iOS/Apps/GasCalc/Sources/Calc.swift
if run_hook "feat(gascalc): tweak iOS calc"; then
  fail "feat(gascalc) iOS without iOS CHANGELOG should reject"
else
  pass "feat(gascalc) iOS without iOS CHANGELOG rejects"
fi
echo "- entry" >> iOS/Apps/GasCalc/CHANGELOG.md
git add iOS/Apps/GasCalc/CHANGELOG.md
if run_hook "feat(gascalc): tweak iOS calc"; then
  pass "feat(gascalc) iOS with iOS CHANGELOG passes"
else
  fail "feat(gascalc) iOS with iOS CHANGELOG should pass"
fi

echo
echo "── results: $PASS pass, $FAIL fail"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
