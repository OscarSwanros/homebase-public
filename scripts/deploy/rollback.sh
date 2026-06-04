#!/usr/bin/env bash
# rollback.sh — thin wrapper around `kamal rollback`.
#
# Invoked by bin/homebase cmd_rollback. Do not source — execute.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMEBASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage:
  homebase rollback <app> <env> --to <version> [--yes]

Rolls the named app/env back to a previous container version using
\`kamal rollback\`. The Git repository is NOT modified — this is a
host-side container swap. The Git tag for the currently-live version
stays in place.

If the target version's image is no longer resident on the host, run:
  homebase deploy <app> <env> --version <version>
to redeploy from scratch instead.

Options:
  --to <version>   Target SemVer to roll back to. Required.
  --yes, -y        Skip interactive confirmation.
  -h, --help       Show this help.
EOF
}

APP=""
ENV_ARG=""
TO=""
YES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)      TO="$2"; shift 2 ;;
    --to=*)    TO="${1#--to=}"; shift ;;
    --yes|-y)  YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --*)       DEPLOY_PHASE="args"; err "unknown flag: $1"; usage; exit 2 ;;
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

if [[ -z "$TO" ]]; then
  DEPLOY_PHASE="args"
  err "--to <version> is required (Kamal has no built-in 'previous-deployment' query)"
  err "Check recent tags: git tag -l '$APP/web/*' | sort -V | tail -5"
  exit 2
fi

DEPLOY_PHASE="resolve"
if ! eval "$(ruby "$HOMEBASE/scripts/deploy/resolve.rb" "$HOMEBASE" "$APP" "$ENV_ARG")"; then
  err "resolve failed"
  exit 2
fi

require_cmd kamal

DEPLOY_PHASE="rollback"
info "target: $APP / $ENV_ARG → $TO"
info "kamal config: $HB_KAMAL_CONFIG (in $HB_APP_PATH)"

if [[ "$YES" != "1" ]]; then
  read -r -p "Roll back? (y/N) " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || { info "aborted"; exit 0; }
fi

cd "$HB_APP_PATH"
kamal rollback "$TO" -c "$HB_KAMAL_CONFIG"
ok "rolled back to $TO"

if [[ -n "$HB_HEALTH_URL" ]]; then
  DEPLOY_PHASE="health"
  retry_health "$HB_HEALTH_URL" 10 3 || exit 1
fi
