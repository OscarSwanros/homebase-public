#!/usr/bin/env bash
# console.sh — open an interactive session against a deployed app.
#
# Default: runs `kamal console` (the app's `aliases.console` in its Kamal
# config — typically `bin/rails console` for Rails apps).
# --shell: runs `kamal shell` instead (app's `aliases.shell`, typically `sh`).
# Useful for apps without a language-level REPL (Go, static sites, etc.).
#
# Invoked by bin/homebase cmd_console. Do not source — execute.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMEBASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage:
  homebase console <app> <env> [--shell]

Opens an interactive session against the running container for <app> in
<env>. Default: the app's \`console\` alias (typically \`bin/rails console\`
for Rails apps). \`--shell\` uses the \`shell\` alias (typically \`sh\`).

Options:
  --shell             Drop into \`sh\` instead of \`console\`. Use for apps
                      without a language-level REPL (Go services, static
                      sites, etc.).
  -h, --help          Show this help.
EOF
}

APP=""
ENV_ARG=""
KAMAL_VERB="console"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --shell)     KAMAL_VERB="shell"; shift ;;
    --console)   KAMAL_VERB="console"; shift ;;
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

DEPLOY_PHASE="resolve"
if ! eval "$(ruby "$HOMEBASE/scripts/deploy/resolve.rb" "$HOMEBASE" "$APP" "$ENV_ARG")"; then
  err "resolve failed"
  exit 2
fi

cd "$HB_APP_PATH"
exec kamal "$KAMAL_VERB" -c "$HB_KAMAL_CONFIG"
