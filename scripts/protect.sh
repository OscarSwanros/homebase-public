#!/usr/bin/env bash
# scripts/protect.sh — assert GitHub branch protection on `main` against
# the canonical shape required by the workflow contract.
#
# Usage:
#   homebase protect <project-path> [--check | --apply]
#     --check   (default) report drift; exit 1 on drift, 0 if aligned.
#     --apply   write the canonical protection via `gh api` (TPM only).
#
# Reads:
#   <project>/.homebase/project.yml — for each apps[].github (owner/repo),
#   asserts protection on the repo's `main` branch.
#
# Canonical protection shape (matching standards/WORKFLOW_CONTRACT.md
# § Layer 5 — CI):
#   - required_linear_history: true
#   - allow_force_pushes: false
#   - allow_deletions: false
#   - required_status_checks: required only when at least one canonical CI
#     workflow is wired in the project. The list of contexts is read from
#     each project's existing GitHub Actions workflow files (see
#     `discover_contexts` below), not hardcoded — homebase's reusable
#     workflows have project-specific job names.
#
# Authorisation:
#   --check is read-only via the gh API and does not require TPM_AUTHORIZED=1
#     (gh-cli-guard hook still enforces the authorisation).
#   --apply requires TPM_AUTHORIZED=1.
#
# Exit codes:
#   0 — aligned (or applied successfully)
#   1 — drift detected (--check)
#   2 — bad argv, missing project.yml, gh failure, no github repos to check

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/workflow-loader.sh
. "${WORK_DIR}/lib/workflow-loader.sh"

usage() {
  cat <<EOF
usage: homebase protect <project-path> [--check | --apply]

Assert GitHub branch protection on \`main\` for every app in
<project-path>/.homebase/project.yml that declares \`github: owner/repo\`.

  --check   (default) Report drift between live protection and the
            canonical shape. Exit 1 on drift, 0 if aligned.
  --apply   Write the canonical protection via \`gh api\`. Requires
            TPM_AUTHORIZED=1 in the calling shell.

Canonical protection asserted (matching WORKFLOW_CONTRACT.md § Layer 5):
  - required_linear_history: true
  - allow_force_pushes: false
  - allow_deletions: false
  - required_status_checks: list of CI contexts inferred from the
    project's .github/workflows/ files (canonical homebase reusable
    workflows: validate-docs, commit-sop-check, render-claudemd-drift,
    work-finish-validate, work-linear-state, work-state-integrity).
EOF
}

PROJECT=""
MODE="check"
while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check)   MODE="check"; shift ;;
    --apply)   MODE="apply"; shift ;;
    -*)        echo "protect: unknown flag $1" >&2; usage; exit 2 ;;
    *)
      if [[ -z "$PROJECT" ]]; then PROJECT="$1"; shift
      else echo "protect: extra positional '$1'" >&2; usage; exit 2
      fi
      ;;
  esac
done

[[ -z "$PROJECT" ]] && { echo "protect: project-path required" >&2; usage; exit 2; }
PROJECT="$(cd "$PROJECT" 2>/dev/null && pwd -P)" || { echo "protect: not a directory" >&2; exit 2; }

PROJECT_YML="$PROJECT/.homebase/project.yml"
[[ -f "$PROJECT_YML" ]] || { echo "protect: $PROJECT_YML not found" >&2; exit 2; }

# Inspect the project's CI workflows to discover the contexts we should
# require. We don't hardcode a list because each project wires its own
# subset of homebase reusable workflows.
discover_contexts() {
  local proj="$1"
  local workflows_dir="$proj/.github/workflows"
  [[ -d "$workflows_dir" ]] || return 0
  # Workflow `name:` field becomes the GitHub status-check context. Strip
  # surrounding quotes (YAML allows `name: "Foo"` or `name: 'Foo'`); the
  # GitHub status-check API uses the unquoted form.
  while IFS= read -r f; do
    awk '/^name:/ {
      sub(/^name:[[:space:]]+/, "");
      sub(/^"/, ""); sub(/"$/, "");
      sub(/^'\''/, ""); sub(/'\''$/, "");
      print; exit
    }' "$f" 2>/dev/null
  done < <(find "$workflows_dir" -maxdepth 1 -type f \( -name "*.yml" -o -name "*.yaml" \) | sort)
}

# Build the canonical protection JSON for the project's main branch.
canonical_json() {
  local proj="$1"
  local contexts_csv contexts_json
  contexts_csv="$(discover_contexts "$proj" | sort -u | paste -sd, -)"
  if [[ -n "$contexts_csv" ]]; then
    contexts_json="$(printf '%s\n' "$contexts_csv" | jq -Rc 'split(",") | map(select(length > 0))')"
  else
    contexts_json='[]'
  fi
  jq -n --argjson contexts "$contexts_json" '
    {
      required_status_checks: (
        if ($contexts | length) > 0 then
          { strict: true, contexts: $contexts }
        else
          null
        end
      ),
      enforce_admins: false,
      required_pull_request_reviews: null,
      restrictions: null,
      required_linear_history: true,
      allow_force_pushes: false,
      allow_deletions: false
    }
  '
}

# Run the protection assertion for one repo. Returns 0 on aligned, 1 on drift.
assert_repo() {
  local owner_repo="$1" mode="$2" canonical="$3"
  local owner repo
  owner="${owner_repo%%/*}"
  repo="${owner_repo##*/}"

  echo "  ${owner_repo}:"

  local current
  if ! current="$(gh api "repos/${owner_repo}/branches/main/protection" 2>&1)"; then
    if echo "$current" | grep -q "Branch not protected"; then
      echo "    [drift] no protection set"
      [[ "$mode" == "apply" ]] && return 0  # caller applies below
      return 1
    fi
    echo "    [error] gh api failed: $(echo "$current" | head -1)" >&2
    return 2
  fi

  # Compare the fields we care about. Live JSON has more fields than canonical;
  # we only check the ones we assert.
  local fields=(required_linear_history allow_force_pushes allow_deletions enforce_admins)
  local drift=0
  for field in "${fields[@]}"; do
    local live want
    live="$(printf '%s' "$current" | jq -c ".${field} // null | (.enabled // .)")"
    want="$(printf '%s' "$canonical" | jq -c ".${field}")"
    if [[ "$live" != "$want" ]]; then
      echo "    [drift] ${field}: live=${live} canonical=${want}"
      drift=1
    fi
  done

  # Status-checks comparison: canonical's contexts must be a subset of live's.
  local canonical_ctx live_ctx
  canonical_ctx="$(printf '%s' "$canonical" | jq -c '.required_status_checks.contexts // []')"
  live_ctx="$(printf '%s' "$current" | jq -c '.required_status_checks.contexts // []')"
  if [[ "$canonical_ctx" != "[]" ]]; then
    local missing
    missing="$(jq -n --argjson c "$canonical_ctx" --argjson l "$live_ctx" '$c - $l')"
    if [[ "$missing" != "[]" ]]; then
      echo "    [drift] required_status_checks.contexts missing: $missing"
      drift=1
    fi
  fi

  if [[ "$drift" -eq 0 ]]; then
    echo "    [ok] aligned"
    return 0
  fi
  return 1
}

apply_repo() {
  local owner_repo="$1" canonical="$2"
  if [[ "${TPM_AUTHORIZED:-0}" != "1" ]]; then
    echo "    [fail] TPM_AUTHORIZED=1 required for --apply" >&2
    return 2
  fi
  echo "    [apply] writing canonical protection..."
  if gh api -X PUT "repos/${owner_repo}/branches/main/protection" --input - <<<"$canonical" >/dev/null 2>&1; then
    echo "    [ok] applied"
    return 0
  fi
  echo "    [fail] gh api PUT failed" >&2
  return 2
}

# ── Main ──────────────────────────────────────────────────────────────────────

require_jq || exit 2
command -v gh >/dev/null 2>&1 || { echo "protect: gh CLI required" >&2; exit 2; }

# Collect the github: owner/repo entries from project.yml.
PROJECT_JSON="$(read_project_yml_as_json "$PROJECT")" || exit 2
REPOS=()
while IFS= read -r repo; do
  [[ -z "$repo" ]] && continue
  REPOS+=("$repo")
done < <(printf '%s' "$PROJECT_JSON" | jq -r '(.apps // []) | map(.github // empty) | unique | .[]')

# Fall back to the project's git remote (origin) when no apps[].github is
# declared. Monorepos with one GitHub repo for all apps don't always set
# the per-app field; the remote URL is the unambiguous truth.
if [[ "${#REPOS[@]:-0}" -eq 0 ]]; then
  if [[ -d "$PROJECT/.git" ]] && command -v git >/dev/null 2>&1; then
    remote_url="$(git -C "$PROJECT" remote get-url origin 2>/dev/null || echo "")"
    if [[ -n "$remote_url" ]]; then
      # Match git@github.com:owner/repo(.git)? or https://github.com/owner/repo(.git)?
      if [[ "$remote_url" =~ github\.com[/:]([^/]+/[^/.[:space:]]+)(\.git)?/?$ ]]; then
        repo="${BASH_REMATCH[1]}"
        echo "protect: no apps[].github in $PROJECT_YML; using origin remote → $repo"
        REPOS+=("$repo")
      fi
    fi
  fi
fi

if [[ "${#REPOS[@]:-0}" -eq 0 ]]; then
  echo "protect: no apps[].github declared in $PROJECT_YML and no GitHub remote on origin; nothing to check"
  exit 0
fi

CANONICAL="$(canonical_json "$PROJECT")"
echo "homebase protect $PROJECT — mode=$MODE"
echo "─────────────────────────────────────────────────────────"
echo "canonical contexts: $(printf '%s' "$CANONICAL" | jq -r '.required_status_checks.contexts // []')"
echo

OVERALL_DRIFT=0
for repo in "${REPOS[@]:-}"; do
  [[ -z "$repo" ]] && continue
  case "$MODE" in
    check)
      assert_repo "$repo" check "$CANONICAL" || OVERALL_DRIFT=1
      ;;
    apply)
      if ! assert_repo "$repo" apply "$CANONICAL"; then
        apply_repo "$repo" "$CANONICAL" || OVERALL_DRIFT=1
      fi
      ;;
  esac
  echo
done

echo "─────────────────────────────────────────────────────────"
if [[ "$OVERALL_DRIFT" -eq 1 ]]; then
  if [[ "$MODE" == "check" ]]; then
    echo "drift detected. Run 'bin/homebase protect $PROJECT --apply' (TPM_AUTHORIZED=1) to fix."
    exit 1
  else
    echo "apply incomplete; review failures above."
    exit 1
  fi
fi
echo "ok: protection aligned across ${#REPOS[@]} repo(s)"
exit 0
