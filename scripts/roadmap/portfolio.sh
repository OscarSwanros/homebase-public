#!/usr/bin/env bash
# homebase roadmap portfolio — terminal summary of active Projects per team.
#
# Read-only. Canonical source: ~/code/homebase/scripts/roadmap/portfolio.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$SCRIPT_DIR/linear.rb" portfolio "$@"
