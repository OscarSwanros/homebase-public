#!/usr/bin/env bash
# Validate a commit against HOMEBASE-SOP-001 § CHANGELOG Discipline.
#
# Two enforcement paths:
#
# 1. Conventional-Commits subjects — `feat(<app>):` / `fix(<app>):`. The
#    scope names the app; if the app's CHANGELOG exists, the commit MUST
#    stage it.
#
# 2. Linear-key subjects (HMB-24) — `<KEY>: <title>` (e.g. `TBL-26: ...`).
#    The hook infers the app from the staged paths: if the commit's
#    staged files all live under exactly one app root and that app has a
#    CHANGELOG, the commit MUST stage the CHANGELOG OR carry a
#    `Changelog skipped: <reason>` trailer in the body. Multi-app or
#    no-app commits are exempt.
#
# App root + changelog path resolution (HMB-26):
#   - Primary: `<REPO_ROOT>/.homebase/project.yml` `apps:` array. Each
#     entry declares `name`, `path` (repo-relative app root), and an
#     optional `changelog` override (defaults to `<path>/CHANGELOG.md`).
#     This is what lets monorepo-root apps like ShopOS (path=ShopOS,
#     changelog=ShopOS/Documentation/Release/CHANGELOG.md) get enforced.
#   - Fallback: when project.yml is absent, the legacy `apps/<scope>/`
#     shape is used so studio-style monorepos that haven't
#     declared apps still work.
#
# Rationale: keeps `## [Unreleased]` current so `homebase deploy` can
# tag a release at any time without a separate "populate changelog"
# step. Mirrors the per-commit discipline; the release tool is a
# tripwire, not the prompt to write one. Linear-key path closes the
# gap that allowed seven user-facing commits on StudioWeb to ship on
# 2026-04-28 without any `## [Unreleased]` entries.
#
# Usage (same as commit-sop-check.sh):
#   commit-changelog-check.sh <path-to-commit-msg-file>
#   printf '%s' "$MSG" | commit-changelog-check.sh
#
# Exit codes:
#   0 — compliant, or rule does not apply to this commit.
#   1 — feat/fix or Linear-key commit on an app-with-CHANGELOG did not
#       stage the CHANGELOG and did not opt out via trailer. Reason is
#       printed to stderr.
#
# Canonical policy: ~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md
# Symlinked into each project via `bin/homebase link-project`.

set -uo pipefail

if [[ $# -ge 1 ]] && [[ -f "$1" ]]; then
  MSG=$(cat "$1")
else
  MSG=$(cat -)
fi

MSG_CLEAN=$(printf '%s\n' "$MSG" | grep -v '^#' || true)
SUBJECT=$(printf '%s\n' "$MSG_CLEAN" | head -1)

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$REPO_ROOT" ]]; then
  exit 0
fi

PROJECT_YML="$REPO_ROOT/.homebase/project.yml"

# Each app entry is expanded into one or more candidate (path, changelog)
# pairs: the primary `path`/`changelog`, plus any `extra_paths[].path` /
# `extra_paths[].changelog` (HMB-26). This is what lets multi-platform
# apps like GasCalc (iOS/Apps/GasCalc + Android/apps/gascalc, each with its
# own CHANGELOG) get enforced on either side independently.
read -r -d '' CANDIDATES_PY_PRELUDE <<'PY' || true
def candidates(app):
    primary_path = (app.get("path") or "").rstrip("/")
    primary_cl = app.get("changelog") or f"{primary_path}/CHANGELOG.md"
    out = [(primary_path, primary_cl)]
    for extra in (app.get("extra_paths") or []):
        ex_path = (extra.get("path") or "").rstrip("/")
        if not ex_path:
            continue
        ex_cl = extra.get("changelog") or f"{ex_path}/CHANGELOG.md"
        out.append((ex_path, ex_cl))
    return out
PY

# Python helper for `changelog_for_scope`. Argv: <project_yml> <scope>.
# Stdin is the newline-separated staged paths (used to disambiguate the
# correct candidate when an app has extra_paths). Prints
# `<app_path>\t<changelog_rel>` on a hit; nothing on a miss.
read -r -d '' SCOPE_LOOKUP_PY <<PY || true
import sys, yaml
${CANDIDATES_PY_PRELUDE}
try:
    yml = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
target = sys.argv[2]
staged = [l.strip() for l in sys.stdin if l.strip()]
for app in (yml.get("apps") or []):
    if app.get("name") != target:
        continue
    cands = candidates(app)
    # If staged paths are present, pick the candidate that covers them.
    if staged:
        covering = [
            (p, cl) for (p, cl) in cands
            if p and all(s.startswith(p + "/") for s in staged)
        ]
        if covering:
            covering.sort(key=lambda pc: len(pc[0]), reverse=True)
            print(f"{covering[0][0]}\t{covering[0][1]}")
            sys.exit(0)
    # Fallback: primary candidate.
    if cands:
        p, cl = cands[0]
        print(f"{p}\t{cl}")
        sys.exit(0)
PY

# Python helper for `app_from_staged_paths`. Argv: <project_yml>. Stdin
# is the newline-separated staged paths. Prints `<app_path>\t<changelog_rel>`
# when exactly one app candidate (primary or extra_paths) covers every
# staged file; nothing otherwise. Prefers the longest matching path so
# nested declarations (e.g. iOS/Apps/LogApp vs iOS/) resolve to the
# specific app, not the parent.
read -r -d '' STAGED_LOOKUP_PY <<PY || true
import sys, yaml
${CANDIDATES_PY_PRELUDE}
try:
    yml = yaml.safe_load(open(sys.argv[1])) or {}
except Exception:
    sys.exit(0)
apps = yml.get("apps") or []
staged_all = [l.strip() for l in sys.stdin if l.strip()]
# CHANGELOG paths are excluded from matching so a developer who stages
# the wrong app's CHANGELOG (e.g. the Android one for an iOS-source
# commit) doesn't accidentally turn the commit into a cross-app commit
# that the hook silently exempts. The hook's downstream logic checks
# whether the *correct* CHANGELOG was staged once we've identified the
# app via source-file paths.
staged = [s for s in staged_all if not s.endswith("/CHANGELOG.md") and s != "CHANGELOG.md"]
if not staged:
    sys.exit(0)
matches = []
for app in apps:
    for (path, changelog) in candidates(app):
        if not path:
            continue
        if all(s.startswith(path + "/") for s in staged):
            matches.append((path, changelog))
if len(matches) > 1:
    matches.sort(key=lambda pc: len(pc[0]), reverse=True)
    matches = [matches[0]]
if len(matches) != 1:
    sys.exit(0)
path, changelog = matches[0]
print(f"{path}\t{changelog}")
PY

# Resolve `<app_path>\t<changelog_rel>` for a Conventional-Commits scope.
# Looks up the project's apps[].name == <scope> first; falls back to the
# legacy `apps/<scope>/` shape when project.yml is absent or doesn't
# declare the scope. Also accepts the current staged paths so that an
# app with multiple roots (`extra_paths`) resolves to the correct
# CHANGELOG when the commit is platform-scoped.
changelog_for_scope() {
  local scope="$1"
  local staged="${2:-}"
  local result=""
  if [[ -f "$PROJECT_YML" ]]; then
    result=$(printf '%s\n' "$staged" | python3 -c "$SCOPE_LOOKUP_PY" "$PROJECT_YML" "$scope" 2>/dev/null)
  fi
  if [[ -n "$result" ]]; then
    printf '%s' "$result"
    return 0
  fi
  printf 'apps/%s\tapps/%s/CHANGELOG.md' "$scope" "$scope"
}

# Resolve `<app_path>\t<changelog_rel>` from a list of staged paths.
# Returns nothing when zero or multiple apps cover the staged set —
# both are exemptions, not errors. Falls back to the legacy `apps/<X>/`
# walk when project.yml is absent.
app_from_staged_paths() {
  local staged="$1"
  local result=""

  if [[ -f "$PROJECT_YML" ]]; then
    result=$(printf '%s\n' "$staged" | python3 -c "$STAGED_LOOKUP_PY" "$PROJECT_YML" 2>/dev/null)
    if [[ -n "$result" ]]; then
      printf '%s' "$result"
      return 0
    fi
  fi

  local apps_touched
  apps_touched=$(printf '%s\n' "$staged" | awk -F/ '$1 == "apps" && NF >= 2 { print $2 }' | sort -u)
  local count
  count=$(printf '%s\n' "$apps_touched" | grep -c .)
  if [[ "$count" -eq 1 ]]; then
    printf 'apps/%s\tapps/%s/CHANGELOG.md' "$apps_touched" "$apps_touched"
  fi
}

# Path 1 — Conventional-Commits `feat(<app>):` / `fix(<app>):`.
if [[ "$SUBJECT" =~ ^(feat|fix)\(([a-zA-Z0-9._-]+)\)!?:[[:space:]] ]]; then
  TYPE="${BASH_REMATCH[1]}"
  SCOPE="${BASH_REMATCH[2]}"

  STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
  RESOLVED=$(changelog_for_scope "$SCOPE" "$STAGED")
  APP_REL="${RESOLVED%%$'\t'*}"
  CHANGELOG_REL="${RESOLVED##*$'\t'}"
  APP_DIR="$REPO_ROOT/$APP_REL"

  # Only enforce when the resolved app exists and has a CHANGELOG.
  if [[ ! -d "$APP_DIR" ]] || [[ ! -f "$REPO_ROOT/$CHANGELOG_REL" ]]; then
    exit 0
  fi

  if printf '%s\n' "$STAGED" | grep -Fxq "$CHANGELOG_REL"; then
    exit 0
  fi

  cat >&2 <<EOF

HOMEBASE-SOP-001 VIOLATION — ${TYPE}(${SCOPE}) commit does not update the app CHANGELOG.

Subject:   ${SUBJECT}
Expected:  ${CHANGELOG_REL} staged in this commit, with a new line
           under '## [Unreleased]'.

\`feat(<app>):\` and \`fix(<app>):\` commits change user-visible behavior
and MUST add an entry under '## [Unreleased]' in the app's CHANGELOG in
the same commit. This keeps '[Unreleased]' current so the release tool
never has to prompt for a changelog at deploy time.

Fix:
  1. Open ${CHANGELOG_REL}
  2. Under '## [Unreleased]', add a bullet to the right section:
       ### Added   — new capabilities
       ### Changed — modifications to existing behavior
       ### Fixed   — bug fixes
  3. Stage it:  git add ${CHANGELOG_REL}
  4. Re-run the commit.

If this commit is genuinely not user-visible (internal refactor that
does not change behavior, test-only change, build/CI tweak, internal
tooling), use a non-feat/fix prefix so the rule does not apply:
  refactor(${SCOPE}): ...
  test(${SCOPE}): ...
  chore(${SCOPE}): ...
  docs(${SCOPE}): ...

Full SOP: ~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md
EOF
  exit 1
fi

# Path 2 — Linear-key subject `<KEY>: <title>` (HMB-24).
# Only fires when the commit isn't a Conventional-Commits prefix that
# already opts out (chore/docs/test/style/refactor/build/ci/perf scoped).
if [[ "$SUBJECT" =~ ^[A-Z]{2,4}-[0-9]+:[[:space:]] ]]; then
  STAGED=$(git diff --cached --name-only 2>/dev/null || echo "")
  if [[ -z "$STAGED" ]]; then
    exit 0
  fi

  RESOLVED=$(app_from_staged_paths "$STAGED")
  if [[ -z "$RESOLVED" ]]; then
    # No single covering app → exempt (multi-app or no-app commit).
    exit 0
  fi

  APP_REL="${RESOLVED%%$'\t'*}"
  CHANGELOG_REL="${RESOLVED##*$'\t'}"
  APP_DIR="$REPO_ROOT/$APP_REL"

  # App must have adopted a CHANGELOG.
  if [[ ! -d "$APP_DIR" ]] || [[ ! -f "$REPO_ROOT/$CHANGELOG_REL" ]]; then
    exit 0
  fi

  # CHANGELOG staged in this commit → compliant.
  if printf '%s\n' "$STAGED" | grep -Fxq "$CHANGELOG_REL"; then
    exit 0
  fi

  # `Changelog skipped: <reason>` trailer in body → audited opt-out.
  if printf '%s\n' "$MSG_CLEAN" | grep -Eiq '^Changelog skipped:[[:space:]]+\S'; then
    exit 0
  fi

  KEY="${SUBJECT%%:*}"
  cat >&2 <<EOF

HOMEBASE-SOP-001 VIOLATION — ${KEY} commit on ${APP_REL}/ did not update the app CHANGELOG.

Subject:   ${SUBJECT}
Expected:  either ${CHANGELOG_REL} staged in this commit (with a new
           line under '## [Unreleased]') OR a 'Changelog skipped: <reason>'
           trailer in the commit body.

Linear-keyed commits that touch a single app's source tree are
treated as user-facing by default — they are how product features
ship — and MUST land an Unreleased entry in the same commit. This
closes the gap that previously let \`<KEY>: <title>\` subjects skate
past the older feat/fix-only check.

Fix:
  1. Open ${CHANGELOG_REL}
  2. Under '## [Unreleased]', add a bullet to the right section:
       ### Added   — new capabilities
       ### Changed — modifications to existing behavior
       ### Fixed   — bug fixes
  3. Stage it:  git add ${CHANGELOG_REL}
  4. Re-run the commit.

If this commit is genuinely not user-visible (internal refactor that
does not change behavior, test-only change, build/CI tweak, internal
governance), add a body trailer:

  Changelog skipped: <one-sentence reason>

Expect TPM to challenge the skip on audit.

Full SOP: ~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md
EOF
  exit 1
fi

# Subject doesn't match either path — exempt.
exit 0
