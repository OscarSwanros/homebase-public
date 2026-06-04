#!/usr/bin/env bash
# homebase roadmap bootstrap — one-shot workspace initialisation.
#
# Creates canonical teams + labels (optionally initial Projects and a quarterly
# Initiative), then captures IDs into per-project project.yml.
#
# Idempotent: existing teams/labels are skipped on re-run.
#
# Credentials: reads LINEAR_API_KEY from env or ~/.config/homebase/env.
# Authorisation: requires LINEAR_TPM_AUTHORIZED=1 for actual execution.
#
# Canonical source: ~/code/homebase/scripts/roadmap/bootstrap.sh
# Delegates to scripts/roadmap/linear.rb.
# See HOMEBASE-SOP-013 § Bootstrap Procedure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec ruby "$SCRIPT_DIR/linear.rb" bootstrap "$@"
