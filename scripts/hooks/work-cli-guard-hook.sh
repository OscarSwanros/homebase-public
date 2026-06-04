#!/usr/bin/env bash
# Claude Code PreToolUse hook for the Bash tool. Layer 1 of the workflow
# control plane: blocks manual mutations that bypass `homebase work`.
#
# When .homebase/workflow.yml is absent the hook is a NO-OP; the project
# hasn't adopted the contract and existing enforcement (commit-msg / task-
# completed) is authoritative.
#
# When .homebase/workflow.yml is present:
#   - `git status|diff|log|show|blame|branch (-l)|remote -v|rev-parse|ls-files|stash list`,
#     `git add`, `git fetch`, `git pull --ff-only`, `git config --get`,
#     `homebase work *`, `homebase status|list|index|help` → ALWAYS allow.
#   - `git commit` (any form, including --amend) → blocked unless
#     HOMEBASE_WORK_AUTHORIZED=1 OR (no active work-state AND
#     [chore:-prefix subject OR HOMEBASE_OFF_CONTRACT=1]).
#   - `git push` (any form) → blocked unless HOMEBASE_WORK_AUTHORIZED=1.
#   - `git push --force` / `--force-with-lease` to main/master/tag →
#     blocked unless HOMEBASE_FORCE_PUSH_CONFIRMED=1 (Charter red-list).
#   - `git checkout|switch <other-branch>` when work-state exists and
#     target ≠ active branch → blocked unless HOMEBASE_WORK_AUTHORIZED=1.
#   - `git rebase|reset --hard|revert` when work-state exists → blocked
#     unless HOMEBASE_WORK_AUTHORIZED=1.
#   - `git tag` → blocked unless HOMEBASE_WORK_AUTHORIZED=1.
#   - `git branch -D|-d|-f <active>` → blocked unless WORK_AUTHORIZED.
#   - `homebase deploy` / `kamal …` → blocked unless
#     HOMEBASE_DEPLOY_CONFIRMED=1 (Charter red-list).
#
# Returns JSON `{"decision":"block","reason":"..."}` on block; exits 0
# silently to allow.
#
# Canonical source: ~/code/homebase/scripts/hooks/work-cli-guard-hook.sh
# Symlinked into each project via `homebase link-project` (Phase 5).

set -uo pipefail

INPUT=$(cat)

# Extract command via Python (consistent with sibling hooks).
COMMAND=$(echo "$INPUT" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('tool_input', {}).get('command', ''))
" 2>/dev/null) || exit 0

# Trim leading whitespace.
COMMAND_TRIM="${COMMAND#"${COMMAND%%[![:space:]]*}"}"

# ── Locate workflow.yml + work-state.json ─────────────────────────────────────

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
[[ -z "$REPO_ROOT" ]] && exit 0  # not in a git repo, nothing to do

WORKFLOW_YML="$REPO_ROOT/.homebase/workflow.yml"

# Source the workflow loader to resolve the SHA-keyed per-worktree state path
# (HMB-87 B.11). Loader is symlinked into every adopting project at
# scripts/lib/workflow-loader.sh by `bin/homebase link-project`. Idempotent
# source guard prevents double-source when sibling scripts also source it.
if [[ -f "$REPO_ROOT/scripts/lib/workflow-loader.sh" ]]; then
  # shellcheck source=../lib/workflow-loader.sh
  . "$REPO_ROOT/scripts/lib/workflow-loader.sh"
  WORK_STATE="$(work_state_path "$REPO_ROOT" 2>/dev/null || echo "")"
else
  WORK_STATE="$REPO_ROOT/.homebase/work-state.json"
fi

# No workflow.yml → project hasn't adopted the contract; existing
# enforcement (commit-msg + task-completed) handles things.
[[ -f "$WORKFLOW_YML" ]] || exit 0

# Helper: emit JSON block decision and exit silently.
deny() {
  local reason="$1"
  python3 -c "
import sys, json
print(json.dumps({'decision': 'block', 'reason': sys.argv[1]}))
" "$reason"
  exit 0
}

# Determine if a non-finished work-state is active.
work_state_active=0
work_state_branch=""
work_state_app=""
if [[ -f "$WORK_STATE" ]] && command -v jq >/dev/null 2>&1; then
  finished=$(jq -r '.finished // false' "$WORK_STATE" 2>/dev/null || echo "true")
  if [[ "$finished" == "false" ]]; then
    work_state_active=1
    work_state_branch=$(jq -r '.branch // ""' "$WORK_STATE" 2>/dev/null || echo "")
    work_state_app=$(jq -r '.app // ""' "$WORK_STATE" 2>/dev/null || echo "")
  fi
fi

# ── Always-allow patterns ─────────────────────────────────────────────────────

# Read-only git commands.
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+(status|diff|log|show|blame|remote[[:space:]]+-v|rev-parse|ls-files|stash[[:space:]]+list|fsck|reflog|describe|count-objects|grep|ls-tree|cat-file|symbolic-ref|name-rev)\b'; then
  exit 0
fi
# git branch with no destructive flags (just listing/inspection).
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+branch([[:space:]]+(-a|--all|-l|--list|-v|-vv|--show-current|--contains|-r|--remotes))*[[:space:]]*$'; then
  exit 0
fi
# git add (staging).
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+add\b'; then
  exit 0
fi
# git fetch and pull --ff-only (read-only / safe).
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+fetch\b'; then
  exit 0
fi
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+pull[[:space:]]+--ff-only\b'; then
  exit 0
fi
# git config --get / -l (read).
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+config([[:space:]]+--global)?[[:space:]]+(--get|--get-all|-l|--list)\b'; then
  exit 0
fi
# git stash (push, pop, list, show — non-destructive to remote/state).
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+stash\b'; then
  exit 0
fi
# git switch -c (creating a new branch from the current spot — equivalent
# to checkout -b). Allowed because new branches don't disrupt work-state.
# Bare `switch <branch>` is gated below.
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+(switch[[:space:]]+-c|checkout[[:space:]]+-b)\b'; then
  exit 0
fi

# homebase work / read-only verbs.
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*(bin/)?homebase[[:space:]]+(work[[:space:]]+(start|checkpoint|finish|status|cancel|resume|init|ship|help|-h|--help)|status|list|index|register|migrate|link|link-project|bootstrap|sync|sops|roster|help)\b'; then
  exit 0
fi
# homebase render-claudemd is read-or-write but only writes to the project's
# CLAUDE.md (operator-controlled file); allow.
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*(bin/)?homebase[[:space:]]+render-claudemd\b'; then
  exit 0
fi
# homebase roadmap (gated separately by linear-cli-guard for mutations).
if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*(bin/)?homebase[[:space:]]+roadmap\b'; then
  exit 0
fi

# ── Charter red-list: deploy / kamal ──────────────────────────────────────────

if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*((bin/)?homebase[[:space:]]+deploy|(/[^[:space:]]+/)?kamal[[:space:]]+(deploy|setup|app[[:space:]]+exec|env|reboot))\b'; then
  if [[ "${HOMEBASE_DEPLOY_CONFIRMED:-0}" != "1" ]]; then
    deny "Production deploy is a Charter red-list operation. Set HOMEBASE_DEPLOY_CONFIRMED=1 only after explicit operator confirmation. See @~/code/homebase/governance/AUTONOMY_CHARTER.md § Red-list."
  fi
  exit 0
fi

# ── git commit ────────────────────────────────────────────────────────────────

if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+commit\b'; then
  if [[ "${HOMEBASE_WORK_AUTHORIZED:-0}" == "1" ]]; then
    exit 0
  fi
  # When a work-state is active, plain `git commit` is permitted — the
  # commit-msg hook (commit-sop-check.sh) already validates the trailer
  # against scripts/lib/issue-trailer.sh, and finish.sh's gate 4 will
  # re-validate that the trailer matches the active issue. The CLI does
  # not need to wrap every commit. Push remains gated.
  if [[ "$work_state_active" -eq 1 ]]; then
    exit 0
  fi
  # No active work-state. Allow if chore: prefix in the message OR HOMEBASE_OFF_CONTRACT=1.
  if [[ "${HOMEBASE_OFF_CONTRACT:-0}" == "1" ]]; then
    exit 0
  fi
  # Inspect the message: -m "subject" or --message "subject".
  message=""
  if [[ "$COMMAND_TRIM" =~ -m[[:space:]]+\"([^\"]+)\" ]]; then
    message="${BASH_REMATCH[1]}"
  elif [[ "$COMMAND_TRIM" =~ -m[[:space:]]+\'([^\']+)\' ]]; then
    message="${BASH_REMATCH[1]}"
  elif [[ "$COMMAND_TRIM" =~ --message[[:space:]]+\"([^\"]+)\" ]]; then
    message="${BASH_REMATCH[1]}"
  fi
  if [[ -n "$message" ]] && echo "$message" | head -1 | grep -Eiq '^chore(\([^)]+\))?:'; then
    # HMB-86 B.4: when worktree mode is on, bare-chore direct-to-main is
    # the failure mode the chore verb fixes — route the agent into
    # `homebase work chore "<desc>"` so the work lands on a worktree
    # instead of polluting main. The HOMEBASE_OFF_CONTRACT=1 escape hatch
    # is preserved for the unfixable cases (debugging the chore verb
    # itself, post-incident hot patches, etc.) named in
    # AGENT_OPERATING_CONTRACT.md rule 6.
    wt_project_yml="$REPO_ROOT/.homebase/project.yml"
    if [[ -f "$wt_project_yml" ]] && \
       grep -A 2 '^worktree:' "$wt_project_yml" 2>/dev/null | grep -q '^[[:space:]]*enabled:[[:space:]]*true'; then
      deny "Bare 'chore:'-prefix direct-to-main commit blocked: this project has worktree.enabled: true and the chore-verb is the intended path. Run 'homebase work chore \"<desc>\"' to scope this commit to a chore-flavoured worktree (HMB-86). Direct-to-main chore commits are reserved for the unfixable cases (AGENT_OPERATING_CONTRACT.md rule 6): set HOMEBASE_OFF_CONTRACT=1 explicitly to opt out."
    fi
    exit 0
  fi
  # No -m flag (interactive editor) — let it through; the commit-msg hook
  # will re-validate and the operator's editor sees the contract.
  if ! echo "$COMMAND_TRIM" | grep -qE '\-m[[:space:]]'; then
    exit 0
  fi
  deny "Manual \`git commit\` requires either an active work-state (\`homebase work start <KEY>\`), \`homebase work chore \"<desc>\"\` for off-contract chore work, or HOMEBASE_OFF_CONTRACT=1 for the unfixable cases (rule 6). Schema: ~/code/homebase/standards/WORKFLOW_CONTRACT.md § Five-layer enforcement § Layer 1."
fi

# ── git push ──────────────────────────────────────────────────────────────────

if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+push\b'; then
  # Force-push to protected refs is double-gated. Always requires
  # HOMEBASE_FORCE_PUSH_CONFIRMED=1 regardless of work-state or
  # off-contract status (Charter red-list).
  if echo "$COMMAND_TRIM" | grep -qE '\-f\b|--force\b|--force-with-lease\b'; then
    if echo "$COMMAND_TRIM" | grep -qE '\b(main|master)\b|refs/tags/'; then
      if [[ "${HOMEBASE_FORCE_PUSH_CONFIRMED:-0}" != "1" ]]; then
        deny "Force-push to a protected ref is a Charter red-list operation. Set HOMEBASE_FORCE_PUSH_CONFIRMED=1 only after explicit operator confirmation. See @~/code/homebase/governance/AUTONOMY_CHARTER.md § Red-list."
      fi
    fi
  fi
  # Standard pushes: allow when EITHER an active work-state has
  # authorised this shell OR the operator has explicitly opted out
  # of contract enforcement for this push (HMB-18). Off-contract
  # snapshot / chore commits otherwise deadlock — the commit guard
  # accepts OFF_CONTRACT but the push guard previously didn't, so
  # housekeeping commits with no work-state had no legal push path.
  if [[ "${HOMEBASE_WORK_AUTHORIZED:-0}" == "1" ]] || [[ "${HOMEBASE_OFF_CONTRACT:-0}" == "1" ]]; then
    exit 0
  fi
  deny "Manual \`git push\` is forbidden. Use \`homebase work checkpoint --push\` (mid-flight) or \`homebase work finish\` (final) for product work. For chore / off-contract pushes set HOMEBASE_OFF_CONTRACT=1 in your shell."
fi

# ── git checkout / switch <other-branch> when work-state active ──────────────

if [[ "$work_state_active" -eq 1 ]]; then
  if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+(checkout|switch)\b'; then
    # Skip the new-branch creation forms (already allowed above).
    target=""
    if [[ "$COMMAND_TRIM" =~ ^[[:space:]]*git[[:space:]]+(checkout|switch)[[:space:]]+([^[:space:]]+) ]]; then
      target="${BASH_REMATCH[2]}"
    fi
    if [[ -n "$target" && "$target" != "$work_state_branch" && "$target" != "-c" && "$target" != "-b" ]]; then
      if [[ "${HOMEBASE_WORK_AUTHORIZED:-0}" != "1" ]]; then
        deny "Switching branches mid-work-state ($work_state_branch → $target) requires HOMEBASE_WORK_AUTHORIZED=1, or run \`homebase work cancel\` first."
      fi
    fi
  fi
fi

# ── git rebase / reset --hard / revert when work-state active ────────────────

if [[ "$work_state_active" -eq 1 ]]; then
  if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+(rebase|reset[[:space:]]+--hard|revert)\b'; then
    if [[ "${HOMEBASE_WORK_AUTHORIZED:-0}" != "1" ]]; then
      deny "History-rewrites inside an active work-state require HOMEBASE_WORK_AUTHORIZED=1. Use \`homebase work cancel\` to abandon the current state first if rebase/reset is genuinely needed."
    fi
  fi
fi

# ── git tag ───────────────────────────────────────────────────────────────────

if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+tag\b'; then
  # Allow listing (no args, or with -l/--list).
  if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+tag([[:space:]]+(-l|--list|-n|--contains))?[[:space:]]*$'; then
    exit 0
  fi
  if [[ "${HOMEBASE_WORK_AUTHORIZED:-0}" != "1" ]]; then
    deny "Tagging is part of release flow. Use \`homebase work ship <APP> <VERSION>\` or set HOMEBASE_WORK_AUTHORIZED=1 inside an explicit release plan."
  fi
fi

# ── git branch -D / -d / -f when target == active branch ─────────────────────

if [[ "$work_state_active" -eq 1 ]]; then
  if echo "$COMMAND_TRIM" | head -1 | grep -qE '^[[:space:]]*git[[:space:]]+branch[[:space:]]+(-D|-d|-f|--force)\b'; then
    if echo "$COMMAND_TRIM" | grep -qE "\\b${work_state_branch}\\b"; then
      if [[ "${HOMEBASE_WORK_AUTHORIZED:-0}" != "1" ]]; then
        deny "Deleting / force-moving the active work-branch ($work_state_branch) requires HOMEBASE_WORK_AUTHORIZED=1. Use \`homebase work cancel\` to abandon the work-state first."
      fi
    fi
  fi
fi

# Default: allow.
exit 0
