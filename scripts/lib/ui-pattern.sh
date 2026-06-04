#!/usr/bin/env bash
# scripts/lib/ui-pattern.sh — canonical UI-file pattern + SOP-007 trailer
# matching. Single source of truth used by:
#
#   - scripts/hooks/ui-verification-check.sh   (Stop-hook gate, post-commit;
#                                               strict block in default mode)
#   - scripts/hooks/commit-sop-check.sh         (commit-msg hook; warn-only
#                                               shift-left at commit time —
#                                               HMB-59)
#
# Keeping both gates on this lib prevents the regex-drift failure mode
# where "what counts as UI" diverges between commit time and Stop time.
#
# Canonical SOP: ~/code/homebase/sops/HOMEBASE-SOP-007-UI_VERIFICATION.md

# ── UI_PATTERN_RE ───────────────────────────────────────────────────────────
# Paths/extensions that constitute "rendered UI" per SOP-007. Composed of
# three trigger groups:
#
# 1. Template-language extensions — always rendering, always trip:
#    .erb / .html / .html.tmpl / .gohtml / .scss / .css / .sass /
#    .vue / .svelte / .stimulus.js
#    (HMB-72: bare `.tmpl` was removed — it false-positived on YAML config
#    scaffolds like templates/project.yml.tmpl. Only `.html.tmpl` HTML
#    templates trip; a genuine non-HTML `.tmpl` rendering surface should be
#    given a real extension or added explicitly here.)
#
# 2. Path triggers — anything inside these dirs trips regardless of ext:
#    app/views/, app/javascript/<*>.{js,ts}, app/assets/stylesheets/,
#    apps/<*>/views/, apps/<*>/templates/, apps/<*>/Views/,
#    docs/_layouts/, docs/_includes/, docs/_sass/, and the UI dir names in
#    BOTH case conventions: /Views/ /views/, /Screens/ /screens/,
#    /Components/ /components/, /UI/ /ui/, /Pages/ /pages/.
#    (HMB-39: lowercase variants added so Kotlin/Compose paths like
#    `gascalc/ui/.../GasPropertiesScreen.kt` — lowercase `/ui/` per the Kotlin
#    package convention — are flagged. Path triggers enumerate both cases
#    rather than matching case-insensitively, so the filename-suffix triggers
#    below stay strict on the Apple `*View.swift` uppercase convention.)
#
# 3. UI-shaped Swift / TSX / JSX filenames — *View / *Screen / *Sheet /
#    *Cell / *Layout. SwiftUI / React rendering code has these suffixes by
#    convention; non-UI Swift (DaltonApp.swift, repositories, view models,
#    services, utilities) does not.
#
# A bare `.swift` / `.tsx` / `.jsx` change in a non-UI path with a non-UI
# filename does NOT trigger. (HMB-19 — was tripping on every Swift edit
# before.) Per-project exemptions still available via
# `.ui-verification-excludes`.
UI_PATTERN_RE='\.(erb|html|html\.tmpl|gohtml|scss|css|sass|vue|svelte|stimulus\.js)$|app/views/|app/javascript/.*\.(js|ts)$|app/assets/stylesheets/|apps/.*/views/|apps/.*/templates/|apps/.*/Views/|docs/_layouts/|docs/_includes/|docs/_sass/|/Views/|/views/|/Screens/|/screens/|/Components/|/components/|/UI/|/ui/|/Pages/|/pages/|(View|Screen|Sheet|Cell|Layout)\.swift$|(View|Screen|Sheet|Cell|Layout)\.(tsx|jsx)$'

# ── UI_EXCLUDE_PATTERN_RE ───────────────────────────────────────────────────
# Universal exclusions: paths that look like UI by extension/dir but are
# either test fixtures or vendored dependencies. Always applied.
#
# `vendor/` and `node_modules/` are anchored as `(^|/)` so the exclusion
# fires both for top-level (`vendor/jquery.js`) and nested
# (`apps/web/vendor/jquery.js`) layouts. The previous `/vendor/` form
# silently failed at the top level since `git diff --cached --name-only`
# returns paths relative to the repo root with no leading slash. (HMB-59
# regression in the integration tests caught this; pre-existing in
# `ui-verification-check.sh` before the lib extraction.)
UI_EXCLUDE_PATTERN_RE='/fixtures/.*\.html$|(^|/)vendor/|(^|/)node_modules/'

# ── UI_TRAILER_RE ───────────────────────────────────────────────────────────
# SOP-007 verification trailer prefixes. Line-anchored, case-insensitive
# match (callers use `grep -Eiq`). The hook is intentionally strict on
# prefix — see HMB-45 Finding 5 reproduction for why typos here are a
# common false-negative.
UI_TRAILER_RE='^(Verified in browser|Verified by XCUITest|Verified on simulator|Verified on device|UI verification waived|UI verification skipped):'

# ── homebase_ui_load_project_excludes <repo_root> ───────────────────────────
# Prints (to stdout) the combined exclude regex: UI_EXCLUDE_PATTERN_RE PLUS
# anything in <repo_root>/.ui-verification-excludes (one glob per line,
# blank/`#`-prefixed lines ignored). Globs are translated to regex with
# minimal metachar escaping and `*` → `[^/]*`.
homebase_ui_load_project_excludes() {
  local repo_root="$1"
  local pattern="$UI_EXCLUDE_PATTERN_RE"
  local excludes_file="$repo_root/.ui-verification-excludes"
  if [[ -f "$excludes_file" ]]; then
    local line escaped
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" == \#* ]] && continue
      escaped=$(printf '%s' "$line" | sed 's/[.+?(){}|^$]/\\&/g; s/\*/[^/]*/g')
      pattern="${pattern}|${escaped}"
    done < "$excludes_file"
  fi
  printf '%s' "$pattern"
}

# ── homebase_ui_files_touch_ui <repo_root> <files_string> ───────────────────
# Returns 0 if the newline-separated `files_string` contains at least one
# path that matches UI_PATTERN_RE and is NOT covered by the (universal +
# project) exclude pattern. Returns 1 otherwise.
homebase_ui_files_touch_ui() {
  local repo_root="$1"
  local files="$2"
  local exclude_pattern
  exclude_pattern=$(homebase_ui_load_project_excludes "$repo_root")

  local relevant
  relevant=$(printf '%s\n' "$files" | grep -Ev "$exclude_pattern" || true)
  [[ -z "$relevant" ]] && return 1

  if printf '%s\n' "$relevant" | grep -Eq "$UI_PATTERN_RE"; then
    return 0
  fi
  return 1
}

# ── homebase_ui_msg_has_trailer <commit_msg> ────────────────────────────────
# Returns 0 if the commit message has at least one line matching
# UI_TRAILER_RE. Returns 1 otherwise. Case-insensitive.
homebase_ui_msg_has_trailer() {
  local msg="$1"
  if printf '%s\n' "$msg" | grep -Eiq "$UI_TRAILER_RE"; then
    return 0
  fi
  return 1
}
