#!/usr/bin/env bash
# scripts/work/rescue.sh — `homebase work rescue [<issue>...] [--apply] [--all]`
#
# HMB-103: detect and recover work-states that finished cleanly
# (finished: true, finish_outcome: "done") but whose Linear issue is stranded
# "In Progress" — the chore-with-issue bug that left TBL-551/552/553 stuck.
# The finish.sh fix prevents NEW occurrences; this verb cleans up existing ones.
#
#   homebase work rescue                 — report every stuck issue (all projects)
#   homebase work rescue --apply --all   — transition every stuck issue → Done
#   homebase work rescue KEY-1 KEY-2 --apply   — transition only the named ones
#
# Mutations (--apply) require LINEAR_TPM_AUTHORIZED=1 (linear.rb gate, SOP-013).
# Scans every project root listed in registry/projects.paths.

set -uo pipefail

WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HOMEBASE="$(cd "$WORK_DIR/../.." && pwd -P)"
LINEAR_RB="$HOMEBASE/scripts/roadmap/linear.rb"
# HOMEBASE_PROJECTS_PATHS overrides the registry for tests; defaults to canon.
PATHS_FILE="${HOMEBASE_PROJECTS_PATHS:-$HOMEBASE/registry/projects.paths}"

APPLY=0
ALL=0
KEYS=()
while (($#)); do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --all)   ALL=1; shift ;;
    -h|--help)
      echo "usage: homebase work rescue [<issue>...] [--apply] [--all]"
      echo "  (no flags)        report stuck issues (finished+done, Linear still In Progress)"
      echo "  --apply --all     transition every stuck issue to Done"
      echo "  KEY-N ... --apply transition only the named issues"
      exit 0 ;;
    -*) echo "rescue: unknown flag $1" >&2; exit 2 ;;
    *)  KEYS+=("$1"); shift ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "rescue: jq is required" >&2; exit 2; }
[[ -f "$PATHS_FILE" ]] || { echo "rescue: registry/projects.paths not found" >&2; exit 2; }

# ── Collect stuck states across every registered project ──────────────────────
S_ISSUE=(); S_FILE=(); S_ROOT=(); S_WHEN=()
while IFS= read -r root; do
  [[ -z "$root" || ! -d "$root/.homebase" ]] && continue
  for sf in "$root"/.homebase/work-state.*.json; do
    [[ -f "$sf" ]] || continue
    line="$(jq -r 'select(.finished == true and .finish_outcome == "done" and .linear_state_now == "In Progress")
                   | [(.issue // ""), (.finished_at // "")] | @tsv' "$sf" 2>/dev/null)"
    [[ -z "$line" ]] && continue
    issue="${line%%$'\t'*}"
    when="${line#*$'\t'}"
    [[ -z "$issue" ]] && continue
    S_ISSUE+=("$issue"); S_FILE+=("$sf"); S_ROOT+=("$root"); S_WHEN+=("$when")
  done
done < "$PATHS_FILE"

if [[ ${#S_ISSUE[@]} -eq 0 ]]; then
  echo "rescue: no stuck issues found (finished+done with Linear still In Progress)."
  exit 0
fi

echo "Stuck issues (finished cleanly, Linear still In Progress):"
for i in "${!S_ISSUE[@]}"; do
  printf '  %-12s finished %s  %s\n' "${S_ISSUE[$i]}" "${S_WHEN[$i]:-?}" "${S_FILE[$i]}"
done

if [[ $APPLY -eq 0 ]]; then
  echo
  echo "(report only — re-run with --apply --all, or --apply naming specific issues, to transition them to Done)"
  exit 0
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
if [[ "${LINEAR_TPM_AUTHORIZED:-0}" != "1" ]]; then
  echo "rescue --apply requires LINEAR_TPM_AUTHORIZED=1 (SOP-013)." >&2
  exit 2
fi
if [[ $ALL -eq 0 && ${#KEYS[@]} -eq 0 ]]; then
  echo "rescue --apply requires either specific issue keys or --all (refusing to transition everything implicitly)." >&2
  exit 2
fi

echo
rescued=0
fail=0
for i in "${!S_ISSUE[@]}"; do
  issue="${S_ISSUE[$i]}"; sf="${S_FILE[$i]}"; root="${S_ROOT[$i]}"; when="${S_WHEN[$i]}"
  if [[ $ALL -eq 0 ]]; then
    match=0
    for k in "${KEYS[@]}"; do [[ "$k" == "$issue" ]] && match=1 && break; done
    [[ $match -eq 0 ]] && continue
  fi
  if ruby "$LINEAR_RB" issue move "$issue" Done >/dev/null 2>&1; then
    tmp="$(mktemp)"
    if jq '.linear_state_now = "Done"' "$sf" > "$tmp" 2>/dev/null; then mv "$tmp" "$sf"; else rm -f "$tmp"; fi
    printf '%s\trescued\t%s\tfinished=%s\thomebase work rescue (HMB-103)\n' \
      "$(date -u +%FT%TZ)" "$issue" "${when:-?}" >> "$root/.homebase/work-state.audit.log"
    echo "  rescued $issue → Done"
    rescued=$((rescued + 1))
  else
    echo "  FAILED to transition $issue (Linear move rejected — check the team's 'Done' state name)" >&2
    fail=$((fail + 1))
  fi
done

echo
echo "rescued $rescued issue(s)$([[ $fail -gt 0 ]] && echo ", $fail failed")."
[[ $fail -gt 0 ]] && exit 1
exit 0
