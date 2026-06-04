#!/usr/bin/env bash
# scripts/hooks/post-plan-approval-reminder.sh — PostToolUse:ExitPlanMode hook.
#
# HMB-105: when the operator approves a plan, inject a reminder so the agent
# acts on the approved plan instead of re-asking permission for steps already
# in it. This is the "Edge 8" deferral defect: AGENT_OPERATING_CONTRACT.md
# Rules 8 + 13 already say "plan approval is the green-light; do not re-ask",
# but the contract sits in the prompt footer at session start and has decayed
# from the model's attention by the time plan-approval fires (often 50k–100k
# tokens later). This hook puts the rule back in front of the model at exactly
# the moment it's about to slip — a deterministic salience boost, not a brittle
# transcript scanner.
#
# Registered as a PostToolUse hook with matcher "ExitPlanMode" in
# .claude/user-settings.json (fires in every session, every project). It emits
# `additionalContext`, which Claude Code surfaces to the model on its next
# turn. Non-blocking; always exits 0. Degrades to a silent no-op if jq is
# absent (no context injected — never breaks the plan-approval flow).
#
# Canonical source: ~/code/homebase/scripts/hooks/post-plan-approval-reminder.sh

# Drain stdin (Claude Code sends the PostToolUse payload; we don't use it).
cat >/dev/null 2>&1 || true

read -r -d '' REMINDER <<'EOF'
Plan approved. Per AGENT_OPERATING_CONTRACT.md Rules 8 + 13, this approval is the green-light for every green- and yellow-list step that follows from the plan — act, don't re-ask. Delegating to technical-project-manager (or any gatekeeper) is not a separate confirmation. Your next message should be execution or a status update, NOT a permission question ("Want me to…?", "Should I…?", "or do you want to drive…?"). Reserve asks for the red-list (deploy, force-push, money, public comms, architecture).
EOF

if command -v jq >/dev/null 2>&1; then
  jq -n --arg ctx "$REMINDER" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $ctx}}'
fi
exit 0
