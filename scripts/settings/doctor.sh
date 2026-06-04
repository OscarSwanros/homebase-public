#!/usr/bin/env bash
# homebase settings doctor — verify and recover the user-level Claude Code
# settings symlink (HMB-50).
#
# Background: ~/.claude/settings.json is the user-level Claude Code settings
# file. On a homebase-managed machine it should be a symlink to
# ~/code/homebase/.claude/user-settings.json so the operator's permissions,
# plugin toggles, and preferences port across machines via git.
#
# 'doctor' handles four cases:
#   1. Already a symlink to the canonical → [OK].
#   2. Symlink to a different target → [WARN], manual intervention required
#      (don't clobber).
#   3. Regular file (Claude Code may have atomic-replaced the symlink):
#        - identical contents to canonical → re-symlink, [OK] resynced.
#        - drift → preserve drift (write into canonical), re-symlink,
#          surface a commit hint. Never auto-commits the homebase repo.
#   4. Missing or broken symlink → re-symlink, [OK] linked.
#
# Read-mostly. The only mutations are the recovery moves above. The
# operator-facing principle: doctor never silently destroys state, and
# never makes git commits — drift is surfaced for review.
#
# Canonical source: ~/code/homebase/scripts/settings/doctor.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMEBASE="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colour codes (bail to empty if NO_COLOR is set or stdout isn't a tty)
if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
  C_RED="" C_GREEN="" C_YELLOW="" C_BOLD="" C_RESET=""
else
  C_RED=$'\033[0;31m'
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
fi

ok()    { echo "${C_GREEN}[OK]${C_RESET}    $*"; }
warn()  { echo "${C_YELLOW}[WARN]${C_RESET}  $*" >&2; }
fail()  { echo "${C_RED}[FAIL]${C_RESET}  $*" >&2; }

CANONICAL="$HOMEBASE/.claude/user-settings.json"
USER_SETTINGS="$HOME/.claude/settings.json"

if [[ ! -f "$CANONICAL" ]]; then
  fail "canonical not found at $CANONICAL — pull the homebase repo first"
  exit 1
fi

mkdir -p "$(dirname "$USER_SETTINGS")"

echo "${C_BOLD}homebase settings doctor${C_RESET}"
echo "  user settings: $USER_SETTINGS"
echo "  canonical:     $CANONICAL"
echo

# Case 1+2: existing symlink. Decide based on target.
if [[ -L "$USER_SETTINGS" ]]; then
  current="$(readlink "$USER_SETTINGS")"
  if [[ "$current" == "$CANONICAL" ]]; then
    ok "already linked → $CANONICAL"
    exit 0
  fi
  # Broken symlink (target doesn't exist): replace silently — the symlink
  # was already pointing at nothing useful.
  if [[ ! -e "$USER_SETTINGS" ]]; then
    rm "$USER_SETTINGS"
    ln -s "$CANONICAL" "$USER_SETTINGS"
    ok "replaced broken symlink → $CANONICAL"
    exit 0
  fi
  # Symlink to a different real file — refuse to clobber.
  warn "linked to $current (not $CANONICAL)"
  warn "manual intervention required: remove $USER_SETTINGS, then re-run 'homebase settings doctor'"
  exit 2
fi

# Case 4 (also): missing.
if [[ ! -e "$USER_SETTINGS" ]]; then
  ln -s "$CANONICAL" "$USER_SETTINGS"
  ok "linked $USER_SETTINGS → $CANONICAL"
  exit 0
fi

# Case 3: regular file.
if [[ ! -f "$USER_SETTINGS" ]]; then
  fail "$USER_SETTINGS exists but is neither a symlink nor a regular file"
  exit 1
fi

# Identical to canonical? Just re-symlink.
if cmp -s "$USER_SETTINGS" "$CANONICAL"; then
  rm "$USER_SETTINGS"
  ln -s "$CANONICAL" "$USER_SETTINGS"
  ok "resynced (regular-file contents matched canonical) → $CANONICAL"
  exit 0
fi

# Drift. Preserve operator state by promoting it into the canonical, then
# re-symlinking. Capture the diff size before we mutate the canonical.
drift_lines="$(diff "$USER_SETTINGS" "$CANONICAL" 2>/dev/null | wc -l | tr -d ' ' || echo "?")"
backup="${USER_SETTINGS}.bak-$(date +%Y%m%d-%H%M%S)"
cp "$USER_SETTINGS" "$backup"
cp "$USER_SETTINGS" "$CANONICAL"
rm "$USER_SETTINGS"
ln -s "$CANONICAL" "$USER_SETTINGS"

ok "preserved drift ($drift_lines diff lines) → wrote into $CANONICAL, re-linked $USER_SETTINGS"
warn "drift backed up at $backup"
warn "commit $CANONICAL in the homebase repo to propagate the changes:"
warn "  cd $HOMEBASE && git add .claude/user-settings.json && git diff --cached"
exit 0
