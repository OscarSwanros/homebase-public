#!/usr/bin/env bash
# scripts/lib/bootstrap-helpers.sh — installer fragments used by
# `homebase bootstrap`. Extracted so test code can exercise them without
# running the full bootstrap (which has many other side effects).
#
# Sourced by:
#   - bin/homebase (cmd_bootstrap)
#   - scripts/_test_bootstrap_helpers.sh
#
# Idempotent source guard.
[[ -n "${_BOOTSTRAP_HELPERS_SOURCED:-}" ]] && return 0
_BOOTSTRAP_HELPERS_SOURCED=1

# HMB-87 B.12: pick the operator's shell-rc file based on $SHELL. Defaults
# to ~/.zshrc on macOS (zsh has been the system default since Catalina),
# ~/.bashrc otherwise.
_bootstrap_pick_rc_file() {
  case "${SHELL:-}" in
    */zsh)  echo "$HOME/.zshrc" ;;
    */bash) echo "$HOME/.bashrc" ;;
    *)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "$HOME/.zshrc"
      else
        echo "$HOME/.bashrc"
      fi
      ;;
  esac
}

# HMB-98 (Tier-2 simplification): the HMB-87 B.12 auto-spawn `claude()` shell
# function is removed. The session-spawn-every-`claude` model caused more harm
# than it prevented (see bin/homebase-claude header). This helper STRIPS the
# sentinel-bracketed block from `$rc_file` if present, so `homebase bootstrap`
# uninstalls it on the next run. Sessions then invoke the real `claude` binary
# directly and launch in the main checkout.
#
# Idempotent: a clean no-op when the block is absent. Preserves all other rc
# content (operator lines above and below the block).
#
# Args:
#   $1  rc_file        path to the shell-rc file to clean
#
# Exit codes:
#   0  removed, or already absent — stdout names the action
#   2  rc_file present but not writable — stdout names the warning
_bootstrap_remove_claude_fn() {
  local rc_file="$1"
  local sentinel_open="# >>> homebase: claude session-spawn (HMB-87 B.12) >>>"
  local sentinel_close="# <<< homebase: claude session-spawn (HMB-87 B.12) <<<"

  [[ -f "$rc_file" ]] || { echo "no rc file at $rc_file — nothing to remove"; return 0; }
  if ! grep -Fq "$sentinel_open" "$rc_file" 2>/dev/null; then
    echo "claude() session-spawn block not present in $rc_file (already removed)"
    return 0
  fi
  if [[ ! -w "$rc_file" ]]; then
    echo "$rc_file is not writable — cannot remove claude() session-spawn block"
    return 2
  fi

  local stripped
  stripped="$(mktemp)"
  awk -v sopen="$sentinel_open" -v sclose="$sentinel_close" '
    $0 == sopen { skip = 1; next }
    skip && $0 == sclose { skip = 0; next }
    !skip { print }
  ' "$rc_file" > "$stripped"
  cat "$stripped" > "$rc_file"
  rm -f "$stripped"
  echo "removed claude() session-spawn block from $rc_file (start a new shell; auto-spawn is gone)"
  return 0
}
