#!/usr/bin/env bash
# scripts/work/lib/worktree.sh — per-task git worktree helpers (HMB-27).
#
# Sourced by:
#   - scripts/work/start.sh      (creates the worktree on `work start`)
#   - scripts/work/finish.sh     (tears down on successful finish)
#   - scripts/work/cancel.sh     (tears down on cancel)
#   - scripts/work/resume.sh     (locates the worktree by KEY)
#   - scripts/work/goto.sh       (prints the worktree path)
#   - scripts/work/list.sh       (lists active worktrees)
#
# Design (HMB-27):
#   * Per-task worktree at <project>/.worktrees/<branch>/.
#   * Tracked symlinks (.githooks/, .claude/, scripts/hooks/*) propagate
#     into every worktree via git's normal checkout.
#   * Caches in `worktree.share` (vendor/bundle, node_modules, tmp/cache)
#     are symlinked from the main checkout into each new worktree.
#   * Per-worktree DB suffix exported as $WORKTREE_DB_SUFFIX so each
#     `database.yml` can resolve to a unique DB name.
#   * State/env files are written inside the worktree's .homebase/, so
#     each worktree carries its own work-state.json and .work-env.

[[ -n "${_WORK_WORKTREE_SOURCED:-}" ]] && return 0
_WORK_WORKTREE_SOURCED=1

_WORKTREE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../../lib/workflow-loader.sh
. "${_WORKTREE_LIB_DIR}/../../lib/workflow-loader.sh"

# ── Project-level config readers ──────────────────────────────────────────────

# True/false: project.yml has `worktree.enabled: true`.
worktree_enabled() {
  local root="${1:-$(find_repo_root)}"
  [[ -z "$root" ]] && return 1
  local enabled
  enabled="$(read_project_yml_as_json "$root" 2>/dev/null | jq -r '.worktree.enabled // false')"
  [[ "$enabled" == "true" ]]
}

# Print the env-var name the app reads to discover its per-worktree DB
# suffix. Defaults to WORKTREE_DB_SUFFIX.
worktree_db_suffix_env() {
  local root="${1:-$(find_repo_root)}"
  read_project_yml_as_json "$root" 2>/dev/null | jq -r '.worktree.db_suffix_env // "WORKTREE_DB_SUFFIX"'
}

# Print the setup command (empty if unset).
worktree_setup_command() {
  local root="${1:-$(find_repo_root)}"
  read_project_yml_as_json "$root" 2>/dev/null | jq -r '.worktree.setup_command // empty'
}

# Print the teardown command (empty if unset).
worktree_teardown_command() {
  local root="${1:-$(find_repo_root)}"
  read_project_yml_as_json "$root" 2>/dev/null | jq -r '.worktree.teardown_command // empty'
}

# Print the list of repo-relative paths to symlink from the main checkout
# into each new worktree (one per line, empty list = no symlinks).
worktree_share_paths() {
  local root="${1:-$(find_repo_root)}"
  read_project_yml_as_json "$root" 2>/dev/null | jq -r '.worktree.share[]? // empty'
}

# ── Path helpers ──────────────────────────────────────────────────────────────

# Print the conventional worktree path for a given branch in this project.
worktree_path_for_branch() {
  local branch="$1"
  local project_root="${2:-$(worktree_project_root)}"
  [[ -z "$branch" || -z "$project_root" ]] && return 1
  echo "$project_root/.worktrees/$branch"
}

# Print the project's main checkout root (the .git common-dir's parent).
# Works whether invoked from the main checkout or from inside a worktree.
worktree_project_root() {
  local common_dir
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  # `--git-common-dir` returns the absolute path on git 2.x; resolve and
  # walk one level up.
  local abs
  abs="$(cd "$common_dir" 2>/dev/null && pwd -P)" || return 1
  dirname "$abs"
}

# Print the absolute path to .worktrees/ for the given project root.
worktree_dir() {
  local root="${1:-$(worktree_project_root)}"
  [[ -z "$root" ]] && return 1
  echo "$root/.worktrees"
}

# True if the current working directory is inside a worktree under
# .worktrees/ (and not the main checkout itself).
in_worktree() {
  local cwd_root project_root
  cwd_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  project_root="$(worktree_project_root)" || return 1
  [[ "$cwd_root" != "$project_root" ]] && [[ "$cwd_root" == "$project_root/.worktrees/"* ]]
}

# True if the current working directory is inside ANY linked git worktree —
# not just homebase's own `.worktrees/`, but also a Claude Code
# `.claude/worktrees/<id>` checkout or any other `git worktree add` location.
# The discriminator is simply: HEAD's checkout is not the main checkout, so
# `main` is checked out elsewhere (by the project root) and `git switch main`
# from here would fail with "already checked out". (HMB-95)
#
# This is intentionally broader than in_worktree(): gate_landed_to_main keys
# its cleanup-path choice off this, so an in-place `--no-branch` start inside a
# Claude worktree skips the legacy switch-back the same way homebase-worktree
# mode does. in_worktree() stays narrow on purpose — finish.sh's teardown only
# destroys homebase-managed `.worktrees/`, never a Claude session worktree.
in_linked_worktree() {
  local cwd_root project_root
  cwd_root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  project_root="$(worktree_project_root)" || return 1
  [[ "$cwd_root" != "$project_root" ]]
}

# Compute the per-worktree DB suffix from the issue key.
# `HMB-27` -> `_hmb_27`.
worktree_db_suffix_for_issue() {
  local key="$1"
  [[ -z "$key" ]] && return 1
  printf '_%s' "$(echo "$key" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
}

# ── Lifecycle: create / tear down ─────────────────────────────────────────────

# Create a worktree for <branch> at <project>/.worktrees/<branch>/, symlink
# the configured share paths from the main checkout, and ensure .homebase/
# exists. Idempotent: a no-op if the worktree already exists.
#
# Args: <project_root> <branch>
# Stdout: lines describing each step (caller can log).
# Exit: 0 success; non-zero on git-worktree-add failure.
worktree_create() {
  local project_root="$1"
  local branch="$2"
  [[ -z "$project_root" || -z "$branch" ]] && return 2

  local wt
  wt="$(worktree_path_for_branch "$branch" "$project_root")" || return 2

  if [[ ! -d "$wt" ]]; then
    mkdir -p "$(dirname "$wt")"
    # `git worktree add <path> <branch>` checks out an existing branch into
    # a new path. The branch was already created by the upstream caller
    # (start.sh creates the branch on the main checkout first; we only need
    # to materialise a worktree for it here).
    if ! HOMEBASE_WORK_AUTHORIZED=1 git -C "$project_root" worktree add "$wt" "$branch" >/dev/null 2>&1; then
      return 1
    fi
    echo "worktree: created $wt"
  else
    echo "worktree: reusing $wt"
  fi

  # Ensure .homebase/ exists in the worktree (gitignored, not auto-created
  # by `git worktree add`).
  mkdir -p "$wt/.homebase"

  # Symlink shared cache paths from main checkout. Skipped silently when
  # the source path doesn't exist yet (e.g. fresh clone with no
  # vendor/bundle yet — first `bundle install` populates it).
  while IFS= read -r share_path; do
    [[ -z "$share_path" ]] && continue
    local src="$project_root/$share_path"
    local dst="$wt/$share_path"
    [[ -e "$dst" ]] && continue
    [[ ! -e "$src" ]] && continue
    mkdir -p "$(dirname "$dst")"
    ln -s "$src" "$dst" && echo "worktree: linked $share_path → $src"
  done < <(worktree_share_paths "$project_root")

  return 0
}

# Trust mise on a freshly-created worktree path so subsequent `mise`
# invocations from inside the worktree pick up its `.mise.toml` without
# prompting (HMB-45 Finding 6). Without this, the next gate that touches
# a Ruby tool blows up with misleading errors (`ANDROID_HOME unset`,
# `java not found`, `bundle check fails`) — none of which point at the
# real cause.
#
# Idempotent. Silent no-op when:
#   - mise isn't on PATH (works on machines without mise).
#   - the worktree has no `.mise.toml` (no-op against `mise trust` itself).
#   - `mise trust` fails (we never want this to block start).
#
# When MISE_AUTO_INSTALL=1, also runs `mise install` inside the worktree
# to pre-fetch the toolchain. Off by default because install can be slow
# and noisy on fresh machines.
#
# Args: <worktree_path>
worktree_trust_mise() {
  local wt="$1"
  [[ -z "$wt" || ! -d "$wt" ]] && return 0
  command -v mise >/dev/null 2>&1 || return 0
  mise trust "$wt" >/dev/null 2>&1 || true
  if [[ "${MISE_AUTO_INSTALL:-0}" == "1" ]]; then
    ( cd "$wt" && mise install >/dev/null 2>&1 ) || true
  fi
  return 0
}

# Run the worktree.setup_command (if set) inside the given worktree, with
# the per-worktree DB suffix exported.
#
# Args: <worktree_path> <issue_key>
worktree_run_setup() {
  local wt="$1"
  local key="$2"
  local cmd
  cmd="$(worktree_setup_command "$wt")"
  [[ -z "$cmd" ]] && return 0
  local suffix_env suffix
  suffix_env="$(worktree_db_suffix_env "$wt")"
  suffix="$(worktree_db_suffix_for_issue "$key")"
  echo "worktree: running setup_command ($suffix_env=$suffix)"
  ( cd "$wt" && env "$suffix_env=$suffix" bash -c "$cmd" )
}

# Run the worktree.teardown_command (if set) inside the worktree, then
# remove the worktree. Failure to run teardown is logged but does not
# block worktree removal — the operator may have already cleaned up the
# DB by hand.
#
# Args: <worktree_path> <issue_key>
worktree_destroy() {
  local wt="$1"
  local key="$2"
  [[ ! -d "$wt" ]] && return 0

  local cmd suffix_env suffix
  cmd="$(worktree_teardown_command "$wt")"
  if [[ -n "$cmd" ]]; then
    suffix_env="$(worktree_db_suffix_env "$wt")"
    suffix="$(worktree_db_suffix_for_issue "$key")"
    echo "worktree: running teardown_command ($suffix_env=$suffix)"
    ( cd "$wt" && env "$suffix_env=$suffix" bash -c "$cmd" ) || \
      echo "  [warn] teardown_command exited non-zero; continuing with worktree removal"
  fi

  local project_root
  project_root="$(worktree_project_root)" || project_root="$(cd "$wt/../.." && pwd -P)"

  # Capture the branch name BEFORE removing the worktree (the worktree's
  # `.git` file is gone after `worktree remove`).
  local branch_name
  branch_name="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"

  if HOMEBASE_WORK_AUTHORIZED=1 git -C "$project_root" worktree remove --force "$wt" >/dev/null 2>&1; then
    echo "worktree: removed $wt"
  else
    echo "  [warn] git worktree remove failed; clean up by hand"
    return 1
  fi

  # Best-effort branch ref cleanup (HMB-36): now that the worktree is
  # gone, no checkout holds the branch, so the ref can be deleted. `-D`
  # is the right form: the branch's commits already live on origin/main
  # via gate_landed_to_main's FF-push, but locally the project checkout
  # may not yet have pulled the merge, so a non-force `-d` would
  # complain about unmerged commits.
  if [[ -n "$branch_name" && "$branch_name" != "main" && "$branch_name" != "HEAD" ]]; then
    HOMEBASE_WORK_AUTHORIZED=1 git -C "$project_root" branch -D "$branch_name" >/dev/null 2>&1 \
      && echo "worktree: deleted branch $branch_name"
  fi
}

# ── Discovery ─────────────────────────────────────────────────────────────────

# Print one line per active worktree under <project>/.worktrees/:
#   <issue_key>\t<branch>\t<absolute_path>\t<linear_state_or_->
# Sorted by issue key. Skips the main checkout.
#
# HMB-87 B.11: discovery is now driven by the central state-file glob
# `<main>/.homebase/work-state.*.json` (per-worktree state lives there, not
# in each worktree's own tree). For each state file, the branch is read from
# the JSON and cross-referenced against `git worktree list --porcelain` to
# resolve back to the worktree path. State files whose branch is no longer
# present (worktree manually removed without `homebase work cancel/finish`)
# surface as orphan rows with path=<orphan:...> so they're visible rather
# than silently dropped.
worktree_list() {
  local project_root="${1:-$(worktree_project_root)}"
  [[ -z "$project_root" ]] && return 1
  # Canonicalise: macOS resolves /var/folders to /private/var/folders, and
  # `git worktree list --porcelain` always emits the canonical form. Match
  # the same shape on input so the prefix check below survives the
  # /private/ rewrite.
  project_root="$(cd "$project_root" 2>/dev/null && pwd -P)" || return 1

  local state_dir="$project_root/.homebase"
  [[ -d "$state_dir" ]] || return 0

  # Build a branch→worktree-path lookup from `git worktree list --porcelain`.
  # Skip the main checkout and any entries outside the project's .worktrees/.
  local branch_map
  branch_map="$(git -C "$project_root" worktree list --porcelain 2>/dev/null | \
    awk -v root="$project_root" '
      BEGIN { wt=""; br="" }
      /^worktree / { wt=$2 }
      /^branch / { br=$2; sub(/^refs\/heads\//, "", br) }
      /^$/ {
        if (wt != "" && wt != root && index(wt, root "/.worktrees/") == 1) {
          print br "\t" wt
        }
        wt=""; br=""
      }
      END {
        if (wt != "" && wt != root && index(wt, root "/.worktrees/") == 1) {
          print br "\t" wt
        }
      }
    ')"

  # Iterate every SHA-keyed state file at the central location.
  shopt -s nullglob
  local state_file
  for state_file in "$state_dir"/work-state.*.json; do
    # Skip the lock-file sibling (work-state.<sha>.json.lock matches the
    # outer glob if the JSON file is absent; defensive guard).
    [[ "$state_file" == *.lock ]] && continue
    local key="-" branch="-" linear="-" wt="-"
    if command -v jq >/dev/null 2>&1; then
      key="$(jq -r '.issue // "-"' "$state_file" 2>/dev/null || echo "-")"
      branch="$(jq -r '.branch // "-"' "$state_file" 2>/dev/null || echo "-")"
      linear="$(jq -r '.linear_state_now // "-"' "$state_file" 2>/dev/null || echo "-")"
    fi
    # Resolve worktree path from branch_map.
    if [[ -n "$branch_map" && "$branch" != "-" ]]; then
      wt="$(printf '%s\n' "$branch_map" | awk -F'\t' -v b="$branch" '$1 == b { print $2; exit }')"
    fi
    [[ -z "$wt" ]] && wt="<orphan:${state_file##*/}>"
    printf '%s\t%s\t%s\t%s\n' "$key" "$branch" "$wt" "$linear"
  done | sort -k1
  shopt -u nullglob
}

# Resolve an issue key to its worktree path. Walks .worktrees/ and matches
# either by branch-name suffix (BRANCH typically encodes the issue key) or
# by reading the per-worktree work-state.json.
worktree_for_issue() {
  local key="$1"
  local project_root="${2:-$(worktree_project_root)}"
  [[ -z "$key" || -z "$project_root" ]] && return 1

  worktree_list "$project_root" | awk -F'\t' -v k="$key" '$1 == k { print $3; exit }'
}
