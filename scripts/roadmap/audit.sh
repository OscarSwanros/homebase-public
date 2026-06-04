#!/usr/bin/env bash
# homebase roadmap audit — verify live Linear state matches canonical schema.
#
# Read-only. Canonical source: ~/code/homebase/scripts/roadmap/audit.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$SCRIPT_DIR/linear.rb" audit "$@"
