#!/usr/bin/env bash
# scripts/lib/ac-regex.sh — shared Acceptance Criteria regex constants.
#
# Single source of truth for the two patterns that define a "valid AC section"
# in a Linear issue body. Sourced by:
#   - scripts/work/start.sh             (start-gate; rejects issues at `work start`)
#   - scripts/hooks/linear-cli-guard-hook.sh (create-gate; rejects creations via
#                                             the Linear MCP `save_issue` tool)
#
# Keeping them aligned is structural: if one ever needs to change (e.g. accept
# a heading variant or a different bullet style), updating this file fixes both
# gates in lockstep. Drift between gates = surprise rejections.
#
# Both patterns are PCRE-style and intentionally use `\s` instead of POSIX
# `[[:space:]]` — jq's Oniguruma engine accepts both, but Python's `re` module
# does NOT support POSIX classes, and the linear-cli-guard create-gate runs
# under Python. Keeping the two engines on a common subset is what lets the
# start-gate (jq) and create-gate (Python) share a single source of truth.
#
# Consumers:
#   - scripts/work/start.sh         (jq --arg, called from bash)
#   - scripts/hooks/linear-cli-guard-hook.sh  (re.search, called from Python)
#
# Canonical source: ~/code/homebase/scripts/lib/ac-regex.sh

# ## Acceptance Criteria  (case-insensitive, multi-line; H2 heading only)
AC_HEADING_RE='(?im)^##\s+Acceptance Criteria'

# - [ ] / - [x] / - [X]  (Markdown task-list checkbox; at least one in the body)
AC_CHECKBOX_RE='- \[[ xX]\]'

export AC_HEADING_RE AC_CHECKBOX_RE
