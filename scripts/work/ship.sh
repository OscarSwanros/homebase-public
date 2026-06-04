#!/usr/bin/env bash
# scripts/work/ship.sh — `homebase work ship <APP> <VERSION> [TARGET]`.
#
# Dispatch table:
#   - Mobile/desktop apps with a `ship:` stanza (HMB-69) — invokes fastlane
#     locally for the named TARGET (testflight | appstore | mac-appstore |
#     playstore-internal | playstore-prod), runs pre-flight gates, creates
#     and pushes the git tag <app>/<tag_platform>/<version>, and closes
#     the Linear Milestone.
#   - Web apps with a `deploy:` stanza — dispatches to
#     `homebase deploy <app> production --version=<v>` (Kamal pipeline).
#   - Mobile/desktop apps without a `ship:` stanza — prints the SOP-005
#     guided checklist (backward-compatible behaviour).
#
# Tier gating (HMB-69 Q3 / Q4 decisions 2026-05-15):
#   - Yellow-tier targets (testflight, playstore-internal/alpha) — no extra
#     confirm beyond invoking the verb.
#   - Red-tier targets (appstore, playstore-prod, mac-appstore) — require
#     HOMEBASE_SHIP_CONFIRMED=1 set at the terminal. The env var is
#     operator-only at the shell; this script explicitly does NOT honour
#     it when set via .claude/settings.local.json's env block.
#
# Always (every path that doesn't exit early): prints a delegate-to-TPM
# instruction to close the Linear Milestone (HMB-77 — milestone mutations live
# in the Linear MCP via the TPM, not in this verb; the retired `homebase roadmap
# project ship` shell-out was removed).

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "${WORK_DIR}/lib/state.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────

APP=""
VERSION=""
TARGET=""
DRY_RUN=0
SKIP_VALIDATION=0
positional_count=0

usage_short() {
  cat <<'EOF' >&2
usage: homebase work ship <APP> <VERSION> [TARGET] [--dry-run] [--skip-validation]

  Run 'homebase work ship --help' for the full target/tier reference.

Examples
  homebase work ship gascalc 1.2.0 testflight
  homebase work ship studio-web 1.4.2
EOF
}

usage_full() {
  cat <<'EOF'
usage: homebase work ship <APP> <VERSION> [TARGET] [--dry-run] [--skip-validation]

Ship <APP> at <VERSION>. Behaviour depends on the app's project.yml stanza:

  Mobile/desktop apps with a 'ship:' stanza (HMB-69)
    TARGET is required. Available targets are declared in the stanza,
    typically a subset of:
      testflight              [yellow-tier]
      playstore-internal      [yellow-tier]
      playstore-alpha         [yellow-tier]
      appstore                [red-tier — requires HOMEBASE_SHIP_CONFIRMED=1]
      playstore-prod          [red-tier — requires HOMEBASE_SHIP_CONFIRMED=1]
      mac-appstore            [red-tier — requires HOMEBASE_SHIP_CONFIRMED=1]

    HOMEBASE_SHIP_CONFIRMED is operator-only at the terminal — it is NOT
    honoured when set via .claude/settings.local.json's env block.

    Running without TARGET prints the available targets and exits 2.

    Git tagging (HMB-122): only PRODUCTION (red-tier) targets cut and push
    a git tag <app>/<platform>/<version>. Yellow-tier beta/internal targets
    (testflight, playstore-internal/alpha) ship WITHOUT a tag — a tag marks
    "shipped to customers", and re-tagging a marketing version on every beta
    build collides. TestFlight→commit traceability is via the build number +
    dSYM/Sentry, not tags.

  Web apps with a 'deploy:' stanza
    TARGET defaults to 'production'. (Other envs from the deploy stanza
    may be supported by 'homebase deploy' directly; this verb passes
    'production'.)

  Mobile/desktop apps WITHOUT a 'ship:' stanza
    TARGET is ignored; the script prints the SOP-005 phase checklist
    (existing pre-HMB-69 behaviour) and closes the Linear Milestone.

Flags
  --dry-run           Run gates + print the fastlane command + intended
                      git tag and Linear Milestone close, but do not
                      invoke fastlane, create or push the tag, or touch
                      Linear.
  --skip-validation   Skip the `validate_lane` pre-flight (downgrades to
                      a warning). Use sparingly — validate_lane is the
                      app's last line of defence against shipping
                      regressions.

Examples
  homebase work ship gascalc 1.2.0 testflight
  HOMEBASE_SHIP_CONFIRMED=1 homebase work ship gascalc 1.2.0 appstore
  HOMEBASE_SHIP_CONFIRMED=1 homebase work ship gascalc 1.2.0 mac-appstore
  homebase work ship studio-web 1.4.2
EOF
}

while (($#)); do
  case "$1" in
    --dry-run)         DRY_RUN=1; shift ;;
    --skip-validation) SKIP_VALIDATION=1; shift ;;
    --help|-h)         usage_full; exit 0 ;;
    --*)
      echo "ship: unknown flag: $1" >&2
      echo "      Run 'homebase work ship --help' for usage." >&2
      exit 2
      ;;
    *)
      case $positional_count in
        0) APP="$1" ;;
        1) VERSION="$1" ;;
        2) TARGET="$1" ;;
        *)
          echo "ship: unexpected positional argument: $1" >&2
          usage_short
          exit 2
          ;;
      esac
      positional_count=$((positional_count + 1))
      shift
      ;;
  esac
done

if [[ -z "$APP" || -z "$VERSION" ]]; then
  usage_short
  exit 2
fi

ROOT="$(find_repo_root)"
[[ -z "$ROOT" ]] && { echo "ship: not in a git repo" >&2; exit 2; }

# ── Project.yml lookup ───────────────────────────────────────────────────────

HAS_DEPLOY="$(read_project_yml_as_json "$ROOT" | jq -r --arg a "$APP" '
  .apps // [] | map(select(.name == $a)) | .[0].deploy // empty | length > 0
')"

SHIP_JSON="$(read_project_yml_as_json "$ROOT" | jq -c --arg a "$APP" '
  .apps // [] | map(select(.name == $a)) | .[0].ship // empty
')"

HAS_SHIP=0
if [[ -n "$SHIP_JSON" && "$SHIP_JSON" != "null" ]]; then
  HAS_SHIP=1
fi

APP_PATH="$(read_project_yml_as_json "$ROOT" | jq -r --arg a "$APP" '
  .apps // [] | map(select(.name == $a)) | .[0].path // empty
')"

PLATFORMS_CSV="$(read_project_yml_as_json "$ROOT" | jq -r --arg a "$APP" '
  .apps // [] | map(select(.name == $a)) | .[0].platforms // [] | join(",")
')"

# ── Output helpers ───────────────────────────────────────────────────────────

divider() { echo "─────────────────────────────────────────────────────────"; }
echo "homebase work ship $APP $VERSION${TARGET:+ $TARGET}"
divider
echo "platforms: $PLATFORMS_CSV"

# ── Ship-stanza helpers ──────────────────────────────────────────────────────

ship_list_targets() {
  echo "$SHIP_JSON" | jq -r '
    .targets | to_entries | sort_by(.key) | .[] |
    "  \(.key)  [\(.value.tier)-tier — \(.value.platform):\(.value.track)]"
  '
}

ship_read_version_from_file() {
  local lang="$1" path="$2" key="$3"
  case "$lang" in
    xcconfig)
      grep -E "^[[:space:]]*${key}[[:space:]]*=" "$path" \
        | head -1 \
        | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" \
        | tr -d ' \t'
      ;;
    gradle-kts)
      # versionName = "1.2.0"
      grep -E "${key}[[:space:]]*=" "$path" \
        | head -1 \
        | sed -E "s/.*${key}[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\\1/"
      ;;
    plist)
      if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Print :${key}" "$path" 2>/dev/null
      fi
      ;;
    pbxproj)
      # MARKETING_VERSION = 1.2.0;  — Xcode writes the same key into EVERY
      # build configuration, so a pbxproj has N identical lines (16 in GasCalc).
      # Collect all values: if they agree, return the value; if they diverge,
      # fail loudly (a split version across configs is operator error to
      # reconcile in Xcode, never something to silently paper over). (HMB-71)
      local vals count
      vals="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$path" \
        | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//; s/;[[:space:]]*\$//" \
        | tr -d ' \t' \
        | sort -u)"
      [[ -z "$vals" ]] && return 0   # key absent → empty (caller reports mismatch)
      count="$(printf '%s\n' "$vals" | grep -c .)"
      if [[ "$count" -ne 1 ]]; then
        echo "ship: ${key} diverges across pbxproj build configurations:" >&2
        printf '         %s\n' $vals >&2
        echo "ship: reconcile in Xcode so every configuration shares one ${key}." >&2
        return 3
      fi
      printf '%s' "$vals"
      ;;
    *)
      echo "ship: unknown version_file.language '$lang'" >&2
      return 2
      ;;
  esac
}

ship_preflight() {
  local ship_json="$1"
  local issues=0
  local branch_required version_file_path version_file_lang version_file_key
  branch_required="$(echo "$ship_json" | jq -r '.branch // "main"')"
  version_file_path="$(echo "$ship_json" | jq -r '.version_file.path // empty')"
  version_file_lang="$(echo "$ship_json" | jq -r '.version_file.language // empty')"
  version_file_key="$(echo "$ship_json" | jq -r '.version_file.key // empty')"

  # Gate A — tree clean.
  if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
    echo "  [fail] tree not clean (commit or stash uncommitted changes first)"
    issues=$((issues + 1))
  else
    echo "  [ok]   tree clean"
  fi

  # Gate B — on the right branch.
  local current_branch
  current_branch="$(git -C "$ROOT" branch --show-current 2>/dev/null || echo '')"
  if [[ "$current_branch" != "$branch_required" ]]; then
    echo "  [fail] branch '$current_branch' != required '$branch_required'"
    echo "         Check out $branch_required and retry."
    issues=$((issues + 1))
  else
    echo "  [ok]   branch is $branch_required"
  fi

  # Gate C — CHANGELOG header matches.
  if [[ -n "$APP_PATH" ]]; then
    local changelog_path="$ROOT/$APP_PATH/CHANGELOG.md"
    local today
    today="$(date +%Y-%m-%d)"
    if [[ ! -f "$changelog_path" ]]; then
      echo "  [warn] CHANGELOG not found at $APP_PATH/CHANGELOG.md (skipping header check)"
    elif grep -q "^## \[$VERSION\]" "$changelog_path"; then
      echo "  [ok]   CHANGELOG has '## [$VERSION]' section"
    else
      echo "  [fail] CHANGELOG missing '## [$VERSION]' section in $APP_PATH/CHANGELOG.md"
      echo "         Move '## [Unreleased]' entries to '## [$VERSION] - $today' first."
      issues=$((issues + 1))
    fi
  fi

  # Gate D — version file constant matches.
  if [[ -n "$version_file_path" && -n "$version_file_key" && -n "$version_file_lang" ]]; then
    local full_vf="$ROOT/$version_file_path"
    if [[ ! -f "$full_vf" ]]; then
      echo "  [fail] version_file not found at $version_file_path"
      issues=$((issues + 1))
    else
      local found_version
      found_version="$(ship_read_version_from_file "$version_file_lang" "$full_vf" "$version_file_key")"
      if [[ "$found_version" == "$VERSION" ]]; then
        echo "  [ok]   $version_file_key in $version_file_path = $VERSION"
      else
        echo "  [fail] $version_file_key in $version_file_path = '$found_version' (expected '$VERSION')"
        echo "         Bump the constant before shipping."
        issues=$((issues + 1))
      fi
    fi
  fi

  # Gate E — validate_lane (optional pre-flight fastlane lane).
  local validate_lane fastlane_root
  validate_lane="$(echo "$ship_json" | jq -r '.validate_lane // empty')"
  fastlane_root="$(echo "$ship_json" | jq -r '.fastlane_root // "fastlane"')"
  if [[ -n "$validate_lane" ]]; then
    if [[ "$SKIP_VALIDATION" == "1" ]]; then
      echo "  [warn] skipping validate_lane '$validate_lane' (--skip-validation)"
    elif [[ "$DRY_RUN" == "1" ]]; then
      echo "  [skip] validate_lane '$validate_lane' (dry-run)"
    else
      echo "  [run]  bundle exec fastlane $validate_lane (in $fastlane_root/)"
      if ! (cd "$ROOT/$fastlane_root" && bundle exec fastlane "$validate_lane"); then
        echo "  [fail] validate_lane '$validate_lane' returned non-zero"
        issues=$((issues + 1))
      else
        echo "  [ok]   validate_lane passed"
      fi
    fi
  fi

  return $issues
}

ship_create_and_push_tag() {
  local app="$1" tag_platform="$2" version="$3" tag tag_body extract_changelog
  tag="$app/$tag_platform/$version"

  # Tag-already-exists check (locally + on origin).
  if git -C "$ROOT" rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "  [fail] tag '$tag' already exists locally"
    echo "         Delete it (git tag -d $tag) and retry if this is a re-ship of a failed run."
    return 1
  fi
  if git -C "$ROOT" ls-remote --tags origin "refs/tags/$tag" 2>/dev/null | grep -q "$tag"; then
    echo "  [fail] tag '$tag' already exists on origin"
    return 1
  fi

  # Build the tag body from the app's CHANGELOG section if available.
  extract_changelog="$(cd "$WORK_DIR/../.." && pwd -P)/scripts/extract-changelog.sh"
  if [[ -x "$extract_changelog" && -n "$APP_PATH" && -f "$ROOT/$APP_PATH/CHANGELOG.md" ]]; then
    tag_body="$("$extract_changelog" "$ROOT/$APP_PATH/CHANGELOG.md" "$version" 2>/dev/null || true)"
  fi
  [[ -z "${tag_body:-}" ]] && tag_body="$app $version"

  echo "  [run]  git tag -a $tag"
  if ! git -C "$ROOT" tag -a "$tag" -m "$tag_body"; then
    echo "  [fail] git tag -a $tag returned non-zero"
    return 1
  fi

  echo "  [run]  git push origin $tag"
  # HMB-78: the verb's own tag push is intentional work, not off-contract
  # chore territory. Self-authorize so the pre-push hook on adopting projects
  # (TFD/Studio) allows it — same pattern homebase work {start,checkpoint,finish}
  # use internally. Without this the hook blocks and the ship can't complete
  # end-to-end (fastlane uploads, tag created locally, push rejected).
  if ! HOMEBASE_WORK_AUTHORIZED=1 git -C "$ROOT" push origin "$tag"; then
    echo "  [fail] git push origin $tag returned non-zero"
    echo "         The tag exists locally; delete + retry, or push manually."
    return 1
  fi
  echo "  [ok]   tag $tag created + pushed"
}

# HMB-121: load store credentials (App Store Connect API key, Play service
# account, etc.) from ~/.config/homebase/env into THIS shell so the
# validate_lane + deploy fastlane subshells inherit them. Operators (and Claude
# sessions) repeatedly hit cryptic mid-upload altool auth failures — the build
# succeeded, then upload exploded ~60s later with an ITunesConnect auth error —
# because their interactive profile never sourced the file. The verb sources it
# itself so every ship works regardless of shell setup.
#
# - Override path with HOMEBASE_ENV_FILE (used by the test fixture).
# - Refuse a group/world-readable secrets file (mode must be 600 or 400).
# - On --dry-run, report what WOULD load without sourcing secrets into a
#   throwaway preview process.
# - Silent-safe when absent: prints a status line, never hard-fails here
#   (a target that genuinely needs creds fails loudly downstream in fastlane).
source_homebase_env() {
  local env_file="${HOMEBASE_ENV_FILE:-$HOME/.config/homebase/env}"
  if [[ ! -f "$env_file" ]]; then
    echo "env:       $env_file not found (store credentials may be unavailable)"
    return 0
  fi
  local perms
  perms="$(stat -f '%Lp' "$env_file" 2>/dev/null || stat -c '%a' "$env_file" 2>/dev/null || echo '')"
  if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
    echo "env:       $env_file is mode $perms (must be 600) — not sourcing; run: chmod 600 $env_file" >&2
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "env:       would source $env_file (dry-run)"
    return 0
  fi
  set -a
  # shellcheck disable=SC1090
  . "$env_file"
  set +a
  echo "env:       sourced $env_file"
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

if [[ "$HAS_SHIP" == "1" ]]; then
  # Ship-stanza path: target-driven fastlane invocation.

  if [[ -z "$TARGET" ]]; then
    cat <<EOF >&2
ship: no TARGET specified for $APP

$APP declares a 'ship:' stanza in project.yml; you must pass one of:
EOF
    ship_list_targets >&2
    cat <<EOF >&2

Example: homebase work ship $APP $VERSION testflight
         homebase work ship $APP $VERSION testflight --dry-run

Run 'homebase work ship --help' for the full target/tier reference.
EOF
    exit 2
  fi

  TARGET_JSON="$(echo "$SHIP_JSON" | jq -c --arg t "$TARGET" '.targets[$t] // empty')"
  if [[ -z "$TARGET_JSON" || "$TARGET_JSON" == "null" ]]; then
    echo "ship: target '$TARGET' is not declared in $APP's ship: stanza" >&2
    echo "      available:" >&2
    ship_list_targets >&2
    exit 2
  fi

  FASTLANE_APP="$(echo "$TARGET_JSON" | jq -r '.fastlane_app')"
  TARGET_PLATFORM="$(echo "$TARGET_JSON" | jq -r '.platform')"
  TARGET_TRACK="$(echo "$TARGET_JSON" | jq -r '.track')"
  TARGET_TIER="$(echo "$TARGET_JSON" | jq -r '.tier')"
  TAG_PLATFORM="$(echo "$TARGET_JSON" | jq -r '.tag_platform // .platform')"
  FASTLANE_ROOT="$(echo "$SHIP_JSON" | jq -r '.fastlane_root // "fastlane"')"
  TOOL="$(echo "$SHIP_JSON" | jq -r '.tool')"

  # HMB-122: tag only PRODUCTION releases. A git tag <app>/<platform>/<version>
  # marks "this shipped to customers"; cutting one per TestFlight / Play
  # internal build collides on the marketing-version tag every re-ship (the tag
  # step fails "already exists" even though the upload succeeded) and is
  # semantically wrong — the tag's annotation is the release changelog.
  # Production targets are exactly the red tier (appstore, mac-appstore,
  # playstore-prod); yellow-tier beta/internal targets ship without a tag.
  # TestFlight→commit traceability comes from the build number + dSYM/Sentry.
  TAG_THIS_SHIP=0
  [[ "$TARGET_TIER" == "red" ]] && TAG_THIS_SHIP=1

  echo "tool:      $TOOL"
  echo "target:    $TARGET ($TARGET_TIER-tier — $TARGET_PLATFORM:$TARGET_TRACK)"
  echo "fastlane:  app:$FASTLANE_APP platform:$TARGET_PLATFORM track:$TARGET_TRACK (in $FASTLANE_ROOT/)"
  if [[ "$TAG_THIS_SHIP" == "1" ]]; then
    echo "tag:       $APP/$TAG_PLATFORM/$VERSION (production release)"
  else
    echo "tag:       (skipped — $TARGET is non-production; tags mark production releases only)"
  fi
  divider

  # Tier gate — red-tier requires HOMEBASE_SHIP_CONFIRMED=1 at the terminal.
  # Skipped under --dry-run: previewing a red-tier ship has no side effects, so
  # the operator-confirm checkpoint isn't meaningful there.
  if [[ "$TARGET_TIER" == "red" && "$DRY_RUN" != "1" && "${HOMEBASE_SHIP_CONFIRMED:-}" != "1" ]]; then
    cat <<EOF >&2

  [fail] red-tier target '$TARGET' requires HOMEBASE_SHIP_CONFIRMED=1

         Red-tier targets ship to production-grade stores (App Store, Play
         production, Mac App Store). They require an explicit operator
         confirmation that cannot be captured in .claude/settings.local.json.

         Set it in your terminal and rerun:
           HOMEBASE_SHIP_CONFIRMED=1 homebase work ship $APP $VERSION $TARGET

         To preview without invoking: add --dry-run.

EOF
    exit 2
  fi

  # HMB-121: source store credentials before any fastlane invocation (the
  # validate_lane below and the deploy lane later both run in subshells that
  # inherit this shell's exported env).
  source_homebase_env

  # Pre-flight gates.
  echo "pre-flight gates:"
  if ! ship_preflight "$SHIP_JSON"; then
    echo
    echo "  [fail] pre-flight gates failed — fix the above and rerun." >&2
    exit 2
  fi
  echo

  TAG="$APP/$TAG_PLATFORM/$VERSION"
  FASTLANE_CMD="bundle exec fastlane deploy app:$FASTLANE_APP platform:$TARGET_PLATFORM track:$TARGET_TRACK"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "dry-run: would run the following (no side effects):"
    echo "  1. cd $ROOT/$FASTLANE_ROOT && $FASTLANE_CMD"
    if [[ "$TAG_THIS_SHIP" == "1" ]]; then
      echo "  2. git tag -a $TAG -m '<CHANGELOG body>' && git push origin $TAG"
    else
      echo "  2. (no tag — $TARGET is non-production; tags mark production releases only)"
    fi
    echo "  3. (post-ship) delegate Milestone v$VERSION close on project '$APP' to the TPM"
    divider
    echo "ok. (dry-run)"
    exit 0
  fi

  # Real invocation: fastlane → tag → milestone close.
  echo "fastlane:"
  echo "  [run]  cd $ROOT/$FASTLANE_ROOT && $FASTLANE_CMD"
  if ! (cd "$ROOT/$FASTLANE_ROOT" && $FASTLANE_CMD); then
    echo "  [fail] fastlane returned non-zero — no tag created, milestone not closed."
    exit 2
  fi
  echo "  [ok]   fastlane completed"
  echo

  if [[ "$TAG_THIS_SHIP" == "1" ]]; then
    echo "tag:"
    if ! ship_create_and_push_tag "$APP" "$TAG_PLATFORM" "$VERSION"; then
      echo
      echo "  [warn] fastlane succeeded but tagging failed."
      echo "         The release artifact reached the store; tag manually:"
      echo "           git tag -a $TAG -m '$APP $VERSION' && git push origin $TAG"
      exit 2
    fi
    echo
  else
    echo "tag:       skipped ($TARGET is non-production — no release tag cut; HMB-122)"
    echo
  fi

elif [[ "$HAS_DEPLOY" == "true" ]]; then
  # Web path: dispatch to homebase deploy.
  echo "deploy:    web (calling 'homebase deploy $APP production --version=$VERSION')"
  HOMEBASE_BIN="$(cd "$WORK_DIR/../.." && pwd -P)/bin/homebase"
  [[ -x "$HOMEBASE_BIN" ]] || HOMEBASE_BIN="$(command -v homebase 2>/dev/null || echo "")"
  if [[ -z "$HOMEBASE_BIN" || ! -x "$HOMEBASE_BIN" ]]; then
    echo "  [fail] cannot locate bin/homebase to dispatch deploy" >&2
    exit 2
  fi
  "$HOMEBASE_BIN" deploy "$APP" production --version="$VERSION" || {
    echo "  [fail] deploy returned non-zero" >&2
    exit 2
  }

else
  # Mobile/desktop checklist (backward-compatible path for apps without ship:).
  cat <<EOF
mobile/desktop release — guided checklist (SOP-005):
  1. Update apps/$APP/CHANGELOG.md '## [Unreleased]' → '## [$VERSION]' with date.
  2. Bump version constant per the app's version_file convention.
  3. Localise store metadata (per HOMEBASE-SOP-005 § Localisation).
  4. Run platform-specific test/build (per workflow.yml required_checks).
  5. Tag: git tag -a $APP/$VERSION -m "$APP $VERSION".
  6. Push tag; CI builds and uploads to TestFlight / Play Console / Sparkle.
  7. Watch for store review; promote when approved.
  8. After release lands: run 'homebase work ship $APP $VERSION' again to
     close the Linear Milestone (this script's last step).

  Adopt the 'ship:' stanza in this project's .homebase/project.yml (see the
  homebase template) to switch this app to the local-fastlane path shipped
  in HMB-69 — then 'homebase work ship $APP $VERSION testflight' will run
  the fastlane deploy lane directly, no checklist required.
EOF
fi

# Release shipped. Closing/graduating the Linear Milestone is a Linear mutation,
# so it is delegated to the technical-project-manager (Linear API gatekeeper,
# SOP-013) rather than performed here. HMB-77: the old `homebase roadmap project
# ship` verb was retired — individual milestone mutations live in the Linear MCP,
# not the roadmap glue — so the ship verb no longer shells out to it (it used to
# warn-and-continue, silently leaving the milestone open).
echo "linear:    release shipped — close the Linear Milestone via the TPM:"
echo "  → Delegate to technical-project-manager: mark Milestone 'v$VERSION' on"
echo "    Linear project '$APP' as shipped (Linear MCP save_milestone, or the"
echo "    Linear UI). The ship verb does not mutate Linear."

divider
echo "ok."
exit 0
