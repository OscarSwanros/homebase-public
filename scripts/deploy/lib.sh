#!/usr/bin/env bash
# lib.sh — phase helpers for homebase deploy/rollback.
# Sourced by deploy.sh and rollback.sh. Do not execute directly.

# Intentionally no `set -e` here; callers set their own.

DEPLOY_PHASE="${DEPLOY_PHASE:-init}"

if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 2 ]]; then
  C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_BOLD="" C_RESET=""
else
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BLUE=$'\033[0;34m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
fi

log()   { echo "${C_BOLD}[${DEPLOY_PHASE}]${C_RESET} $*" >&2; }
err()   { echo "${C_RED}[${DEPLOY_PHASE}] error:${C_RESET} $*" >&2; }
warn()  { echo "${C_YELLOW}[${DEPLOY_PHASE}] warn:${C_RESET}  $*" >&2; }
info()  { echo "${C_BLUE}[${DEPLOY_PHASE}] info:${C_RESET}  $*" >&2; }
ok()    { echo "${C_GREEN}[${DEPLOY_PHASE}] ok:${C_RESET}    $*" >&2; }

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || { err "missing required command: $cmd"; return 1; }
}

# tag_exists <tag>: exits 0 if the tag is present locally, non-zero otherwise.
tag_exists() {
  git rev-parse -q --verify "refs/tags/$1" >/dev/null
}

# retry_health <url> [retries=10] [sleep_seconds=3]
retry_health() {
  local url="$1" retries="${2:-10}" sleep_s="${3:-3}"
  if [[ -z "$url" ]]; then
    info "no health_url declared — skipping"
    return 0
  fi
  require_cmd curl || return 1
  local i=0
  while [[ $i -lt $retries ]]; do
    if curl --fail --silent --output /dev/null --max-time 10 "$url"; then
      ok "health check $url passed (attempt $((i + 1)))"
      return 0
    fi
    i=$((i + 1))
    [[ $i -lt $retries ]] && sleep "$sleep_s"
  done
  err "health check $url failed after $retries attempts"
  return 1
}

# compute_next_version <current> <bump>: prints next SemVer. bump in {patch, minor, major}.
compute_next_version() {
  ruby -e '
    current = ARGV[0].split(/[.-]/, 4)
    major, minor, patch = current[0..2].map(&:to_i)
    case ARGV[1]
    when "major" then major += 1; minor = 0; patch = 0
    when "minor" then minor += 1; patch = 0
    when "patch" then patch += 1
    else abort "invalid bump: #{ARGV[1]}"
    end
    puts "#{major}.#{minor}.#{patch}"
  ' "$1" "$2"
}

# assert_version_increases <current> <new>: non-zero if new <= current.
assert_version_increases() {
  ruby -e '
    current = ARGV[0].split(".").map(&:to_i)
    new_v = ARGV[1].split(/[.-]/)[0..2].map(&:to_i)
    exit 0 if (new_v <=> current) > 0
    warn "version #{ARGV[1]} is not strictly greater than #{ARGV[0]}"
    exit 1
  ' "$1" "$2"
}

# unreleased_has_content <changelog_path>: exits 0 if [Unreleased] has non-blank lines.
unreleased_has_content() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  local answer
  answer=$(awk '
    /^## \[Unreleased\]/ { in_u = 1; next }
    /^## \[/ && in_u    { exit }
    in_u && NF > 0      { found = 1 }
    END { print (found ? "yes" : "no") }
  ' "$path")
  [[ "$answer" == "yes" ]]
}

# changelog_rotate <path> <version> <date>: rewrites `## [Unreleased]` → `## [X.Y.Z] - DATE`.
changelog_rotate() {
  local path="$1" version="$2" date="$3"
  VERSION="$version" DATE="$date" ruby -i -pe 'gsub(/^## \[Unreleased\]$/, "## [" + ENV.fetch("VERSION") + "] - " + ENV.fetch("DATE"))' "$path"
}

# changelog_reopen <path>: inserts empty `## [Unreleased]` above the first existing version heading.
changelog_reopen() {
  local path="$1"
  ruby -e '
    path = ARGV[0]
    lines = File.readlines(path)
    out = []
    inserted = false
    lines.each do |line|
      if !inserted && line.start_with?("## [")
        out << "## [Unreleased]\n\n"
        inserted = true
      end
      out << line
    end
    File.write(path, out.join)
  ' "$path"
}

# push_with_rebase_recovery <branch> [--follow-tags]: pushes <branch> to origin,
# and if the push fails non-fast-forward, fetches origin/<branch>, rebases
# local <branch> onto origin/<branch>, and retries the push exactly once.
#
# HMB-123: the deploy's Phase 11 / Phase 12 pushes can race against a
# concurrent commit on origin (e.g. an operator landed an unrelated
# patch on main while kamal was building the image and running Phase
# 9/health). In that window the container is already deployed, the tag
# is already created locally, but the version-bump commit can't push
# fast-forward. Because the version-bump only touches the CHANGELOG +
# version file, the rebase surface is minimal — recovery is almost
# always conflict-free, so the verb can do it itself instead of
# bouncing out to an off-contract manual dance.
#
# Behaviour:
#   - First attempt: HOMEBASE_WORK_AUTHORIZED=1 git push origin <branch> [--follow-tags].
#     If it succeeds, return 0 (no recovery needed).
#   - If the push fails: classify by inspecting the captured stderr.
#       * "non-fast-forward" / "fetch first" / "Updates were rejected": run
#         `git fetch origin <branch>`, `git rebase origin/<branch>`,
#         then retry the push once.
#       * Any other failure: return 1 (caller surfaces the error).
#   - If `git rebase` reports a conflict, abort the rebase (leaving the
#     working tree clean), print an operator-facing remediation block,
#     and return 2.
#
# The function is intentionally idempotent on the success path and
# fail-fast on the conflict path — a release that hits a CHANGELOG /
# version-file conflict deserves an operator's eyes, not an automated
# resolver.
push_with_rebase_recovery() {
  local branch="$1"; shift
  # Capture extra flags (e.g. --follow-tags) into an array. Use the
  # `${var[@]+"${var[@]}"}` guard everywhere we expand it — bash 3.2
  # (macOS default) errors out under `set -u` when expanding an empty
  # array.
  local push_flags=()
  if [[ $# -gt 0 ]]; then
    push_flags=("$@")
  fi
  local push_stderr first_rc

  # First attempt. Capture stderr so we can classify failure modes without
  # leaking duplicate output to the operator (the err() call below echoes
  # the captured stderr verbatim when classification falls through).
  push_stderr="$(HOMEBASE_WORK_AUTHORIZED=1 git push origin "$branch" ${push_flags[@]+"${push_flags[@]}"} 2>&1 >/dev/null)"
  first_rc=$?
  if [[ $first_rc -eq 0 ]]; then
    return 0
  fi

  # Classify: non-fast-forward is the only mode we know how to recover.
  # Tolerate the multiple phrasings git ships across versions.
  if ! echo "$push_stderr" | grep -qE 'non-fast-forward|fetch first|Updates were rejected because|stale info'; then
    echo "$push_stderr" >&2
    return 1
  fi

  warn "push to origin/$branch rejected non-fast-forward — concurrent commit on origin (HMB-123)"
  info "fetching origin/$branch and rebasing local $branch on top"

  if ! git fetch --quiet origin "$branch"; then
    err "git fetch origin $branch failed during HMB-123 recovery"
    return 1
  fi

  # The release-bump commit touches CHANGELOG + version_file only, so the
  # rebase surface is minimal. If it still conflicts, abort cleanly and
  # surface a remediation block — the operator can rebase by hand and
  # re-run from Phase 11.
  local rebase_stderr rebase_rc
  rebase_stderr="$(git rebase "origin/$branch" 2>&1)"
  rebase_rc=$?
  if [[ $rebase_rc -ne 0 ]]; then
    git rebase --abort >/dev/null 2>&1 || true
    err "HMB-123 recovery: git rebase origin/$branch reported conflict"
    cat >&2 <<EOF

  The deploy succeeded: the new container is running and the local tag
  exists. The version-bump commit collided with a concurrent change on
  origin/$branch in CHANGELOG.md and/or the version file.

  Recover manually:
    1. cd into the project worktree.
    2. git fetch origin $branch
    3. git rebase origin/$branch
       Resolve the conflict (almost certainly in CHANGELOG.md) — keep
       BOTH unreleased sections merged into one [X.Y.Z] block.
    4. HOMEBASE_WORK_AUTHORIZED=1 git push origin $branch ${push_flags[*]:-}
    5. The tag was created locally in Phase 10. If it pushed in the
       first --follow-tags attempt it's already on origin; otherwise:
       HOMEBASE_WORK_AUTHORIZED=1 git push origin --tags

  Rebase output:
$rebase_stderr
EOF
    return 2
  fi

  info "rebase complete — retrying push"
  if ! HOMEBASE_WORK_AUTHORIZED=1 git push origin "$branch" ${push_flags[@]+"${push_flags[@]}"}; then
    err "push to origin/$branch still failed after rebase — manual recovery required"
    return 1
  fi
  ok "push succeeded after HMB-123 rebase recovery"
  return 0
}

# resolve_changelog_path <project_root> <app_slug>: prints absolute changelog path.
# Requires <project_root>/.homebase/changelogs.conf to define `resolve_changelog_path`.
resolve_changelog_abs() {
  local project_root="$1" app="$2"
  local conf="$project_root/.homebase/changelogs.conf"
  if [[ ! -f "$conf" ]]; then
    err "no .homebase/changelogs.conf in $project_root — see HOMEBASE-SOP-005"
    return 1
  fi
  # Source in a subshell so the project's function definition doesn't leak.
  local rel
  rel=$( ( set +u; source "$conf"; declare -f resolve_changelog_path >/dev/null || { echo "missing-function" >&2; exit 2; }; resolve_changelog_path "$app" "web" ) )
  if [[ -z "$rel" ]]; then
    err "resolve_changelog_path returned empty for app='$app' platform=web"
    return 1
  fi
  echo "$project_root/$rel"
}
