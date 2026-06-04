#!/usr/bin/env bash
# Shared regexes for issue-reference trailer validation. Sourced by every
# hook that needs to recognise (or reject) a `Closes #N` / `Closes KEY-N`
# trailer line. Single source of truth — do not duplicate these patterns in
# individual hooks.
#
# Sourced by:
#   - scripts/hooks/commit-sop-check.sh
#   - scripts/hooks/task-completed.sh
#
# Canonical policy: ~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md
# §0 (Linear-first tracking) and §B2 (Issue Reference Trailers).
#
# This file is symlinked into each homebase-adopting project by
# `bin/homebase link-project`. Do not edit copies.

# ── Issue identifier shape ─────────────────────────────────────────────────────
#
# Accepts either:
#   GitHub:  #N        (e.g. #412)
#   Linear:  KEY-N     (e.g. TFD-123, HMB-7) — KEY is 2-5 uppercase letters
#
# The validator does not enforce that KEY is one of the canonical Linear teams
# — Linear rejects unknown keys server-side. The local check is shape-only.
ISSUE_REF_RE='(#[0-9]+|[A-Z]{2,5}-[0-9]+)'

# ── Valid trailer keywords ─────────────────────────────────────────────────────
#
# The set matches what `commit-sop-check.sh` historically accepted (case-
# insensitively, via `grep -Ei`):
#
#   Refs            — intermediate work; does not auto-close
#   Closes / Close / Closed
#   Fixes  / Fix   / Fixed
#   Resolves / Resolve / Resolved
#
# `References` is DELIBERATELY EXCLUDED — it is listed as an anti-pattern in
# SOP-001 §B2 because it reads correctly to a human but is not a GitHub /
# Linear auto-close keyword. The anti-pattern set is the inverse of this set
# minus shared tokens; see ANTI_PATTERN_KEYWORDS_RE below.
TRAILER_KEYWORDS_RE='Refs|Closes|Close|Closed|Fixes|Fix|Fixed|Resolves|Resolve|Resolved'

# ── Anti-pattern trailer keywords ──────────────────────────────────────────────
#
# Plausible English that reads like a closing keyword but is NOT recognised
# by GitHub's or Linear's auto-close parser. A commit with only one of these
# leaves the issue open — the automation the SOP is designed to drive
# silently breaks.
#
# Matched case-insensitively via `grep -Ei`.
ANTI_PATTERN_KEYWORDS_RE='Part of|Related( to)?|See|References|Ref|Relates to'

# ── Composite line patterns ────────────────────────────────────────────────────
#
# These match a full trailer line (anchored). Use with `grep -E` (case-
# sensitive prefix) or `grep -Ei` (case-insensitive prefix) depending on
# caller requirements; both hooks currently use `grep -Ei`.
TRAILER_LINE_RE="^(${TRAILER_KEYWORDS_RE})[[:space:]]+${ISSUE_REF_RE}[[:space:]]*$"
ANTI_PATTERN_LINE_RE="^(${ANTI_PATTERN_KEYWORDS_RE})[[:space:]]+${ISSUE_REF_RE}[[:space:]]*$"

# ── Match-anywhere trailer pattern (for task-completed.sh's last-commit check) ─
#
# Less strict than TRAILER_LINE_RE: matches a keyword followed by an
# identifier anywhere on a line, not anchored. Used by `task-completed.sh`
# to check whether the last commit references an issue at all.
TRAILER_ANYWHERE_RE="(${TRAILER_KEYWORDS_RE}) ${ISSUE_REF_RE}"
