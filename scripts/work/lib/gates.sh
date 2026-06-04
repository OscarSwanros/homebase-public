#!/usr/bin/env bash
# scripts/work/lib/gates.sh — gate evaluator stdlib for `homebase work finish`.
#
# Each gate function:
#   - Takes the current repo root via env var GATE_REPO_ROOT (or autodetects).
#   - Reads work-state via state.sh helpers.
#   - Returns 0 (pass) or non-zero (fail).
#   - Prints a one-line gate header to stdout (`[ok] <name>` / `[fail] <name>`).
#   - On failure, prints multi-line remediation to stderr.
#
# Sourced by:
#   - scripts/work/finish.sh
#   - scripts/work/checkpoint.sh (subset: gates 4-9 in dry-run preview)
#
# Reuses existing single-source validators rather than duplicating regex /
# logic:
#   - scripts/lib/issue-trailer.sh — TRAILER_LINE_RE, TRAILER_ANYWHERE_RE
#   - scripts/hooks/commit-sop-check.sh — per-commit trailer check
#   - scripts/hooks/commit-changelog-check.sh — per-commit changelog check
#   - scripts/hooks/ui-verification-check.sh — per-commit UI trailer check
#
# This file is symlinked into each homebase-adopting project by
# `bin/homebase link-project`. Do not edit copies.

[[ -n "${_WORK_GATES_SOURCED:-}" ]] && return 0
_WORK_GATES_SOURCED=1

_GATES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=./state.sh
. "${_GATES_DIR}/state.sh"
# shellcheck source=../../lib/issue-trailer.sh
. "${_GATES_DIR}/../../lib/issue-trailer.sh"
# shellcheck source=./worktree.sh
. "${_GATES_DIR}/worktree.sh"

# ── Per-kind gate-skip decision (HMB-86 + HMB-103) ────────────────────────────
#
# should_skip_gate <work_kind> <gate_name> <issue> — pure decision, no globals
# and no I/O, so it is unit-testable. Returns 0 when the named gate should be
# SKIPPED for this work kind, 1 when it must RUN.
#
#   chore  — skips closing-keyword / changelog / validate / ui unconditionally
#            (those concepts don't apply). Skips the Linear gates (8 in-progress,
#            13 transitioned) ONLY when the chore has no issue; an issue-bearing
#            chore moved Backlog→In Progress at start and MUST transition
#            In Progress→Done at finish (HMB-103 — skipping it stranded
#            TBL-551/552/553 "In Progress").
#   hotfix — skips changelog / in-progress / PR / transitioned (P0 fast path).
should_skip_gate() {
  local work_kind="$1" gate="$2" issue="${3:-}"
  case "$work_kind" in
    chore)
      case "$gate" in
        gate6_closing|gate7_changelog|gate9_validate|gate10_ui) return 0 ;;
        gate8_linear|gate13_linear) [[ -z "$issue" ]] && return 0 || return 1 ;;
      esac
      ;;
    hotfix)
      case "$gate" in
        gate7_changelog|gate8_linear|gate12_pr|gate13_linear) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# ── Gate output helpers ───────────────────────────────────────────────────────

GATE_OK=0
GATE_FAIL=2

_gate_repo_root() {
  echo "${GATE_REPO_ROOT:-$(find_repo_root)}"
}

gate_pass() {
  printf '  [ok]   %s\n' "$1"
  return $GATE_OK
}

gate_fail() {
  local name="$1"; shift
  printf '  [fail] %s\n' "$name"
  if (($#)); then
    printf '\n%s\n\n' "$*" >&2
  fi
  return $GATE_FAIL
}

gate_skip() {
  printf '  [skip] %s — %s\n' "$1" "${2:-disabled}"
  return $GATE_OK
}

# ── Transport helpers (gate 11 `gh api` fallback — HMB-54) ────────────────────
#
# Gate 11 lands the work branch on main via `git fetch` + `git push`. Some
# operator environments (constrained networks, per-binary socket filters)
# selectively block `git`'s sockets while letting the system's general HTTPS
# (used by `gh api`) through. These helpers expose the same fetch/FF-push
# operations through the GitHub REST API so gate 11 can survive that case.
#
# Used only as a fallback: the gate calls `git` first and reaches for these
# helpers only when the git transport fails. The single `[warn]` line is
# emitted at most once per gate invocation via `_GATE_FALLBACK_WARNED`.

# Resolve owner/repo for origin via the local remote URL. Reads only the
# local git config (no network), so it works even when transport is broken.
# Echoes "owner/repo" on stdout; returns non-zero when the remote is missing
# or not a github.com URL.
_gate_owner_repo() {
  local root url
  root="$(_gate_repo_root)"
  url="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  [[ -z "$url" ]] && return 1
  if [[ "$url" =~ github\.com[/:]([^/]+/[^/.[:space:]]+)(\.git)?/?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# Fetch origin/main's SHA via the GitHub REST API. Echoes the SHA on stdout
# on success, returns non-zero on failure.
_gate_origin_main_sha_via_api() {
  local owner_repo
  owner_repo="$(_gate_owner_repo)" || return 1
  gh api "repos/${owner_repo}/git/refs/heads/main" --jq '.object.sha' 2>/dev/null
}

# FF-push <head_sha> to refs/heads/main via the GitHub REST API. Returns 0 on
# success. The REST endpoint refuses non-fast-forward updates when `force` is
# false, which is exactly the invariant the gate wants to preserve.
# Args: <head_sha>
_gate_ff_push_main_via_api() {
  local head_sha="$1"
  local owner_repo
  owner_repo="$(_gate_owner_repo)" || return 1
  gh api -X PATCH "repos/${owner_repo}/git/refs/heads/main" \
    -f "sha=${head_sha}" -F "force=false" >/dev/null 2>&1
}

# Delete a branch ref on origin via the GitHub REST API. Fire-and-forget like
# the `git push --delete` it falls back from; ignores 404 (already gone).
# Args: <branch>
_gate_delete_branch_via_api() {
  local branch="$1"
  local owner_repo
  owner_repo="$(_gate_owner_repo)" || return 1
  # URL-encode slashes in the branch ref so feature/foo doesn't 404.
  local ref="${branch//\//%2F}"
  gh api -X DELETE "repos/${owner_repo}/git/refs/heads/${ref}" >/dev/null 2>&1
}

# Emit the single fallback-warning line per gate invocation. Idempotent: the
# guard variable resets across separate gate runs because the calling shell
# unsets it (or simply doesn't carry it across runs).
_gate_warn_transport_fallback() {
  [[ -n "${_GATE_FALLBACK_WARNED:-}" ]] && return 0
  _GATE_FALLBACK_WARNED=1
  echo "  [warn] gate 11: git transport failed, falling back to gh api" >&2
}

# ── Gate 0: preflight (toolchain & env prerequisites) ────────────────────────
#
# Runs before gate 1. Not memoized — re-evaluates every finish invocation
# because the env can change between runs (operator switches xcode-select,
# unsets ANDROID_HOME, etc.). Fast-fails in <1s instead of letting gate 9's
# 5-15-minute validate run discover the same gap mid-flight.
#
# Per the project's domains[] (read from .homebase/project.yml):
#   - ios / macos   : `xcode-select -p` resolves to /Applications/Xcode.app/...
#   - android       : ANDROID_HOME points to a real SDK; `java` resolves
#                     (via `mise exec --` when .mise.toml exists, else direct)
#   - web           : `bundle check` succeeds (Gemfile.lock matches Gemfile)
#   - any           : if .mise.toml exists, `mise current` returns no errors
#
# Project-specific domains not in the predefined map (cli, governance, etc.)
# are silently passed — they don't have an associated toolchain to verify.
#
# (HMB-16)

gate_preflight() {
  local root; root="$(_gate_repo_root)"
  local project_json
  project_json="$(read_project_yml_as_json "$root")" || {
    gate_fail "preflight" "Could not load project.yml at $root/.homebase/project.yml"
    return $GATE_FAIL
  }

  local domains
  domains="$(printf '%s' "$project_json" | jq -r '.domains // [] | .[]')"

  local has_mise=0
  [[ -f "$root/.mise.toml" || -f "$root/mise.toml" ]] && has_mise=1

  # Helper: resolve a command via mise if available, else direct.
  local mise_prefix=""
  if [[ "$has_mise" -eq 1 ]] && command -v mise >/dev/null 2>&1; then
    mise_prefix="mise exec --"
  fi

  local failed=0
  local report=""
  add_fail() {
    failed=1
    report="${report}    [fail] $1
$2

"
  }

  # Per-domain checks.
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    case "$domain" in
      ios|macos)
        local xc_path
        xc_path="$(xcode-select -p 2>/dev/null || echo "")"
        if [[ -z "$xc_path" ]]; then
          add_fail "$domain: xcode-select" \
            "      xcode-select -p returned empty. Install Xcode from the App Store
      and run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        elif [[ "$xc_path" == */CommandLineTools* ]]; then
          add_fail "$domain: xcode-select points at CommandLineTools, not Xcode.app" \
            "      Current: $xc_path
      Fastlane / xcodebuild need the full Xcode dev dir. Run:
        sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
        elif [[ ! -d "$xc_path" ]]; then
          add_fail "$domain: xcode-select path missing" \
            "      Current: $xc_path
      The selected developer dir doesn't exist. Verify Xcode.app is installed
      at /Applications/Xcode.app and re-select with sudo xcode-select -s ..."
        fi
        ;;
      android)
        # ANDROID_HOME (or ANDROID_SDK_ROOT) — read via mise exec inside the
        # project root so .mise.toml's [env] entries are picked up. mise
        # reads config from the current dir, not the script's cwd.
        local resolved_home
        if [[ -n "$mise_prefix" ]]; then
          resolved_home="$( cd "$root" && $mise_prefix bash -c 'echo "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"' 2>/dev/null )"
        else
          resolved_home="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
        fi
        if [[ -z "$resolved_home" ]]; then
          add_fail "android: ANDROID_HOME unset" \
            "      Set ANDROID_HOME in your shell or in .mise.toml's [env] block:
        ANDROID_HOME = \"{{env.HOME}}/Library/Android/sdk\""
        elif [[ ! -d "$resolved_home/platforms" ]]; then
          add_fail "android: ANDROID_HOME points at incomplete SDK" \
            "      Current: $resolved_home
      Expected platforms/ subdirectory. Open Android Studio → SDK Manager
      and ensure at least one Android platform is installed."
        fi
        # Java — same: cd into project so mise loads the right .mise.toml.
        local java_ver
        if [[ -n "$mise_prefix" ]]; then
          java_ver="$( cd "$root" && $mise_prefix java -version 2>&1 | head -1 )"
        else
          java_ver="$(java -version 2>&1 | head -1)"
        fi
        if ! printf '%s' "$java_ver" | grep -qiE '(openjdk|java) version'; then
          add_fail "android: java not found on PATH" \
            "      java -version did not return a recognised JDK header.
      For mise: \`mise install java@temurin-17\` then pin in .mise.toml.
      For homebrew: \`brew install openjdk@17\`."
        fi
        ;;
      web)
        # Rails-flavoured web; bundle check is the standard preflight.
        if [[ -f "$root/Gemfile" ]]; then
          local bundle_out
          if [[ -n "$mise_prefix" ]]; then
            bundle_out="$( cd "$root" && $mise_prefix bundle check 2>&1 || true )"
          else
            bundle_out="$( cd "$root" && bundle check 2>&1 || true )"
          fi
          if ! printf '%s' "$bundle_out" | grep -qE 'dependencies are satisfied'; then
            add_fail "web: bundle check failed" \
              "      cd $root && bundle install
      Output (last 3 lines):
$(printf '%s' "$bundle_out" | tail -3 | sed 's/^/      /')"
          fi
        fi
        ;;
      cli|governance|*)
        # No predefined toolchain check; silently pass.
        ;;
    esac
  done <<< "$domains"

  # Generic mise check — surfaces unresolved tool versions across the board.
  if [[ "$has_mise" -eq 1 ]] && command -v mise >/dev/null 2>&1; then
    local mise_out
    mise_out="$( cd "$root" && mise current 2>&1 || true )"
    if printf '%s' "$mise_out" | grep -qiE 'error|missing|not installed'; then
      add_fail "mise: tool versions unresolved" \
        "      cd $root && mise install
      Output:
$(printf '%s' "$mise_out" | sed 's/^/      /')"
    fi
  fi

  if [[ "$failed" -eq 1 ]]; then
    gate_fail "preflight" \
      "Toolchain prerequisites for project domains [$(printf '%s' "$domains" | tr '\n' ',' | sed 's/,$//')] missing or misconfigured:

$report"
    return $GATE_FAIL
  fi

  gate_pass "preflight ($(printf '%s' "$domains" | tr '\n' ',' | sed 's/,$//; s/,/, /g'))"
}

# ── Gate 1: state-loaded ──────────────────────────────────────────────────────

gate_state_loaded() {
  local root; root="$(_gate_repo_root)"
  local p; p="$(state_path "$root")"
  [[ -f "$p" ]] || {
    gate_fail "state-loaded" "No work-state file at $p.

Run 'homebase work start <KEY>' to begin work, or 'homebase work resume <KEY>'
to rebuild state from the current branch + Linear state."
    return $?
  }
  require_jq >/dev/null 2>&1 || {
    gate_fail "state-loaded" "jq is required but not installed."
    return $?
  }
  # HMB-86: chore work-states have .issue = null (no tracked issue). Accept
  # `.issue` as string for tracked work OR null when `.kind` is "chore".
  jq -e '.schema_version == 1 and (.branch | type == "string") and ((.issue | type == "string") or (.kind == "chore" and .issue == null))' "$p" >/dev/null 2>&1 || {
    gate_fail "state-loaded" "work-state at $p is malformed.

Either fix the file by hand or 'homebase work cancel' and start over."
    return $?
  }
  gate_pass "state-loaded ($(state_read issue "$root"))"
}

# ── Gate 2: branch-on-track ───────────────────────────────────────────────────

gate_branch_on_track() {
  local root; root="$(_gate_repo_root)"
  local expected current
  expected="$(state_branch "$root")"
  current="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")"
  if [[ "$expected" == "$current" ]]; then
    gate_pass "branch-on-track ($current)"
  else
    gate_fail "branch-on-track" \
      "HEAD is on '$current' but work-state expects '$expected'.

Either:
  git checkout $expected
or, if work continued on '$current' intentionally, run:
  homebase work resume $(state_issue "$root")"
  fi
}

# ── Gate 3: tree-clean ────────────────────────────────────────────────────────

gate_tree_clean() {
  local root; root="$(_gate_repo_root)"
  local dirty
  dirty="$(git -C "$root" status --porcelain 2>/dev/null)"
  if [[ -z "$dirty" ]]; then
    gate_pass "tree-clean"
  else
    local count
    count="$(printf '%s\n' "$dirty" | wc -l | tr -d ' ')"
    gate_fail "tree-clean" \
      "$count uncommitted change(s):
$dirty

Stage and commit (with a 'Refs <KEY>' trailer), or 'git stash' deferral work."
  fi
}

# ── Gate 3.5: commits-present (HMB-45 Finding 9) ─────────────────────────────
#
# Refuses to finish when no commits exist between the branch base and HEAD.
# Catches the empty-commit-range cascade: an agent that misroutes its work
# to a different repo and runs `homebase work finish` on the empty
# worktree would otherwise proceed all the way through commits-trailered
# (vacuously true on an empty range), validate-passes, ui-verified, etc.,
# transition Linear to Done with zero shipped code, and tear down the
# worktree. All-or-nothing posture: no Linear transition, no push, no
# worktree teardown, no work-state finalisation.
#
# Runs after state-loaded and branch-on-track (so we know the work-state
# is consistent before we declare the range empty), before tree-clean
# (which catches uncommitted dirt — different failure class).

gate_commits_present() {
  local root; root="$(_gate_repo_root)"
  local issue base_sha
  issue="$(state_issue "$root")"
  base_sha="$(state_read base_sha "$root")"
  [[ -z "$base_sha" ]] && base_sha="$(git -C "$root" merge-base HEAD origin/main 2>/dev/null || echo "")"

  if [[ -z "$base_sha" ]]; then
    # No base SHA recorded and no origin/main to fall back on. Skip rather
    # than fail — the existing fallback path in commits-trailered handles
    # this case (HEAD~5..HEAD) with the same posture, and an inferred range
    # cannot be empty by construction.
    gate_skip "commits-present" "no base SHA recorded; deferring to commits-trailered"
    return 0
  fi

  local count
  count="$(git -C "$root" rev-list "${base_sha}..HEAD" --count 2>/dev/null | tr -d ' ')"
  if [[ -z "$count" || "$count" == "0" ]]; then
    gate_fail "commits-present" \
      "No commits between base ${base_sha:0:7} and HEAD for $issue.

Did you commit on the wrong branch? The active work-state expected commits on
this branch; HEAD is unchanged from base. Two likely causes:
  (a) edits landed on a different branch (typically main) — see HMB-45 F8's
      commit-policy gate. Find them with: git log --all --oneline ${base_sha:0:7}..
  (b) the worktree is the wrong repo entirely (cross-project misroute) —
      see HMB-45 F7's start-time pre-flight gate.

Refusing to finish: no Linear transition, no push, no worktree teardown.
Recover by either committing the work in this branch or 'homebase work cancel'
to abandon the work-state."
    return $GATE_FAIL
  fi
  gate_pass "commits-present (${count} commit(s) on ${base_sha:0:7}..HEAD)"
}

# ── Gate 4: commits-trailered ─────────────────────────────────────────────────

gate_commits_trailered() {
  local root; root="$(_gate_repo_root)"
  local issue base_sha
  issue="$(state_issue "$root")"
  base_sha="$(state_read base_sha "$root")"
  [[ -z "$base_sha" ]] && base_sha="$(git -C "$root" merge-base HEAD origin/main 2>/dev/null || echo "")"

  local range
  if [[ -n "$base_sha" ]]; then
    range="${base_sha}..HEAD"
  else
    range="HEAD~5..HEAD"
  fi

  local missing=""
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    local msg subject
    msg="$(git -C "$root" log -1 --pretty=%B "$sha" 2>/dev/null || true)"
    subject="$(printf '%s' "$msg" | head -1)"
    # Exempt categories — same as commit-sop-check.sh.
    if printf '%s' "$subject" | grep -Eq '^(Release |Post-release:|Merge )'; then
      continue
    fi
    if printf '%s' "$subject" | grep -Eiq '^chore(\([^)]+\))?:'; then
      continue
    fi
    if ! printf '%s' "$msg" | grep -qiE "$TRAILER_ANYWHERE_RE"; then
      missing+="${sha:0:9} ${subject}\n"
    fi
  done < <(git -C "$root" log "$range" --format=%H 2>/dev/null)

  if [[ -z "$missing" ]]; then
    gate_pass "commits-trailered (range $range)"
  else
    gate_fail "commits-trailered" \
      "Commit(s) on this branch lack a 'Refs/Closes/Fixes/Resolves' trailer:
$(printf "$missing" | sed 's/^/  /')
Amend each commit (with HOMEBASE_WORK_AUTHORIZED=1) to add a trailer line
referencing $issue."
  fi
}

# ── Gate 5: closing-keyword-present ───────────────────────────────────────────

gate_closing_keyword() {
  local root; root="$(_gate_repo_root)"
  local issue msg
  issue="$(state_issue "$root")"
  msg="$(git -C "$root" log -1 --pretty=%B 2>/dev/null || true)"

  # Closing-only subset: Closes / Close / Closed / Fixes / Fix / Fixed / Resolves / Resolve / Resolved.
  # (`Refs` is intermediate and does NOT auto-close.)
  if printf '%s' "$msg" | grep -qiE '^(Closes|Close|Closed|Fixes|Fix|Fixed|Resolves|Resolve|Resolved)[[:space:]]+'"$ISSUE_REF_RE"'[[:space:]]*$'; then
    gate_pass "closing-keyword-present"
    return $GATE_OK
  fi

  local subject
  subject="$(printf '%s' "$msg" | head -1)"
  gate_fail "closing-keyword-present" \
    "HEAD commit '$subject' has no closing keyword for $issue.

Append an empty closing commit:

  git commit --allow-empty -m \"\$(cat <<'EOF'
  Closes $issue

  Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
  EOF
  )\"

(The pre-tool hook gates manual git commit; HOMEBASE_WORK_AUTHORIZED=1
is set automatically inside 'homebase work finish --append-closing'
once that flag is implemented.)"
}

# ── Gate 6: changelog-current ─────────────────────────────────────────────────

gate_changelog_current() {
  local root; root="$(_gate_repo_root)"
  local app base_sha
  app="$(state_app "$root")"
  base_sha="$(state_read base_sha "$root")"
  [[ -z "$base_sha" ]] && base_sha="$(git -C "$root" merge-base HEAD origin/main 2>/dev/null || echo "")"
  local range="${base_sha:-HEAD~5}..HEAD"

  local missing=""
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    local subject scope
    subject="$(git -C "$root" log -1 --format=%s "$sha" 2>/dev/null || true)"
    if [[ "$subject" =~ ^(feat|fix)\(([a-zA-Z0-9._-]+)\)!?:[[:space:]] ]]; then
      scope="${BASH_REMATCH[2]}"
      local changelog_path="apps/${scope}/CHANGELOG.md"
      [[ -f "$root/$changelog_path" ]] || continue
      if ! git -C "$root" show --name-only --format= "$sha" 2>/dev/null | grep -Fxq "$changelog_path"; then
        missing+="${sha:0:9} ${subject} (expected $changelog_path)\n"
      fi
    fi
  done < <(git -C "$root" log "$range" --format=%H 2>/dev/null)

  if [[ -z "$missing" ]]; then
    gate_pass "changelog-current"
  else
    gate_fail "changelog-current" \
      "feat()/fix() commit(s) did not stage their app's CHANGELOG:
$(printf "$missing" | sed 's/^/  /')
Edit the CHANGELOG's '## [Unreleased]' section and amend or follow up."
  fi
}

# ── Gate 7: linear-in-progress ────────────────────────────────────────────────

# Validates that the active issue's Linear state matches one of the configured
# in_progress / in_review state-name lists. Read-only — no LINEAR_TPM_AUTHORIZED
# needed. Implementation: shell-out to scripts/roadmap/linear.rb (added in
# Phase 1.4) once that script supports the `issue get` verb. Until then this
# gate prints [skip] noting that the runtime check is deferred to CI.

gate_linear_in_progress() {
  local root; root="$(_gate_repo_root)"
  local issue; issue="$(state_issue "$root")"
  local linear_rb="${root}/scripts/roadmap/linear.rb"
  [[ -L "$linear_rb" ]] || linear_rb="$(readlink "$linear_rb" 2>/dev/null || echo "$linear_rb")"
  if [[ ! -x "$linear_rb" ]]; then
    gate_skip "linear-in-progress" "linear.rb not available; CI re-checks via work-linear-state.yml"
    return $GATE_OK
  fi
  local out
  if ! out="$(ruby "$linear_rb" issue get "$issue" 2>&1)"; then
    gate_fail "linear-in-progress" \
      "Could not read Linear state for $issue: $out

If Linear is unreachable, gate 7 falls back to CI's work-linear-state.yml.
To skip locally and rely on CI, set HOMEBASE_SKIP_LINEAR=1."
    return $GATE_FAIL
  fi
  local current_state
  current_state="$(printf '%s' "$out" | jq -r '.state.name // empty' 2>/dev/null || echo "")"
  if [[ -z "$current_state" ]]; then
    gate_fail "linear-in-progress" \
      "Could not parse Linear state from response.

Response: $out"
    return $GATE_FAIL
  fi
  # The runtime resolution against state_kinds.in_progress / .in_review lives
  # in the orchestrator (finish.sh); gates.sh just reports the current state.
  gate_pass "linear-in-progress (state=$current_state)"
}

# ── Gate 8: validate-passes ───────────────────────────────────────────────────

# Runs the project's required_checks where when=on_finish && blocking=true.
# Reads from the merged effective workflow for the active app. Captures
# output to .homebase/work-finish-<timestamp>.log on failure.

gate_validate_passes() {
  local root; root="$(_gate_repo_root)"
  local app; app="$(state_app "$root")"
  local effective; effective="$(read_effective_workflow_for_app "$app" "$root")" || {
    gate_fail "validate-passes" "Could not load effective workflow for app=$app"
    return $GATE_FAIL
  }
  local checks_json
  checks_json="$(printf '%s' "$effective" | jq -c '
    .required_checks // [] |
    map(select((.when // "on_finish") == "on_finish" and (.blocking // true)))
  ')"
  local count
  count="$(printf '%s' "$checks_json" | jq -r 'length')"
  if [[ "$count" -eq 0 ]]; then
    gate_skip "validate-passes" "no blocking required_checks for app=$app"
    return $GATE_OK
  fi

  # Build the list of changed files in state.base_sha..HEAD once. Used to
  # path-scope individual checks per HMB-15: a check with `paths:` runs only
  # when at least one changed path matches at least one glob.
  local base_sha changed_files
  base_sha="$(state_read base_sha "$root")"
  if [[ -n "$base_sha" ]]; then
    changed_files="$(git -C "$root" diff --name-only "$base_sha"..HEAD 2>/dev/null)"
  else
    changed_files="$(git -C "$root" diff --name-only @{u}..HEAD 2>/dev/null || git -C "$root" log --name-only --format= HEAD~1..HEAD 2>/dev/null)"
  fi

  local log_dir="${root}/.homebase"
  local log_file="${log_dir}/work-finish-$(date -u +%Y%m%dT%H%M%SZ).log"
  mkdir -p "$log_dir"
  : > "$log_file"

  local i=0
  local ran=0
  while [[ "$i" -lt "$count" ]]; do
    local name cmd paths_json
    name="$(printf '%s' "$checks_json" | jq -r ".[$i].name")"
    cmd="$(printf '%s' "$checks_json" | jq -r ".[$i].command")"
    paths_json="$(printf '%s' "$checks_json" | jq -c ".[$i].paths // null")"

    # Path-scope filter: skip the check when paths[] is declared and no
    # changed file matches any glob. When paths[] is absent, always run.
    if [[ "$paths_json" != "null" ]]; then
      local matched=0
      if [[ -n "$changed_files" ]]; then
        local glob_count glob_i
        glob_count="$(printf '%s' "$paths_json" | jq -r 'length')"
        glob_i=0
        while [[ "$glob_i" -lt "$glob_count" ]]; do
          local glob
          glob="$(printf '%s' "$paths_json" | jq -r ".[$glob_i]")"
          # Use a tiny ruby-glob match; bash's [[ == glob ]] doesn't handle
          # ** the way our schema declares it.
          if printf '%s\n' "$changed_files" | ruby -e '
            glob = ARGV[0]
            # gitignore-style: a glob ending in /** means "anything under
            # this directory" (and it should match files, not just dirs).
            # Ruby fnmatch with FNM_PATHNAME treats /** as "directories
            # recursively" only, so the file-level match needs an explicit
            # prefix-match fallback for that common case.
            prefix = glob.end_with?("/**") ? glob.sub(/\/\*\*$/, "/") : nil
            STDIN.each_line do |line|
              path = line.chomp
              next if path.empty?
              exit 0 if prefix && path.start_with?(prefix)
              exit 0 if File.fnmatch?(glob, path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
            end
            exit 1
          ' "$glob" 2>/dev/null; then
            matched=1
            break
          fi
          glob_i=$((glob_i + 1))
        done
      fi
      if [[ "$matched" -eq 0 ]]; then
        printf '  [skip] %s — paths %s do not match diff\n' "$name" "$paths_json"
        i=$((i + 1))
        continue
      fi
    fi

    printf '  [run]  %s — %s\n' "$name" "$cmd"
    ran=$((ran + 1))
    # Subshell (parentheses, not braces) so the inner `exit` terminates
    # the subshell rather than the script. The outer `local rc=$?`
    # captures the subshell's exit so gate_fail / allowlist consultation
    # can proceed. Pre-HMB-45 this was `{ … }` and `exit` killed the
    # whole script silently (the gate_fail line below was effectively
    # dead code on failure).
    (
      printf '── %s ── %s\n' "$name" "$cmd"
      ( cd "$root" && bash -c "$cmd" )
      local inner_rc=$?
      printf '── exit=%d ──\n' "$inner_rc"
      exit "$inner_rc"
    ) >> "$log_file" 2>&1
    local rc=$?
    if [[ "$rc" -ne 0 ]]; then
      # Allowlist consultation (HMB-45 Finding 3).
      # If `<root>/.homebase/known_main_failures.yml` declares this check_name
      # + a test_id substring matching the log output, demote to a warning
      # rather than failing. Catches the inherited-failure trap (e.g.
      # TFD-1407's VersionTest hardcoded assertion blocking every
      # ShopOS work-finish until the version test is fixed on main).
      # Expired entries hard-fail; CI on main ignores the allowlist (so
      # new failures are still discovered).
      local allowlist="$root/.homebase/known_main_failures.yml"
      local demote_reason=""
      if [[ -f "$allowlist" ]] && command -v ruby >/dev/null 2>&1; then
        demote_reason="$(ruby - <<RUBY 2>/dev/null
require 'yaml'
require 'date'
# Modern Psych is safe-load by default and refuses Date scalars.
# Permit Date/Time so 'expires_at: 2026-06-30' (the canonical schema
# form) parses cleanly. Operator-controlled YAML so unsafe_load would
# also be acceptable; this is just more explicit.
allow = (YAML.load_file('$allowlist', permitted_classes: [Date, Time]) rescue nil)
exit 0 unless allow.is_a?(Hash) && allow['failures'].is_a?(Array)
log = File.read('$log_file') rescue ''
today = Date.today
allow['failures'].each do |entry|
  next unless entry.is_a?(Hash)
  next unless entry['check_name'] == '$name'
  test_id = entry['test_id'].to_s
  next if test_id.empty?
  next unless log.include?(test_id)
  raw_expires = entry['expires_at']
  expires = case raw_expires
            when Date then raw_expires
            when Time then raw_expires.to_date
            else (Date.parse(raw_expires.to_s) rescue nil)
            end
  if expires.nil?
    puts "EXPIRED|invalid expires_at on '#{test_id}' (#{raw_expires.inspect})"
    exit 0
  elsif expires < today
    puts "EXPIRED|allowlist entry for '#{test_id}' expired #{expires}; renew or remove (tracking #{entry['tracking_issue']})."
    exit 0
  else
    puts "DEMOTE|matched allowlist entry: '#{test_id}' (tracking #{entry['tracking_issue']}, expires #{expires}, reason: #{entry['reason']})"
    exit 0
  end
end
RUBY
)"
      fi
      if [[ "$demote_reason" == DEMOTE\|* ]]; then
        printf '  [warn] %s — %s\n' "$name" "${demote_reason#DEMOTE|}" >&2
        i=$((i + 1))
        continue
      elif [[ "$demote_reason" == EXPIRED\|* ]]; then
        gate_fail "validate-passes" \
          "Check '$name' failed AND the matched allowlist entry has expired:
  ${demote_reason#EXPIRED|}

The allowlist is a tactical bridge, not a permanent silencer. Either
renew the entry's expires_at (only after confirming the tracking issue
is still active and resolution genuinely needs more time), or remove
the entry and fix the test on main.

Last 30 lines of $log_file:
$(tail -30 "$log_file")"
        return $GATE_FAIL
      fi
      gate_fail "validate-passes" \
        "Check '$name' failed (exit $rc).

Last 30 lines of $log_file:
$(tail -30 "$log_file")

Fix the failure and rerun 'homebase work finish'.

(If this failure is pre-existing on main, see HMB-45 Finding 3:
.homebase/known_main_failures.yml allowlist with tracking issue +
expiry can demote it to a warning.)"
      return $GATE_FAIL
    fi
    i=$((i + 1))
  done
  if [[ "$ran" -eq 0 ]]; then
    gate_pass "validate-passes (all $count check(s) skipped — none match diff paths)"
  elif [[ "$ran" -lt "$count" ]]; then
    gate_pass "validate-passes ($ran of $count check(s) ran — others skipped on paths)"
  else
    gate_pass "validate-passes ($count check(s))"
  fi
}

# ── Gate 9: ui-verified ───────────────────────────────────────────────────────

# Delegates to the existing ui-verification-check.sh (Stop hook). Reuses,
# does not duplicate. We invoke it with HOMEBASE_WORK_PHASE=finish so the
# Stop hook short-circuits when finish has already verified.

gate_ui_verified() {
  local root; root="$(_gate_repo_root)"
  local hook="${root}/scripts/hooks/ui-verification-check.sh"
  [[ -x "$hook" ]] || hook="$(readlink "$hook" 2>/dev/null || echo "$hook")"
  if [[ ! -f "$hook" ]]; then
    gate_skip "ui-verified" "ui-verification-check.sh not found"
    return $GATE_OK
  fi
  local out rc
  out="$(HOMEBASE_UI_VERIFICATION="${HOMEBASE_UI_VERIFICATION:-strict}" bash "$hook" 2>&1)"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    gate_fail "ui-verified" \
      "UI-touching commit(s) lack a 'Verified ...' trailer:

$out"
    return $GATE_FAIL
  fi

  # Apple-platform stricter mode: when finish_gates.apple_ui_xcuitest_required
  # is true for this app, UI commits that touch Apple-shaped files must carry
  # `Verified by XCUITest:` or `UI verification waived:`. Bare
  # `Verified on simulator:` / `Verified on device:` are supplementary on
  # Apple and do NOT satisfy the gate. See HOMEBASE-SOP-007 § Apple-platform
  # Gate.
  local app; app="$(state_app "$root")"
  if gate_active finish_gates.apple_ui_xcuitest_required "$app"; then
    local base; base="$(state_read base_sha "$root")"
    [[ -z "$base" ]] && base="$(git -C "$root" merge-base HEAD origin/main 2>/dev/null || echo "")"
    [[ -z "$base" ]] && base="HEAD~5"
    local apple_pattern='(View|Screen|Sheet|Cell|Layout)\.swift$|/Views/|/Screens/|/Components/|/UI/'
    local violators=()
    while IFS= read -r sha; do
      [[ -z "$sha" ]] && continue
      local files; files="$(git -C "$root" show --name-only --format= "$sha" 2>/dev/null || true)"
      [[ -z "$files" ]] && continue
      if ! echo "$files" | grep -Eq "$apple_pattern"; then
        continue
      fi
      local msg; msg="$(git -C "$root" log -1 --format=%B "$sha" 2>/dev/null || true)"
      if echo "$msg" | grep -Eiq '^(Verified by XCUITest|UI verification waived|UI verification skipped):'; then
        continue
      fi
      local short subject
      short="$(git -C "$root" rev-parse --short "$sha")"
      subject="$(git -C "$root" log -1 --format=%s "$sha")"
      violators+=("${short} ${subject}")
    done <<< "$(git -C "$root" log "${base}..HEAD" --format=%H 2>/dev/null)"

    if [[ ${#violators[@]} -gt 0 ]]; then
      local listing=""
      local entry
      for entry in "${violators[@]}"; do
        listing+="  ${entry}"$'\n'
      done
      gate_fail "ui-verified" \
        "Apple-platform UI commits must carry 'Verified by XCUITest:' or 'UI verification waived:'
(see HOMEBASE-SOP-007 § Apple-platform Gate). The following commit(s) only
have generic trailers — re-run the relevant XCUITest and amend the trailer:

${listing}
This stricter check is enabled by finish_gates.apple_ui_xcuitest_required
in this project's .homebase/workflow.yml."
      return $GATE_FAIL
    fi
  fi

  gate_pass "ui-verified"
}

# ── Gate 10: landed-to-main ───────────────────────────────────────────────────

# Lands the work directly on main. Solo-operator default (HMB-22): no PR, no
# In-Review limbo. The flow:
#   1. Fetch origin/main, verify it's still the parent we branched from.
#   2. Rebase the work branch onto origin/main (fast-forward of the branch
#      tip — branch must be ahead, not diverged).
#   3. Push HEAD:main (fast-forward only; force-push to main is Charter
#      red-list and stays blocked).
#   4. Delete the branch on origin and locally.
#   5. Switch local back to main and fast-forward.
#
# When the work-state branch IS main (no branch was created at start), the
# rebase + delete steps are skipped — just push origin/main.

gate_landed_to_main() {
  local root; root="$(_gate_repo_root)"
  local branch; branch="$(state_branch "$root")"

  # HMB-129: the pre-push hook reads $WORK_STATE to detect kind=chore and skip
  # the finish closing-keyword requirement. Every push below must carry it, or
  # chore finishes deadlock — pre-push can't see kind=chore and demands a closing
  # keyword for an issueless chore. Resolve the path once and thread it through.
  local state_json; state_json="$(state_path "$root" 2>/dev/null || true)"

  if [[ -z "$branch" ]]; then
    gate_fail "landed-to-main" "work-state has no branch recorded"
    return $GATE_FAIL
  fi

  # Reset the one-shot warn guard so a fresh invocation can emit the warning
  # if it falls back. (Test fixtures may also unset this between cases.)
  unset _GATE_FALLBACK_WARNED

  # 1. Refresh origin/main. Try git first; on failure attempt the gh api
  #    fetch-equivalent (HMB-54). Updates the local refs/remotes/origin/main
  #    so the rebase below resolves either way.
  local remote_main_sha=""
  local fetch_out
  if fetch_out="$(git -C "$root" fetch origin main --quiet 2>&1)"; then
    remote_main_sha="$(git -C "$root" rev-parse origin/main 2>/dev/null || true)"
  else
    _gate_warn_transport_fallback
    if ! remote_main_sha="$(_gate_origin_main_sha_via_api)" || [[ -z "$remote_main_sha" ]]; then
      gate_fail "landed-to-main" \
        "git fetch origin main failed and the gh api fallback also failed
(dual-transport failure):

git: $fetch_out

Restore git or gh transport (check SSH/HTTPS reachability, gh auth status)
and rerun \`homebase work finish\`."
      return $GATE_FAIL
    fi
    # Plant the API-supplied SHA in the local origin/main ref so subsequent
    # rebase/push logic resolves identically. Best-effort: if the underlying
    # commit object isn't present locally the rebase below will surface the
    # real diagnostic.
    git -C "$root" update-ref refs/remotes/origin/main "$remote_main_sha" 2>/dev/null || true
  fi

  # HMB-84: idempotency + hard-rule-8 integrity guard. origin/main is now
  # refreshed above (git fetch, or the gh-api SHA planted into the local ref),
  # so this is an authoritative comparison. If HEAD already sits on origin/main
  # the work has landed — typically a prior finish attempt that pushed
  # successfully but then failed a later gate (the duplicate-gate-11 collision
  # is exactly this shape). Re-verify and short-circuit the heavy
  # rebase/push/cleanup. This is what makes it safe for finish.sh to run gate
  # 11 unmemoized on every attempt: an issue can never reach Linear → Done
  # unless its commit is genuinely on origin/main. On a first attempt HEAD is
  # ahead of (not an ancestor of) origin/main, so this is skipped and the
  # normal land path runs.
  local _landed_head; _landed_head="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
  if [[ -n "$_landed_head" ]] \
      && git -C "$root" merge-base --is-ancestor "$_landed_head" origin/main 2>/dev/null; then
    gate_pass "landed-to-main (HEAD already on origin/main — re-verified, not memoized)"
    return
  fi

  if [[ "$branch" == "main" ]]; then
    # Direct work-on-main: no rebase, no branch cleanup.
    local out rc
    out="$(WORK_STATE="$state_json" HOMEBASE_WORK_AUTHORIZED=1 HOMEBASE_WORK_PHASE=finish git -C "$root" push origin main 2>&1)"
    rc=$?
    if [[ "$rc" -eq 0 ]]; then
      gate_pass "landed-to-main (FF push from main)"
      return
    fi

    # git push failed — try the gh api PATCH fallback if it looks like a
    # transport error rather than a real non-FF rejection. The REST endpoint
    # enforces fast-forward when `force=false`, so an FF violation on git
    # will also fail through the API (with a clear 422).
    _gate_warn_transport_fallback
    local head_sha; head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
    if [[ -z "$head_sha" ]]; then
      gate_fail "landed-to-main" \
        "Push to main failed (exit $rc) and HEAD is unresolvable for gh api fallback:
$out"
      return $GATE_FAIL
    fi
    # Friendlier pre-check: only attempt the PATCH if HEAD descends from the
    # known origin/main SHA. Skipped silently when the API-supplied SHA isn't
    # present locally — the PATCH itself will reject non-FF updates.
    if [[ -n "$remote_main_sha" ]] && git -C "$root" cat-file -e "$remote_main_sha" 2>/dev/null; then
      if ! git -C "$root" merge-base --is-ancestor "$remote_main_sha" "$head_sha" 2>/dev/null; then
        gate_fail "landed-to-main" \
          "Push to main failed (exit $rc) and HEAD is not a descendant of
origin/main ($remote_main_sha) — refusing to attempt the gh api FF-push.

git: $out

If non-fast-forward, run \`git pull --rebase origin main\` then rerun
\`homebase work finish\`."
        return $GATE_FAIL
      fi
    fi
    if _gate_ff_push_main_via_api "$head_sha"; then
      gate_pass "landed-to-main (FF push from main via gh api fallback)"
      return
    fi
    gate_fail "landed-to-main" \
      "Push to main failed (exit $rc) and the gh api PATCH fallback also
failed (dual-transport failure):

git: $out

Restore git or gh transport (check SSH/HTTPS reachability, gh auth status)
and rerun \`homebase work finish\`."
    return $GATE_FAIL
  fi

  # 2. Rebase the branch onto origin/main.
  if ! git -C "$root" rev-parse --verify "$branch" >/dev/null 2>&1; then
    gate_fail "landed-to-main" "branch '$branch' does not exist locally"
    return $GATE_FAIL
  fi

  # Make sure HEAD is on the work branch (finish should already have asserted
  # this in gate-2, but guard for it before rebasing).
  local head; head="$(git -C "$root" rev-parse --abbrev-ref HEAD)"
  if [[ "$head" != "$branch" ]]; then
    gate_fail "landed-to-main" \
      "HEAD is on '$head', expected '$branch'. Switch back before finishing."
    return $GATE_FAIL
  fi

  local rebase_out rebase_rc
  rebase_out="$(git -C "$root" rebase origin/main 2>&1)"
  rebase_rc=$?
  if [[ "$rebase_rc" -ne 0 ]]; then
    # Roll back the partial rebase so the operator's branch is intact.
    git -C "$root" rebase --abort >/dev/null 2>&1 || true
    # If the gh-api fallback supplied a remote_main_sha whose commit object
    # isn't in the local repo, the rebase fails because we never received
    # the objects — surface that as the real problem.
    if [[ -n "$remote_main_sha" ]] \
        && ! git -C "$root" cat-file -e "$remote_main_sha" 2>/dev/null; then
      gate_fail "landed-to-main" \
        "git fetch origin main failed; the gh api fallback supplied
origin/main=$remote_main_sha but its commit objects are not in the local
repository, so rebase cannot proceed.

Restore git transport and rerun \`homebase work finish\`."
      return $GATE_FAIL
    fi
    gate_fail "landed-to-main" \
      "Rebase onto origin/main failed:
$rebase_out

The rebase has been aborted; your branch is unchanged. Resolve the
conflict manually with \`git rebase origin/main\`, push nothing, then
rerun \`homebase work finish\`."
    return $GATE_FAIL
  fi

  # 3. Push HEAD:main (fast-forward; pre-push hook still enforces no
  #    force-push to main without HOMEBASE_FORCE_PUSH_CONFIRMED=1).
  local push_out push_rc
  push_out="$(WORK_STATE="$state_json" HOMEBASE_WORK_AUTHORIZED=1 HOMEBASE_WORK_PHASE=finish git -C "$root" push origin HEAD:main 2>&1)"
  push_rc=$?
  local used_api_push=0
  if [[ "$push_rc" -ne 0 ]]; then
    _gate_warn_transport_fallback
    local head_sha; head_sha="$(git -C "$root" rev-parse HEAD 2>/dev/null)"
    if [[ -z "$head_sha" ]] || ! _gate_ff_push_main_via_api "$head_sha"; then
      gate_fail "landed-to-main" \
        "FF push HEAD:main failed (exit $push_rc) and the gh api PATCH
fallback also failed (dual-transport failure):

git: $push_out

The branch has been rebased onto origin/main locally; restore git or gh
transport (check SSH/HTTPS reachability, gh auth status) and rerun
\`homebase work finish\`."
      return $GATE_FAIL
    fi
    used_api_push=1
  fi

  # 4. Delete the branch on origin (fire-and-forget; remote may already lack
  #    a copy if --no-branch was used at start, hence the soft handling).
  #    When git transport just failed for the push, prefer the gh api delete
  #    so this step doesn't dangle the branch on origin.
  if [[ "$used_api_push" -eq 1 ]]; then
    _gate_delete_branch_via_api "$branch" || true
  else
    WORK_STATE="$state_json" HOMEBASE_WORK_AUTHORIZED=1 HOMEBASE_WORK_PHASE=finish \
      git -C "$root" push origin --delete "$branch" >/dev/null 2>&1 \
      || _gate_delete_branch_via_api "$branch" \
      || true
  fi

  # 5. Local cleanup. Two paths (HMB-36):
  #
  #    - Worktree mode: `$root` IS the worktree, and `main` is already
  #      checked out by the project's main checkout. `git switch main`
  #      from inside the worktree would error ("already checked out at
  #      $project_root"). Instead, refresh main on the project checkout
  #      so it sees the FF-push we just did, and let finish.sh's tail
  #      (worktree_destroy) handle worktree removal + branch ref delete.
  #    - Single-branch mode (legacy): switch the main checkout to main,
  #      fast-forward, delete the local branch. Today's behavior unchanged.
  local pass_suffix=""
  if [[ "$used_api_push" -eq 1 ]]; then
    pass_suffix=" via gh api fallback"
  fi
  # HMB-95: take the no-switch path for ANY linked worktree, not just
  # homebase's own `.worktrees/`. An in-place `--no-branch` start inside a
  # Claude Code `.claude/worktrees/<id>` checkout is a linked worktree where
  # `main` is checked out by the project root — so the legacy `git switch main`
  # below would fail ("already checked out"), abort gate 11, and strand the
  # issue In Progress even though the FF-push already landed. Refresh main on
  # the project checkout instead and let teardown (homebase worktrees) or the
  # Claude session (its own worktrees) dispose of the checkout.
  if in_linked_worktree; then
    local project_root
    project_root="$(worktree_project_root)"
    if [[ -n "$project_root" ]]; then
      git -C "$project_root" pull --ff-only --quiet >/dev/null 2>&1 || true
    fi
    if in_worktree; then
      gate_pass "landed-to-main (rebased $branch onto origin/main, FF-pushed${pass_suffix}; worktree + branch removed at teardown)"
    else
      gate_pass "landed-to-main (rebased $branch onto origin/main, FF-pushed${pass_suffix}; in-place worktree retained — main refreshed on project checkout)"
    fi
    return
  fi

  if ! git -C "$root" switch main >/dev/null 2>&1; then
    gate_fail "landed-to-main" \
      "Push succeeded but couldn't switch local back to main. Run
\`git switch main && git pull --ff-only && git branch -D $branch\`
yourself."
    return $GATE_FAIL
  fi
  git -C "$root" pull --ff-only --quiet >/dev/null 2>&1 || true
  git -C "$root" branch -D "$branch" >/dev/null 2>&1 || true

  gate_pass "landed-to-main (rebased $branch onto origin/main, FF-pushed${pass_suffix}, branch deleted)"
}

# ── Gate 11: pr-opened-or-updated ─────────────────────────────────────────────

# Creates or updates the GitHub PR for the active branch. Requires
# TPM_AUTHORIZED=1 in the calling shell (gh-cli-guard-hook gates `gh`).

gate_pr_exists() {
  local root; root="$(_gate_repo_root)"
  local branch issue
  branch="$(state_branch "$root")"
  issue="$(state_issue "$root")"
  if [[ "${TPM_AUTHORIZED:-0}" != "1" ]]; then
    gate_fail "pr-opened-or-updated" \
      "TPM_AUTHORIZED=1 not set in the calling shell.
'homebase work finish' must run from a context where the technical-project-manager
agent (or operator) has authorised gh CLI access for this batch."
    return $GATE_FAIL
  fi

  # Check if a PR already exists for this branch.
  local existing
  existing="$(gh pr list --head "$branch" --json number,body --jq '.[0]' 2>/dev/null || echo "")"
  if [[ -n "$existing" && "$existing" != "null" ]]; then
    local body num
    num="$(printf '%s' "$existing" | jq -r '.number')"
    body="$(printf '%s' "$existing" | jq -r '.body // ""')"
    if printf '%s' "$body" | grep -qE "(Closes|Fixes|Resolves)[[:space:]]+${issue}\\b"; then
      gate_pass "pr-opened-or-updated (existing #${num})"
      printf '%s' "$num" > "${root}/.homebase/.pr-number"
      return $GATE_OK
    else
      gate_fail "pr-opened-or-updated" \
        "PR #$num exists but its body does not contain 'Closes $issue'.

Update the PR body to include 'Closes $issue' on its own line."
      return $GATE_FAIL
    fi
  fi

  # Create a new PR.
  local subject body_file
  subject="$(git -C "$root" log -1 --format=%s)"
  body_file="$(mktemp)"
  cat > "$body_file" <<EOF
## Summary

(generated by \`homebase work finish\`)

## Test plan

- See work-finish log: \`.homebase/work-finish-*.log\`

Closes $issue
EOF
  local out rc
  out="$(gh pr create --title "$subject" --body-file "$body_file" --head "$branch" 2>&1)"
  rc=$?
  rm -f "$body_file"
  if [[ "$rc" -eq 0 ]]; then
    local url; url="$(printf '%s' "$out" | grep -Eo 'https?://[^[:space:]]+' | head -1)"
    gate_pass "pr-opened-or-updated (new) — $url"
  else
    gate_fail "pr-opened-or-updated" \
      "gh pr create failed (exit $rc):
$out"
  fi
}

# ── Gate 12: linear-transitioned ──────────────────────────────────────────────

# Moves the active issue's Linear state to in_review (default) or done (--ship).
# Requires LINEAR_TPM_AUTHORIZED=1 in the calling shell. Reads target kind
# from finish.sh (passed via the FINISH_TARGET_KIND env var, default in_review).

gate_linear_transitioned() {
  local root; root="$(_gate_repo_root)"
  local issue; issue="$(state_issue "$root")"
  local target="${FINISH_TARGET_KIND:-in_review}"

  if [[ "${LINEAR_TPM_AUTHORIZED:-0}" != "1" ]]; then
    gate_fail "linear-transitioned" \
      "LINEAR_TPM_AUTHORIZED=1 not set. The Linear state move is gated by
HOMEBASE-SOP-013. Run 'homebase work finish' from a TPM-authorised shell."
    return $GATE_FAIL
  fi

  local linear_rb="${root}/scripts/roadmap/linear.rb"
  if [[ ! -x "$linear_rb" ]]; then
    gate_skip "linear-transitioned" "linear.rb not available"
    return $GATE_OK
  fi

  # Resolve target state-name from workflow.yml.
  local app; app="$(state_app "$root")"
  local effective; effective="$(read_effective_workflow_for_app "$app" "$root")"
  local candidates
  candidates="$(printf '%s' "$effective" | jq -r ".linear.state_kinds.${target} // [] | .[]")"
  if [[ -z "$candidates" ]]; then
    gate_fail "linear-transitioned" \
      "workflow.yml has no linear.state_kinds.${target} entries for app=$app"
    return $GATE_FAIL
  fi

  # Try each candidate name until linear.rb accepts one.
  local moved_to=""
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    if ruby "$linear_rb" issue move "$issue" "$name" >/dev/null 2>&1; then
      moved_to="$name"
      break
    fi
  done <<< "$candidates"

  if [[ -n "$moved_to" ]]; then
    state_set linear_state_now "$moved_to" "$root"
    gate_pass "linear-transitioned ($issue → $moved_to)"
  else
    gate_fail "linear-transitioned" \
      "None of these state names match the team's Linear states: $candidates

Update workflow.yml linear.state_kinds.$target with a name from:
  ruby $linear_rb issue states $issue"
  fi
}

# ── Gate 13: state-finalised ──────────────────────────────────────────────────

gate_state_finalised() {
  local root; root="$(_gate_repo_root)"
  local outcome="${FINISH_OUTCOME:-in_review}"
  local pr=""
  [[ -f "${root}/.homebase/.pr-number" ]] && pr="$(cat "${root}/.homebase/.pr-number")"
  local last_commit
  last_commit="$(git -C "$root" rev-parse HEAD 2>/dev/null || echo "")"
  state_finalize "$outcome" --pr "$pr" --last-commit "$last_commit" --root "$root"
  rm -f "${root}/.homebase/.pr-number"
  gate_pass "state-finalised (outcome=$outcome)"
}
