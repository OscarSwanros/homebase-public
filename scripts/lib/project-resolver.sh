#!/usr/bin/env bash
# scripts/lib/project-resolver.sh — app slug → project path resolution.
#
# Inverse of `scripts/lib/workflow-loader.sh app_slug_for_path`: given an
# app slug (e.g. "shopos", "studio-web", "gascalc"), walk
# `registry/projects.paths` and each project's `.homebase/project.yml` to
# return the owning project's absolute path.
#
# Used by `scripts/work/start.sh` (HMB-45 Finding 7) to refuse cwd-misroutes
# at start time — when the issue's Linear `app` field resolves to a project
# whose path isn't an ancestor of the current cwd, abort before any
# side-effects (no worktree, no Linear transition, no work-state.json).
#
# Design constraints:
#   - Read-only. Never writes.
#   - Pure stdlib bash + standard tools (grep, sed). No yq/ruby — keeps
#     the dependency surface minimal so this works during start preflight.
#   - Project-agnostic. Walks registry/projects.paths verbatim and consults
#     each project's project.yml; no hardcoded project names or app slugs.
#
# Canonical source: ~/code/homebase/scripts/lib/project-resolver.sh
# Symlinked into each homebase-adopting project by `bin/homebase link-project`.
# Do not edit copies.

# Idempotent source guard.
[[ -n "${_PROJECT_RESOLVER_SOURCED:-}" ]] && return 0
_PROJECT_RESOLVER_SOURCED=1

# Resolve homebase root. The registry lives at ~/code/homebase/registry/
# regardless of which project we're called from.
_pr_homebase_root() {
  if [[ -n "${HOMEBASE_ROOT:-}" && -d "$HOMEBASE_ROOT/registry" ]]; then
    echo "$HOMEBASE_ROOT"
    return 0
  fi
  # Default: derive from this script's path. Symlink-aware: this file may
  # be a symlink into a project, but BASH_SOURCE returns the resolved path
  # only if we go through the worktree's symlink resolution.
  local self
  self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  # We're at <homebase>/scripts/lib/. Walk up two levels.
  cd "$self/../.." && pwd -P
}

# app_to_project_path <app-slug>
#   Echoes the absolute path of the project that owns <app-slug> and
#   exits 0. If no match, echoes nothing and exits 1.
#
# Walks registry/projects.paths line by line. Each line is the absolute
# path of a registered project. For each path, reads
# <path>/.homebase/project.yml and matches `apps[].name` (case-sensitive)
# against the requested slug. The first match wins (registries don't
# allow duplicate app names — guaranteed by `bin/homebase index`).
app_to_project_path() {
  local slug="${1:-}"
  [[ -z "$slug" ]] && return 1

  local hb_root paths_file
  hb_root="$(_pr_homebase_root)"
  paths_file="$hb_root/registry/projects.paths"
  [[ -f "$paths_file" ]] || return 1

  local proj_path
  while IFS= read -r proj_path; do
    [[ -z "$proj_path" ]] && continue
    [[ "$proj_path" == \#* ]] && continue
    # Expand ~ if present (registry stores absolute paths but be defensive).
    proj_path="${proj_path/#\~/$HOME}"
    local project_yml="$proj_path/.homebase/project.yml"
    [[ -f "$project_yml" ]] || continue
    # Match `name: <slug>` lines under `apps:`. The yml is structured as:
    #   apps:
    #     - name: foo
    #       path: ...
    #     - name: bar
    # We grep for `- name: <slug>` (with optional whitespace).
    if grep -Eq "^[[:space:]]*-?[[:space:]]*name:[[:space:]]*${slug}[[:space:]]*$" "$project_yml"; then
      # Confirm the match is in the apps[] block, not another top-level
      # `name:` field. A two-step approach: extract the apps: section and
      # search within it.
      local apps_block
      apps_block="$(awk '
        /^apps:[[:space:]]*$/ { in_apps=1; next }
        /^[a-zA-Z_]/ && !/^[[:space:]]/ { in_apps=0 }
        in_apps { print }
      ' "$project_yml")"
      if printf '%s\n' "$apps_block" | grep -Eq "^[[:space:]]*-?[[:space:]]*name:[[:space:]]*${slug}[[:space:]]*$"; then
        echo "$proj_path"
        return 0
      fi
    fi
  done < "$paths_file"

  return 1
}

# linear_project_name_to_project_path <linear-project-name>
#   Same as app_to_project_path, but matches against the Linear Project
#   name displayed on the issue (e.g. "ShopOS") rather than an app
#   slug. Performs the same normalisation as scripts/work/start.sh's
#   existing matching code (lowercase, whitespace → underscore).
#
# Returns 0 with the project path on stdout when found; 1 with empty
# stdout otherwise.
linear_project_name_to_project_path() {
  local target="${1:-}"
  [[ -z "$target" ]] && return 1
  # Normalise: lowercase, spaces → underscores. Mirrors the inline norm()
  # in start.sh so behaviour stays consistent.
  local norm_target
  norm_target="$(printf '%s' "$target" | tr '[:upper:] ' '[:lower:]_')"

  local hb_root paths_file
  hb_root="$(_pr_homebase_root)"
  paths_file="$hb_root/registry/projects.paths"
  [[ -f "$paths_file" ]] || return 1

  local proj_path
  while IFS= read -r proj_path; do
    [[ -z "$proj_path" ]] && continue
    [[ "$proj_path" == \#* ]] && continue
    proj_path="${proj_path/#\~/$HOME}"
    local project_yml="$proj_path/.homebase/project.yml"
    [[ -f "$project_yml" ]] || continue
    # Extract apps[] block, then check whether any name (lowercased) matches.
    local apps_block
    apps_block="$(awk '
      /^apps:[[:space:]]*$/ { in_apps=1; next }
      /^[a-zA-Z_]/ && !/^[[:space:]]/ { in_apps=0 }
      in_apps { print }
    ' "$project_yml")"
    local match
    match="$(printf '%s\n' "$apps_block" \
      | grep -E '^[[:space:]]*-?[[:space:]]*name:[[:space:]]*' \
      | sed -E 's/^[[:space:]]*-?[[:space:]]*name:[[:space:]]*//; s/[[:space:]]+$//' \
      | tr '[:upper:] ' '[:lower:]_' \
      | grep -Fxq "$norm_target" && echo y || true)"
    if [[ "$match" == "y" ]]; then
      echo "$proj_path"
      return 0
    fi
  done < "$paths_file"

  return 1
}

# cwd_in_project_path <project-path>
#   Returns 0 iff the current working directory (resolved through symlinks)
#   is equal to or a descendant of <project-path> (also resolved through
#   symlinks). Used by start.sh's cwd-misroute gate.
#
# Symlink resolution matters because homebase worktrees live inside the
# project's main checkout (e.g. ~/code/homebase/.worktrees/homebase/...)
# and pwd -P canonicalises symlinks; we want the gate to consider a
# worktree as "inside its parent project."
cwd_in_project_path() {
  local proj_path="${1:-}"
  [[ -z "$proj_path" ]] && return 1
  proj_path="${proj_path/#\~/$HOME}"
  [[ -d "$proj_path" ]] || return 1

  local cwd_canon proj_canon
  cwd_canon="$(pwd -P)"
  proj_canon="$(cd "$proj_path" && pwd -P)" || return 1

  # Equality or proper-prefix-with-slash. Avoid false-positive on
  # `/foo` matching `/foobar` by requiring the prefix end at a path
  # boundary.
  if [[ "$cwd_canon" == "$proj_canon" ]]; then
    return 0
  fi
  if [[ "$cwd_canon" == "$proj_canon/"* ]]; then
    return 0
  fi
  return 1
}
