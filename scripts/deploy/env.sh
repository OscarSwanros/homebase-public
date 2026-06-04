#!/usr/bin/env bash
# env.sh — inspect env vars for a deployed app.
#
# Three sources, chosen by flag:
#   running (default) — `docker exec env` inside the live container.
#                       What's actually running RIGHT NOW.
#   pending           — resolve from the app's local .kamal/secrets.
#                       What the NEXT deploy would inject (useful after
#                       editing ~/.config/homebase/env to verify before shipping).
#
# Default output is key + value length (secrets stay out of scrollback).
# `--values` opts into printing real values.
#
# Invoked by bin/homebase cmd_env. Do not source — execute.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOMEBASE="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<EOF
Usage:
  homebase env <app> <env> [--pending] [--values] [--match <regex>]

Inspect environment variables for a deployed app. Default: reads the
live container on the target host (reflects what's actually running).

Options:
  --pending           Resolve from the app's local .kamal/secrets
                      (what the next deploy would inject). Useful after
                      editing ~/.config/homebase/env to verify changes
                      before shipping.
  --values            Include values in output. Default: lengths only
                      (keeps secrets out of terminal scrollback).
  --match <regex>     Only print keys matching POSIX regex.
  -h, --help          Show this help.
EOF
}

APP=""
ENV_ARG=""
SOURCE="running"
VALUES=0
MATCH=".*"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pending)   SOURCE="pending"; shift ;;
    --running)   SOURCE="running"; shift ;;
    --values)    VALUES=1; shift ;;
    --match)     MATCH="$2"; shift 2 ;;
    --match=*)   MATCH="${1#--match=}"; shift ;;
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

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

case "$SOURCE" in
  running)
    DEPLOY_PHASE="exec"
    HOST="${HB_HOSTS%% *}"
    [[ -z "$HOST" ]] && { err "no host declared for $HB_APP_NAME/$HB_ENV_NAME"; exit 1; }
    CONTAINER="$(ssh -o StrictHostKeyChecking=no "root@$HOST" \
      "docker ps --filter label=service=$HB_APP_NAME --filter label=role=web --format '{{.Names}}' | head -1")"
    [[ -z "$CONTAINER" ]] && { err "no running container for service=$HB_APP_NAME on $HOST"; exit 1; }
    ssh "root@$HOST" "docker exec $CONTAINER env" > "$TMP"
    ;;
  pending)
    DEPLOY_PHASE="pending"
    [[ -f "$HB_APP_PATH/$HB_SECRETS_FILE" ]] || {
      err "secrets file not found: $HB_APP_PATH/$HB_SECRETS_FILE"
      exit 1
    }
    ( cd "$HB_APP_PATH" && env -i HOME="$HOME" PATH="$PATH" bash -c "set -a; . '$HB_SECRETS_FILE'; env" ) > "$TMP"
    ;;
esac

DEPLOY_PHASE="print"

# System / container-runtime / Kamal-metadata vars to hide by default.
# Users can still surface them with `--match`.
SYSTEM_REGEX='^(HOME|PATH|HOSTNAME|SHLVL|PWD|OLDPWD|TERM|_|LANG|LC_|LS_COLORS|KAMAL_)'

if [[ "$VALUES" == "1" ]]; then
  awk -F= -v mr="$MATCH" -v sr="$SYSTEM_REGEX" \
    '$1 ~ sr { next } $1 !~ mr { next } { print }' "$TMP" | sort
else
  awk -F= -v mr="$MATCH" -v sr="$SYSTEM_REGEX" \
    '$1 ~ sr { next } $1 !~ mr { next } { printf "%-40s %d\n", $1, length(substr($0, index($0, "=") + 1)) }' "$TMP" | sort
fi
