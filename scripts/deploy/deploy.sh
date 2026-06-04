#!/usr/bin/env bash
# deploy.sh — 12-phase deploy orchestrator for `homebase deploy`.
#
# Invoked by bin/homebase cmd_deploy. Do not source — execute.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMEBASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage:
  homebase deploy <app> <env> [--setup] [--dry-run] [--version=X.Y.Z] [--patch|--minor|--major]

Deploys <app> to <env> via Kamal. Orchestrates the 12-phase pipeline defined
in standards/RAILS_PLAYBOOK.md: resolve → preflight → version read →
changelog move → version bump → validate → commit → kamal build/push →
kamal deploy → tag → push → reopen [Unreleased].

Options:
  --version=X.Y.Z     Explicit SemVer (must be strictly greater than current).
  --patch             Bump patch (default).
  --minor             Bump minor (resets patch to 0).
  --major             Bump major (resets minor + patch to 0).
  --setup             First-time deploy: Phase 9 runs \`kamal setup\` (provisions
                      kamal-proxy + accessories on a fresh host) instead of
                      \`kamal deploy\`. Idempotent; use once per app+env.
  --dry-run           Run phases 1–3 and 6; print but don't execute 4–5 and 7–12.
  -h, --help          Show this help.
EOF
}

APP=""
ENV_ARG=""
VERSION_ARG=""
BUMP="patch"
DRY_RUN=0
SETUP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=1; shift ;;
    --setup)     SETUP=1; shift ;;
    --version=*) VERSION_ARG="${1#--version=}"; shift ;;
    --version)   VERSION_ARG="$2"; shift 2 ;;
    --patch)     BUMP="patch"; shift ;;
    --minor)     BUMP="minor"; shift ;;
    --major)     BUMP="major"; shift ;;
    -h|--help)   usage; exit 0 ;;
    --*)         DEPLOY_PHASE="args"; err "unknown flag: $1"; usage; exit 2 ;;
    *)
      if   [[ -z "$APP" ]];     then APP="$1"
      elif [[ -z "$ENV_ARG" ]]; then ENV_ARG="$1"
      else DEPLOY_PHASE="args"; err "unexpected argument: $1"; usage; exit 2
      fi
      shift ;;
  esac
done

if [[ -z "$APP" || -z "$ENV_ARG" ]]; then
  DEPLOY_PHASE="args"
  err "<app> and <env> required"
  usage
  exit 2
fi

export DRY_RUN

# ── Phase 1: Resolve ──────────────────────────────────────────────────────────

DEPLOY_PHASE="1/resolve"
if ! eval "$(ruby "$HOMEBASE/scripts/deploy/resolve.rb" "$HOMEBASE" "$APP" "$ENV_ARG")"; then
  err "resolve failed"
  exit 2
fi
ok "project=$HB_PROJECT_PATH  app=$HB_APP_NAME  env=$HB_ENV_NAME"

PROJECT_PATH="$HB_PROJECT_PATH"
APP_PATH="$HB_APP_PATH"
APP_NAME="$HB_APP_NAME"
ENV_NAME="$HB_ENV_NAME"

# ── Phase 2: Preflight ────────────────────────────────────────────────────────

DEPLOY_PHASE="2/preflight"
require_cmd git
require_cmd ruby
require_cmd docker
require_cmd kamal
require_cmd curl

cd "$PROJECT_PATH"

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "$HB_BRANCH" ]]; then
  err "on branch '$CURRENT_BRANCH', expected '$HB_BRANCH'"
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  err "working tree not clean:"
  git status --short >&2
  exit 1
fi

git fetch --quiet origin "$HB_BRANCH"
LOCAL_SHA="$(git rev-parse @)"
REMOTE_SHA="$(git rev-parse "origin/$HB_BRANCH")"
if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
  err "local $HB_BRANCH out of sync with origin ($LOCAL_SHA vs $REMOTE_SHA)"
  exit 1
fi

if [[ "$DRY_RUN" != "1" ]]; then
  if ! docker info >/dev/null 2>&1; then
    err "docker daemon not available"
    exit 1
  fi
  if ! grep -q '"ghcr\.io"' "$HOME/.docker/config.json" 2>/dev/null; then
    warn "ghcr.io not in ~/.docker/config.json — you may need 'docker login ghcr.io' before Phase 8"
  fi

  # HMB-74: ghcr.io auth probe. Fail fast on silent token expiry BEFORE Phase 3
  # makes any version-bump commits. Hits the docker-login token-exchange endpoint
  # (not /v2/, which always 401s as an auth-challenge) using the same credential
  # resolution Kamal does at deploy time — subshell `source .kamal/secrets` with
  # cwd=$APP_PATH so inline `$(gh auth token)` expansions resolve correctly.
  KAMAL_CONFIG_ABS="$APP_PATH/$HB_KAMAL_CONFIG"
  if [[ -f "$KAMAL_CONFIG_ABS" && -f "$APP_PATH/.kamal/secrets" ]]; then
    REG_SERVER="$(grep -E '^\s*server:' "$KAMAL_CONFIG_ABS" | head -1 | awk -F: '{print $2}' | xargs || true)"
    if [[ "$REG_SERVER" == "ghcr.io" ]]; then
      REG_USERNAME="$(grep -E '^\s*username:' "$KAMAL_CONFIG_ABS" | head -1 | awk -F: '{print $2}' | xargs || true)"
      REG_IMAGE="$(grep -E '^\s*image:' "$KAMAL_CONFIG_ABS" | head -1 | awk -F: '{print $2}' | xargs || true)"
      if [[ -z "$REG_USERNAME" || -z "$REG_IMAGE" ]]; then
        err "ghcr.io auth probe: could not parse registry.username or image from $KAMAL_CONFIG_ABS"
        exit 1
      fi
      # Source .kamal/secrets in a subshell with cwd=$APP_PATH so command
      # substitutions like `$(gh auth token)` expand the same way Kamal expands
      # them at deploy time. Process substitution (`source <(...)`) is avoided
      # intentionally — it has been observed to swallow gh-CLI stderr and
      # return an empty value.
      REG_PASSWORD="$(cd "$APP_PATH" && bash -c 'set +u; source .kamal/secrets; echo "$KAMAL_REGISTRY_PASSWORD"')"
      if [[ -z "$REG_PASSWORD" ]]; then
        err "ghcr.io auth probe: KAMAL_REGISTRY_PASSWORD resolved empty after sourcing $APP_PATH/.kamal/secrets"
        err "  check the secrets file and confirm any inline \$(gh auth token) call works (gh auth status)"
        exit 1
      fi
      PROBE_URL="https://ghcr.io/token?service=ghcr.io&scope=repository:${REG_IMAGE}:pull"
      PROBE_CODE="$(curl --silent --output /dev/null --write-out '%{http_code}' \
        --max-time 10 \
        --user "${REG_USERNAME}:${REG_PASSWORD}" \
        "$PROBE_URL" || echo "000")"
      if [[ "$PROBE_CODE" != "200" ]]; then
        err "ghcr.io auth probe failed: HTTP $PROBE_CODE from $PROBE_URL"
        err "  KAMAL_REGISTRY_PASSWORD (from $APP_PATH/.kamal/secrets) was rejected by ghcr.io"
        err "  remediation:"
        err "    - run 'gh auth status' to confirm your GitHub token is live"
        err "    - inspect $APP_PATH/.kamal/secrets for stale static tokens"
        err "    - if the secrets file uses a static PAT, consider switching to \$(gh auth token)"
        exit 1
      fi
      info "ghcr.io auth probe OK"
    fi
  fi
fi

ok "clean tree on $CURRENT_BRANCH, synced with origin"

# ── Phase 3: Version read + next version ──────────────────────────────────────

DEPLOY_PHASE="3/version"
VERSION_FILE_ABS="$APP_PATH/$HB_VERSION_FILE_PATH"
if [[ ! -f "$VERSION_FILE_ABS" ]]; then
  err "version_file not found: $VERSION_FILE_ABS"
  exit 1
fi

CURRENT_VERSION="$(ruby "$HOMEBASE/scripts/deploy/bump_version.rb" read "$VERSION_FILE_ABS" "$HB_VERSION_FILE_LANGUAGE")"
ok "current: $CURRENT_VERSION"

if [[ -n "$VERSION_ARG" ]]; then
  NEW_VERSION="$VERSION_ARG"
else
  NEW_VERSION="$(compute_next_version "$CURRENT_VERSION" "$BUMP")"
fi

assert_version_increases "$CURRENT_VERSION" "$NEW_VERSION" || exit 1
ok "next: $NEW_VERSION"

TAG_NAME="$APP_NAME/web/$NEW_VERSION"
if tag_exists "$TAG_NAME"; then
  err "tag $TAG_NAME already exists"
  exit 1
fi

# ── Phase 4: Changelog move ───────────────────────────────────────────────────

DEPLOY_PHASE="4/changelog"
CHANGELOG_ABS="$(resolve_changelog_abs "$PROJECT_PATH" "$APP_NAME")" || exit 1
[[ -f "$CHANGELOG_ABS" ]] || { err "changelog missing: $CHANGELOG_ABS"; exit 1; }
ok "changelog: $CHANGELOG_ABS"

if ! unreleased_has_content "$CHANGELOG_ABS"; then
  err "[Unreleased] in $CHANGELOG_ABS has no entries — nothing to release"
  exit 1
fi

RELEASE_DATE="$(date -u +%Y-%m-%d)"

if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would rotate [Unreleased] → [$NEW_VERSION] - $RELEASE_DATE"
else
  changelog_rotate "$CHANGELOG_ABS" "$NEW_VERSION" "$RELEASE_DATE"
  ok "rotated changelog"
fi

# ── Phase 5: Version bump ─────────────────────────────────────────────────────

DEPLOY_PHASE="5/bump"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would rewrite $HB_VERSION_FILE_PATH: $CURRENT_VERSION → $NEW_VERSION"
else
  ruby "$HOMEBASE/scripts/deploy/bump_version.rb" write "$VERSION_FILE_ABS" "$HB_VERSION_FILE_LANGUAGE" "$NEW_VERSION" >/dev/null
  ok "bumped $HB_VERSION_FILE_PATH"
fi

# ── Phase 6: Validate ─────────────────────────────────────────────────────────

DEPLOY_PHASE="6/validate"
if [[ -n "$HB_VALIDATE" ]]; then
  info "running: $HB_VALIDATE (in $APP_PATH)"
  cd "$APP_PATH"
  if ! bash -c "$HB_VALIDATE"; then
    err "validate failed: $HB_VALIDATE"
    exit 1
  fi
  ok "validate passed"
  cd "$PROJECT_PATH"
else
  info "no validate command declared — skipping"
fi

# ── Phase 7: Commit ───────────────────────────────────────────────────────────

DEPLOY_PHASE="7/commit"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would commit: Release $APP_NAME $NEW_VERSION"
else
  cd "$PROJECT_PATH"
  git add "$VERSION_FILE_ABS" "$CHANGELOG_ABS"
  git commit -m "Release $APP_NAME $NEW_VERSION"
  ok "committed"
fi

# ── Phase 8: Build + push image ───────────────────────────────────────────────

DEPLOY_PHASE="8/build-push"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would run: kamal build push --version=$NEW_VERSION -c $HB_KAMAL_CONFIG (in $APP_PATH)"
else
  cd "$APP_PATH"
  VERSION="$NEW_VERSION" kamal build push --version="$NEW_VERSION" -c "$HB_KAMAL_CONFIG"
  ok "pushed $HB_IMAGE:$NEW_VERSION"
fi

# ── Phase 9: Deploy ───────────────────────────────────────────────────────────

DEPLOY_PHASE="9/deploy"
KAMAL_VERB="deploy"
[[ "$SETUP" == "1" ]] && KAMAL_VERB="setup"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would run: kamal $KAMAL_VERB --version=$NEW_VERSION -c $HB_KAMAL_CONFIG"
else
  cd "$APP_PATH"
  VERSION="$NEW_VERSION" kamal "$KAMAL_VERB" --version="$NEW_VERSION" -c "$HB_KAMAL_CONFIG"
  ok "kamal $KAMAL_VERB succeeded"
  if [[ -n "$HB_HEALTH_URL" ]]; then
    DEPLOY_PHASE="9/health"
    retry_health "$HB_HEALTH_URL" 10 3 || exit 1
  fi
fi

# ── Phase 10: Tag ─────────────────────────────────────────────────────────────

DEPLOY_PHASE="10/tag"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would tag: $TAG_NAME"
else
  cd "$PROJECT_PATH"
  TAG_MSG="$("$HOMEBASE/scripts/extract-changelog.sh" "$APP_NAME" "$NEW_VERSION" "web")"
  git tag -a "$TAG_NAME" -m "$TAG_MSG"
  ok "tagged $TAG_NAME"
fi

# ── Phase 11: Push ────────────────────────────────────────────────────────────

DEPLOY_PHASE="11/push"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would push: git push origin $HB_BRANCH --follow-tags"
else
  cd "$PROJECT_PATH"
  # `homebase deploy` IS a homebase verb in flight — authorise its own pushes
  # against the project's pre-push hook. Without this envelope, every
  # adopted-workflow project rejects the deploy's tag/release push and the
  # operator has to hand-drive the off-contract recovery tail.
  #
  # HMB-123: if the push collides with a concurrent commit on origin
  # (operator landed an unrelated patch on $HB_BRANCH while kamal was
  # building/deploying in Phases 8/9), push_with_rebase_recovery
  # fetches + rebases + retries. The release-bump commit only touches
  # CHANGELOG + version file so the rebase surface is minimal.
  # Conflicts fall through with an operator remediation block (exit 2
  # from the helper) and we propagate the failure.
  push_with_rebase_recovery "$HB_BRANCH" --follow-tags
  push_rc=$?
  if [[ $push_rc -ne 0 ]]; then
    if [[ $push_rc -eq 2 ]]; then
      err "Phase 11 push: rebase recovery hit conflicts — see remediation block above."
    fi
    exit 1
  fi
  ok "pushed $HB_BRANCH + tag"
fi

# ── Phase 12: Reopen [Unreleased] ─────────────────────────────────────────────

DEPLOY_PHASE="12/reopen"
if [[ "$DRY_RUN" == "1" ]]; then
  info "[dry-run] would reopen [Unreleased] in $CHANGELOG_ABS and push"
else
  cd "$PROJECT_PATH"
  changelog_reopen "$CHANGELOG_ABS"
  git add "$CHANGELOG_ABS"
  # Same envelope for the post-release reopen commit + push: the deploy is
  # still in flight, so the work-authorised path is the correct one (not
  # off-contract).
  HOMEBASE_WORK_AUTHORIZED=1 git commit -m "Post-release: open $APP_NAME $NEW_VERSION unreleased section"

  # HMB-123: Phase 12 push uses the same recovery path. The reopen commit
  # only touches the CHANGELOG, so a conflict here would mean two
  # operators both reopened [Unreleased] in the same window — extremely
  # rare, but the helper still bails cleanly with a remediation block
  # if it happens.
  push_with_rebase_recovery "$HB_BRANCH"
  push_rc=$?
  if [[ $push_rc -ne 0 ]]; then
    if [[ $push_rc -eq 2 ]]; then
      err "Phase 12 push: rebase recovery hit conflicts — see remediation block above."
    fi
    exit 1
  fi
  ok "reopened [Unreleased]"
fi

DEPLOY_PHASE="done"
ok "$APP_NAME $NEW_VERSION deployed to $ENV_NAME"
if [[ -n "$HB_TRAEFIK_HOST" ]]; then
  info "https://$HB_TRAEFIK_HOST"
fi
