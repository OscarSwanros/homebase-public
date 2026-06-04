#!/usr/bin/env bash
# Shared loader for `<project>/.homebase/workflow.yml`. Sourced by hooks and
# `homebase work` verbs. Pure data access — no business logic, no side
# effects beyond stdout / stderr / exit code.
#
# Sourced by (Phase 1+):
#   - bin/homebase (cmd_work dispatch)
#   - scripts/work/{start,checkpoint,finish,status,cancel,resume}.sh
#   - scripts/hooks/work-cli-guard-hook.sh (Phase 3)
#   - scripts/hooks/{session-start,task-created,task-completed}.sh (Phase 3 extensions)
#
# Canonical reference: ~/code/homebase/standards/WORKFLOW_CONTRACT.md.
# Schema: ~/code/homebase/schemas/workflow.schema.json.
#
# This file is symlinked into each homebase-adopting project by
# `bin/homebase link-project`. Do not edit copies.
#
# YAML→JSON conversion uses Ruby's standard library (yaml + json), which is
# already a homebase dependency via scripts/roadmap/linear.rb. Queries use
# jq (Apple-shipped on macOS, brew-installable). No yq dependency.

# Idempotent source guard.
[[ -n "${_WORKFLOW_LOADER_SOURCED:-}" ]] && return 0
_WORKFLOW_LOADER_SOURCED=1

# ── Dependency checks ─────────────────────────────────────────────────────────

require_ruby() {
  command -v ruby >/dev/null 2>&1 || {
    echo "workflow-loader: ruby is required but not found in PATH." >&2
    echo "  Install via mise: 'mise install ruby@3.3' (homebase canon)." >&2
    return 1
  }
}

require_jq() {
  command -v jq >/dev/null 2>&1 || {
    echo "workflow-loader: jq is required but not found in PATH." >&2
    echo "  Install via Homebrew: 'brew install jq'." >&2
    return 1
  }
}

# ── Path resolution ───────────────────────────────────────────────────────────

# Print the absolute path to the project's repo root.
# Returns 1 if not inside a git repo.
find_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

# Print the absolute path to .homebase/workflow.yml for the given project.
# Defaults to the current repo root.
workflow_yml_path() {
  local root="${1:-$(find_repo_root)}"
  [[ -z "$root" ]] && return 1
  echo "$root/.homebase/workflow.yml"
}

# Print the absolute path to .homebase/project.yml for the given project.
project_yml_path() {
  local root="${1:-$(find_repo_root)}"
  [[ -z "$root" ]] && return 1
  echo "$root/.homebase/project.yml"
}

# Print the absolute path to the project's MAIN checkout — the worktree that
# owns the shared .git/ directory. Works from main or any worktree. Returns 1
# if not inside a git repo.
_work_state_main_root() {
  local common
  common="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ -z "$common" ]] && return 1
  # --git-common-dir is relative when invoked from main, absolute from a
  # worktree. Normalise via cd + pwd -P, then dirname to drop the trailing
  # `.git`.
  ( cd "$common" 2>/dev/null && cd .. && pwd -P )
}

# Same as _work_state_main_root, but resolved relative to the given worktree.
_work_state_main_root_for() {
  local wt_root="$1"
  [[ -z "$wt_root" ]] && return 1
  ( cd "$wt_root" 2>/dev/null && _work_state_main_root )
}

# Print the 8-char sha1 of the current worktree's realpath. Used to namespace
# per-worktree state files at the central `<main>/.homebase/` directory.
_work_state_sha() {
  local wt
  wt="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [[ -z "$wt" ]] && return 1
  _work_state_sha_for "$wt"
}

_work_state_sha_for() {
  local wt_root="$1"
  [[ -z "$wt_root" ]] && return 1
  local real
  real="$(cd "$wt_root" 2>/dev/null && pwd -P)" || return 1
  # shasum ships with macOS and is present on Linux util-linux installs.
  printf '%s' "$real" | shasum | cut -c1-8
}

# Print the absolute path to the per-worktree work-state file. State files
# live at the MAIN checkout's `.homebase/` directory, keyed by sha1 of the
# current worktree's realpath: `<main>/.homebase/work-state.<sha8>.json`.
#
# When called without arguments, resolves both `<main>` and `<sha>` from the
# current cwd. When called with an explicit `<root>`, that root is treated as
# the worktree's path and used for both lookups.
#
# Centralised storage gives the operator a single ls-able directory for all
# active sessions, and lets state files outlive `git worktree remove` (the
# Stop hook from HMB-87 B.12 depends on this survivability to distinguish
# empty session-worktrees from in-flight ones).
work_state_path() {
  local root="${1:-}"
  local main_root sha wt_root
  if [[ -n "$root" ]]; then
    main_root="$(_work_state_main_root_for "$root")" || return 1
    sha="$(_work_state_sha_for "$root")" || return 1
    wt_root="$root"
  else
    main_root="$(_work_state_main_root)" || return 1
    sha="$(_work_state_sha)" || return 1
    wt_root="$(git rev-parse --show-toplevel 2>/dev/null)"
  fi
  [[ -z "$main_root" || -z "$sha" ]] && return 1
  local new_path="$main_root/.homebase/work-state.$sha.json"
  _work_state_migrate_legacy "$new_path" "$wt_root"
  echo "$new_path"
}

# Atomically migrate a legacy single-file `<worktree>/.homebase/work-state.json`
# to the new SHA-keyed central location. Called by read-side state helpers
# before they touch the path so in-flight work transitions cleanly.
#
# Semantics: legacy-wins. When the legacy file exists, it always overrides
# whatever is at the SHA-keyed central path (mv replaces). This handles:
#   - Fresh migration: no central file yet; legacy moves to central.
#   - Repeated legacy writes (tests, manual debugging, mid-migration scripts):
#     each write supersedes the previous central content.
# Production code never writes to the legacy path post-HMB-87, so this
# overwrite semantics is moot for normal use. Sibling .lock and audit.log
# move together to keep concurrency safety and audit-trail continuity.
_work_state_migrate_legacy() {
  local new_path="$1"
  local wt_root="${2:-}"
  [[ -z "$new_path" ]] && return 0
  if [[ -z "$wt_root" ]]; then
    wt_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  fi
  [[ -z "$wt_root" ]] && return 0
  local legacy="$wt_root/.homebase/work-state.json"
  [[ ! -f "$legacy" ]] && return 0
  mkdir -p "$(dirname "$new_path")"
  mv -f "$legacy" "$new_path" 2>/dev/null || return 0
  local legacy_lock="$wt_root/.homebase/work-state.json.lock"
  local legacy_audit="$wt_root/.homebase/work-state.audit.log"
  [[ -f "$legacy_lock"  ]] && mv -f "$legacy_lock"  "${new_path}.lock" 2>/dev/null
  [[ -f "$legacy_audit" ]] && mv -f "$legacy_audit" "$(dirname "$new_path")/work-state.audit.log" 2>/dev/null
  return 0
}

# Exit 0 if workflow.yml exists for the given project (or current repo).
workflow_yml_exists() {
  local p
  p="$(workflow_yml_path "$@")" || return 2
  [[ -f "$p" ]]
}

# Exit 0 if a non-finished work-state exists.
work_state_active() {
  local p
  p="$(work_state_path "$@")" || return 2
  [[ -f "$p" ]] || return 1
  require_jq || return 2
  local finished
  finished="$(jq -r '.finished // false' "$p" 2>/dev/null || echo "true")"
  [[ "$finished" == "false" ]]
}

# ── YAML loading ──────────────────────────────────────────────────────────────

# Print the contents of <project>/.homebase/workflow.yml as compact JSON.
# Exits 1 if the file is missing; exits 2 on YAML parse error.
read_workflow_yml_as_json() {
  local root="${1:-$(find_repo_root)}"
  local path
  path="$(workflow_yml_path "$root")" || return 2
  [[ -f "$path" ]] || { echo "workflow-loader: $path not found" >&2; return 1; }
  require_ruby || return 2
  ruby -ryaml -rjson -e '
    begin
      puts JSON.generate(YAML.load_file(ARGV[0]))
    rescue => e
      warn "workflow-loader: failed to parse #{ARGV[0]}: #{e.message}"
      exit 2
    end
  ' "$path"
}

# Print the contents of <project>/.homebase/project.yml as compact JSON.
read_project_yml_as_json() {
  local root="${1:-$(find_repo_root)}"
  local path
  path="$(project_yml_path "$root")" || return 2
  [[ -f "$path" ]] || { echo "workflow-loader: $path not found" >&2; return 1; }
  require_ruby || return 2
  ruby -ryaml -rjson -e '
    begin
      puts JSON.generate(YAML.load_file(ARGV[0]))
    rescue => e
      warn "workflow-loader: failed to parse #{ARGV[0]}: #{e.message}"
      exit 2
    end
  ' "$path"
}

# Print the merged effective workflow JSON for the given app slug.
# Performs the deep-merge-objects-replace-arrays semantics described in
# standards/WORKFLOW_CONTRACT.md § Per-app overrides:
#   - Top-level objects merge with apps[<slug>] overrides.
#   - Nested objects deep-merge.
#   - Arrays REPLACE entirely.
#
# When the app slug is empty, returns the project-level defaults unchanged.
read_effective_workflow_for_app() {
  local app="$1"
  local root="${2:-$(find_repo_root)}"
  require_ruby || return 2
  local wf_path
  wf_path="$(workflow_yml_path "$root")" || return 2
  [[ -f "$wf_path" ]] || { echo "workflow-loader: $wf_path not found" >&2; return 1; }
  ruby -ryaml -rjson -e '
    def deep_merge(a, b)
      return b unless a.is_a?(Hash) && b.is_a?(Hash)
      a.merge(b) do |_, av, bv|
        if av.is_a?(Hash) && bv.is_a?(Hash)
          deep_merge(av, bv)
        else
          bv  # arrays + scalars: replace
        end
      end
    end
    wf = YAML.load_file(ARGV[0])
    app = ARGV[1].to_s
    if app.empty?
      out = wf
    else
      override = (wf["apps"] && wf["apps"][app]) || {}
      base = wf.reject { |k, _| k == "apps" }
      out = deep_merge(base, override)
    end
    puts JSON.generate(out)
  ' "$wf_path" "$app"
}

# ── Query helpers ─────────────────────────────────────────────────────────────

# Exit 0 if the named gate is active for the given app (or project default).
# Usage: gate_active <gate_name> [<app_slug>]
# Gate names follow the schema: e.g., start_gates.tree_must_be_clean,
# finish_gates.last_commit_has_closing_keyword, session_end.require_homebase_work_finish.
gate_active() {
  local gate="$1"
  local app="${2:-}"
  require_jq || return 2
  local effective
  effective="$(read_effective_workflow_for_app "$app")" || return $?
  local val
  val="$(printf '%s' "$effective" | jq -r ".${gate} // null")" || return 2
  [[ "$val" == "true" ]]
}

# Print the list of active hard-rule slugs for the given app, one per line.
hard_rules_active() {
  local app="${1:-}"
  require_jq || return 2
  local effective
  effective="$(read_effective_workflow_for_app "$app")" || return $?
  printf '%s' "$effective" | jq -r '.hard_rules // [] | .[]'
}

# Print the list of mandatory-reviewer agent slugs for an app + change kind,
# one per line. Combines `required_agents.by_platform[<platform>]` (read from
# project.yml's apps[<app>].platforms) with `required_agents.by_change_kind[<kind>]`.
# Path-scoped reviewers are not handled here — that's the CLI's job since it
# needs the staged-path list.
mandatory_agents_for() {
  local app="$1"
  local change_kind="$2"
  require_jq || return 2
  local effective
  effective="$(read_effective_workflow_for_app "$app")" || return $?
  # Resolve platforms from project.yml.
  local project_json platforms
  project_json="$(read_project_yml_as_json)" || return $?
  platforms="$(printf '%s' "$project_json" | \
    jq -r --arg app "$app" '
      (.apps // []) | map(select(.name == $app)) | .[0].platforms // [] | .[]
    ')" || return 2
  {
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      printf '%s' "$effective" | jq -r --arg p "$p" \
        '.required_agents.by_platform[$p] // [] | .[]'
    done <<< "$platforms"
    if [[ -n "$change_kind" ]]; then
      printf '%s' "$effective" | jq -r --arg k "$change_kind" \
        '.required_agents.by_change_kind[$k] // [] | .[]'
    fi
  } | sort -u
}

# Resolve a staged file path to its app slug by matching against the
# `apps[].path` declarations in project.yml. Print the matching slug or
# nothing if no match. The path argument should be relative to the repo root.
app_slug_for_path() {
  local rel_path="$1"
  require_jq || return 2
  local project_json
  project_json="$(read_project_yml_as_json)" || return $?
  printf '%s' "$project_json" | \
    jq -r --arg p "$rel_path" '
      .apps // [] |
      map(. as $a | select(
        $a.path == "." or
        ($p | startswith($a.path + "/"))
      )) |
      sort_by(.path | length) |
      reverse |
      .[0].name // empty
    '
}

# Print the active issue key from .homebase/work-state.json (e.g. HMB-8),
# or nothing if no state.
active_work_issue() {
  local p
  p="$(work_state_path "$@")" || return 2
  [[ -f "$p" ]] || return 1
  require_jq || return 2
  jq -r '.issue // empty' "$p"
}

# Print the active branch name from work-state.json.
active_work_branch() {
  local p
  p="$(work_state_path "$@")" || return 2
  [[ -f "$p" ]] || return 1
  require_jq || return 2
  jq -r '.branch // empty' "$p"
}

# Print the active app slug from work-state.json.
active_work_app() {
  local p
  p="$(work_state_path "$@")" || return 2
  [[ -f "$p" ]] || return 1
  require_jq || return 2
  jq -r '.app // empty' "$p"
}

# Exit 0 if work-state.json shows a finished work cycle (finished_at non-null).
work_state_finished() {
  local p
  p="$(work_state_path "$@")" || return 2
  [[ -f "$p" ]] || return 1
  require_jq || return 2
  local finished
  finished="$(jq -r '.finished // false' "$p" 2>/dev/null || echo "false")"
  [[ "$finished" == "true" ]]
}
