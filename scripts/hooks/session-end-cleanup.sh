#!/usr/bin/env bash
# scripts/hooks/session-end-cleanup.sh — Stop hook (intentionally a no-op).
#
# HMB-98 (Tier-2 simplification): this hook used to destroy "empty" session-
# worktrees on Claude exit (HMB-87 B.12). That destruction was the single
# largest source of session-breakage — it ran on a heuristic ("zero commits
# beyond base AND no work-state file → delete") on every Stop event, not only
# at true session exit, and repeatedly deleted the worktree out from under a
# live session, invalidating the parent process's CWD and breaking every
# subsequent tool call.
#
# The auto-spawn model that minted those session-worktrees was removed
# (bin/homebase-claude is now a pass-through), so HOMEBASE_SESSION_WORKTREE is
# never exported and there is nothing for this hook to clean up. Worktrees are
# now created only by `homebase work start` / `homebase work chore` and
# destroyed only by the explicit `homebase work finish` / `cancel` verbs —
# never by a Stop hook.
#
# This file remains (still wired in .claude/settings.json hooks.Stop and
# symlinked into projects) as a documented no-op so the wiring doesn't need to
# change in lockstep across every consuming project. It drains stdin and exits
# 0. Do not reintroduce worktree destruction here.

# Drain stdin (Claude Code sends a JSON payload; we don't use it).
cat >/dev/null 2>&1 || true

exit 0
