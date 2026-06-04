#!/usr/bin/env bash
# homebase roadmap capture <app> — refresh Linear IDs into <project>/.homebase/project.yml.
#
# Canonical source: ~/code/homebase/scripts/roadmap/capture.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$SCRIPT_DIR/linear.rb" capture "$@"
