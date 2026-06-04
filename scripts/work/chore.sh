#!/usr/bin/env bash
# scripts/work/chore.sh — `homebase work chore "<desc>" [opts]`.
#
# HMB-86 B.1: materialises a chore-flavoured worktree for off-contract
# governance / canon / SOP / README edits that legitimately don't need a
# Linear issue. The verb mirrors `homebase work start <KEY>` but with:
#
#   - no Linear lookup (chore has no tracked issue)
#   - branch named `chore/<slug>` (slug derived from "<desc>")
#   - work-state JSON marks `kind: chore`, `issue: null`
#   - finish.sh skips Linear + closing-keyword + UI / changelog gates for
#     kind:chore so the operator doesn't have to fight gates that don't
#     apply to chore work
#
# Args:
#   "<desc>"          Required. Free-text description; kebab-case + 40-char
#                     cap drives the slug.
#   --slug <slug>     Override the auto-derived slug (skips the slugify
#                     pass; still validated against the chore/<slug> pattern).
#   -h | --help       Print this usage block.
#
# Materialises a fresh `.worktrees/chore-<slug>/` for off-contract edits that
# don't need a Linear issue. (HMB-109: session-worktree adoption removed with
# Tier-2 — sessions launch in main and chore always creates its own worktree.)

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS_DIR="$(dirname "${WORK_DIR}")"
# shellcheck source=./lib/state.sh
. "${WORK_DIR}/lib/state.sh"
# shellcheck source=./lib/worktree.sh
. "${WORK_DIR}/lib/worktree.sh"

DESC=""
OVERRIDE_SLUG=""

usage() {
  cat <<'EOF'
usage: homebase work chore "<desc>" [--slug <slug>]

Materialise a chore-flavoured worktree for off-contract edits (governance,
canon, SOPs, README typos) that legitimately don't need a Linear issue.

The verb derives a kebab-case slug from "<desc>" (capped at 40 chars),
creates branch `chore/<slug>` and worktree `.worktrees/chore-<slug>/` from
the project's base branch, and writes a kind:chore work-state.

Examples:
  homebase work chore "fix sop-001 typo"
  homebase work chore "refresh registry after add" --slug refresh-registry

Off-contract direct-to-main commits remain available via
HOMEBASE_OFF_CONTRACT=1 for the unfixable cases named in
AGENT_OPERATING_CONTRACT.md rule 6 (debugging the chore verb itself,
fixing a worktree-creation bug, post-incident hot patches).
EOF
}

while (($#)); do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    --slug)      OVERRIDE_SLUG="$2"; shift 2 ;;
    -*)          echo "chore: unknown flag $1" >&2; usage; exit 2 ;;
    *)
      if [[ -z "$DESC" ]]; then DESC="$1"; shift
      else echo "chore: extra positional '$1' — wrap multi-word descriptions in quotes" >&2; usage; exit 2
      fi
      ;;
  esac
done

[[ -z "$DESC" ]] && { echo "chore: <desc> required" >&2; usage; exit 2; }

# ── Slug derivation ──────────────────────────────────────────────────────────
#
# Lowercase, replace non-alnum runs with `-`, strip leading/trailing `-`,
# cap at 40 chars (preserving word boundary by trimming trailing `-`).
# Operator can override entirely via `--slug`.
derive_slug() {
  local s="$1"
  s="$(printf '%s' "$s" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
  s="$(printf '%s' "$s" | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g')"
  s="${s:0:40}"
  s="${s%-}"  # cap-trim might leave a trailing -
  printf '%s' "$s"
}

if [[ -n "$OVERRIDE_SLUG" ]]; then
  SLUG="$OVERRIDE_SLUG"
  if ! printf '%s' "$SLUG" | LC_ALL=C grep -Eq '^[a-z0-9][a-z0-9-]{0,39}[a-z0-9]$|^[a-z0-9]$'; then
    echo "chore: --slug must be kebab-case (a-z0-9 + hyphen, 1-40 chars, no leading/trailing hyphen). got '$SLUG'" >&2
    exit 2
  fi
else
  SLUG="$(derive_slug "$DESC")"
  [[ -z "$SLUG" ]] && { echo "chore: could not derive slug from '$DESC' (only special characters?)" >&2; exit 2; }
fi

BRANCH="chore/$SLUG"

# ── Resolve repo + project root + base branch ────────────────────────────────

ROOT="$(find_repo_root)"
[[ -z "$ROOT" ]] && { echo "chore: not in a git repo" >&2; exit 2; }

workflow_yml_exists "$ROOT" || {
  echo "chore: $(workflow_yml_path "$ROOT") not found" >&2
  echo "       Run 'homebase work init' to scaffold one." >&2
  exit 1
}

PROJECT_ROOT="$ROOT"
if in_worktree; then
  PROJECT_ROOT="$(worktree_project_root)"
fi
[[ -z "$PROJECT_ROOT" ]] && PROJECT_ROOT="$ROOT"

BRANCH_BASE="$(read_effective_workflow_for_app "" "$PROJECT_ROOT" 2>/dev/null | jq -r '.branch.base // "main"')"
[[ -z "$BRANCH_BASE" || "$BRANCH_BASE" == "null" ]] && BRANCH_BASE="main"

# HMB-109: session-worktree adoption (HMB-87 B.12) removed with Tier-2 — no
# session-worktree is ever minted now, so `chore` always creates a fresh
# `.worktrees/chore-<slug>/`.

# ── Banner ────────────────────────────────────────────────────────────────────
divider() { echo "─────────────────────────────────────────────────────────"; }
echo "homebase work chore \"$DESC\""
divider

# Refuse if an active work-state already exists. Operator should finish or
# cancel the prior one before starting another.
if state_active "$ROOT"; then
  cur_issue="$(state_issue "$ROOT")"
  cur_branch="$(state_branch "$ROOT")"
  echo "[fail] active work-state already exists for ${cur_issue:-<chore>} (branch $cur_branch)" >&2
  echo "       Run 'homebase work finish' or 'homebase work cancel' first." >&2
  divider
  exit 1
fi

echo "desc:     $DESC"
echo "slug:     $SLUG"
echo "branch:   $BRANCH"

# ── Branch + worktree materialisation ────────────────────────────────────────

if ! worktree_enabled "$PROJECT_ROOT"; then
  echo "chore: $PROJECT_ROOT's project.yml does not declare worktree.enabled: true" >&2
  echo "       chore work requires worktree mode. Add the block to .homebase/project.yml," >&2
  echo "       or use HOMEBASE_OFF_CONTRACT=1 for direct-to-main chore commits." >&2
  divider
  exit 2
fi

# Refuse if the target branch already exists — adoption can't rename onto a
# live branch, and a fresh worktree shouldn't either (operator may have a
# stale chore branch from a prior aborted attempt).
if git -C "$PROJECT_ROOT" rev-parse --verify "$BRANCH" >/dev/null 2>&1; then
  echo "chore: branch '$BRANCH' already exists." >&2
  echo "       Pick a different slug (--slug <slug>), or 'git branch -D $BRANCH' if it's stale." >&2
  divider
  exit 2
fi

WORKTREE_PATH=""
{
  # Create the branch on the main checkout's refs (without switching it), then
  # materialise a new worktree at .worktrees/chore-<slug>/.
  HOMEBASE_WORK_AUTHORIZED=1 git -C "$PROJECT_ROOT" branch "$BRANCH" "$BRANCH_BASE" >/dev/null
  echo "branch:   created $BRANCH (from $BRANCH_BASE)"
  if ! worktree_create "$PROJECT_ROOT" "$BRANCH"; then
    echo "chore: git worktree add failed for $BRANCH" >&2
    divider
    exit 2
  fi
  WORKTREE_PATH="$(worktree_path_for_branch "$BRANCH" "$PROJECT_ROOT")"
  # Re-root downstream operations into the worktree so state/env writers
  # land at the right SHA-keyed central location for THIS worktree (HMB-87
  # B.11). Mirrors start.sh's WORKTREE_ENABLED branch.
  ROOT="$WORKTREE_PATH"
  worktree_trust_mise "$WORKTREE_PATH"
}

# ── Persist work-state ───────────────────────────────────────────────────────
#
# state_init signature: --issue is required for normal flows but state.sh
# now permits omission when --kind chore is set (HMB-86 B.1). The slug
# survives as the descriptive label inside state.json's `branch` field;
# the `issue` field is null (no Linear / GitHub key).

BASE_SHA="$(git -C "$PROJECT_ROOT" rev-parse "$BRANCH_BASE" 2>/dev/null || echo "")"
state_init \
  --app homebase \
  --branch "$BRANCH" \
  --base-sha "$BASE_SHA" \
  --kind chore \
  --root "$ROOT" \
  --no-issue
echo "state:    $(state_path "$ROOT") written"

# ── Env file ─────────────────────────────────────────────────────────────────

WORK_ENV="$ROOT/.homebase/.work-env"
{
  echo "# Generated by 'homebase work chore \"$DESC\"' at $(date -u +%FT%TZ)."
  echo "# Source this file in your shell to authorise commits/pushes for this chore:"
  echo "#   source $WORK_ENV"
  echo "# Removed automatically by 'homebase work finish' / 'homebase work cancel'."
  echo "export HOMEBASE_WORK_AUTHORIZED=1"
  echo "export WORK_KIND=chore"
  echo "export WORK_SLUG=$SLUG"
  echo "export WORK_BRANCH=$BRANCH"
  echo "export WORKTREE_PATH=$WORKTREE_PATH"
} > "$WORK_ENV"
echo "env:      $WORK_ENV written"

divider
echo "ready. Use 'homebase work finish' to land the chore on $BRANCH_BASE; 'homebase work cancel' to abandon."
echo "        → cd $WORKTREE_PATH"
echo "        → source .homebase/.work-env to authorise commits/pushes."
exit 0
