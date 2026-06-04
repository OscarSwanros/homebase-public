#!/usr/bin/env bash
# extract-changelog.sh — extract a version's section from a CHANGELOG.md.
#
# Two invocation forms:
#   1. Direct path:   scripts/extract-changelog.sh <changelog-path> <version>
#   2. Resolver form: scripts/extract-changelog.sh <app> <version> [platform]
#
# Form 2 requires the project to ship `.homebase/changelogs.conf` at the
# repo root. The conf file defines a bash function:
#
#   resolve_changelog_path() {
#     local app="$1" platform="${2:-ios}"
#     case "$app" in
#       gascalc)
#         case "$platform" in
#           ios)     echo "iOS/Apps/GasCalc/CHANGELOG.md" ;;
#           android) echo "Android/apps/gascalc/CHANGELOG.md" ;;
#         esac ;;
#       # …
#     esac
#   }
#
# The script sources the conf file and calls `resolve_changelog_path` to
# get the changelog path.
#
# Canonical source: ~/code/homebase/scripts/extract-changelog.sh
# Symlinked into each project — do not duplicate.

set -euo pipefail

if [ $# -lt 2 ]; then
  cat >&2 <<EOF
Usage:
  $0 <changelog-path> <version>
  $0 <app> <version> [platform]

The second form requires .homebase/changelogs.conf defining resolve_changelog_path.
EOF
  exit 1
fi

FIRST="$1"
VERSION="$2"
PLATFORM="${3:-ios}"

# Dispatch: a path-looking first arg goes to form 1; otherwise form 2.
if [[ "$FIRST" == */* || -f "$FIRST" ]]; then
  CHANGELOG="$FIRST"
else
  REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  CONF="$REPO_ROOT/.homebase/changelogs.conf"
  if [ ! -f "$CONF" ]; then
    echo "Error: $CONF not found. Form 2 requires a project-specific changelogs.conf." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$CONF"
  if ! declare -f resolve_changelog_path > /dev/null; then
    echo "Error: resolve_changelog_path not defined in $CONF" >&2
    exit 1
  fi
  CHANGELOG=$(resolve_changelog_path "$FIRST" "$PLATFORM")
  if [ -z "$CHANGELOG" ]; then
    echo "Error: resolve_changelog_path returned empty for app='$FIRST' platform='$PLATFORM'" >&2
    exit 1
  fi
fi

if [ ! -f "$CHANGELOG" ]; then
  echo "Error: $CHANGELOG not found" >&2
  exit 1
fi

# Extract the section between ## [VERSION] and the next ## [ header.
awk -v ver="$VERSION" '
  /^## \[/ {
    if (found) exit
    if (index($0, "[" ver "]") > 0) {
      found = 1
      next
    }
  }
  found { print }
' "$CHANGELOG" | awk 'NF{found=1} found' | awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--){if(lines[i]~/[^ \t]/){last=i;break}} for(i=1;i<=last;i++) print lines[i]}'
# Trailing awk pipeline trims leading and trailing blank lines.
