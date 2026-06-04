---
name: migrate-machine
description: "HOMEBASE-SOP-014 first-run on a new Mac. Use when setting up a new machine, restoring after a wipe, or troubleshooting a freshly migrated Claude Code environment. Walks the SOP-014 verification gate via 'homebase bootstrap' and triages any failures."
---

# Migrate Machine — HOMEBASE-SOP-014 Wrapper

Drive a transparent setup on a new Mac. Read SOP-014, run `homebase bootstrap`, interpret each result, and walk the user through the small set of prompts that no automation can avoid (Apple ID 2FA, possible Google MCP re-consent, etc.).

## Canonical Process

Follow **HOMEBASE-SOP-014** in order:

- **Phase 0**: Pre-migration prep on the OLD Mac (commit/push, Brewfile dump, baseline `homebase status`, recovery codes, mode check on `~/.config/homebase/env`).
- **Phase 1**: Primary path — macOS Migration Assistant (Thunderbolt; account username MUST be `youruser`).
- **Phase 2**: Run `homebase bootstrap` on the new Mac.
- **Phase 3**: MCP and Claude Code verification (this skill drives this phase).
- **Phase 4**: Fallback path — scripted bundle (only if Migration Assistant is unavailable).

See `@~/code/homebase/sops/HOMEBASE-SOP-014-MACHINE_MIGRATION.md` for full step detail, the architecture-switch and username-drift sections, and the known caveats list.

## When to invoke

Use `/migrate-machine` when the user:

- Just sat down at a new Mac for the first time.
- Restored from a wipe or hardware failure.
- Asks about resuming work on a machine that hasn't run homebase before.
- Reports symlink, MCP, or auth issues that look like a fresh-clone state.

Do **not** invoke for routine `homebase status` checks on an already-set-up machine — that's just `homebase status <project>`.

## Procedure

### Step 1: Confirm context

Confirm with the user before running anything destructive-feeling: "Is this a brand-new Mac (first run) or a re-verification of an already-migrated machine?" Both are valid; the answer changes how you interpret WARNs.

If the answer is "brand new" and Migration Assistant has NOT been run yet, stop and walk the user through SOP-014 Phase 0 + Phase 1 first. `homebase bootstrap` cannot bootstrap a machine that doesn't yet have `~/code/homebase` cloned.

**Sanity-check the account username before bootstrap.** Run `whoami` and confirm it returns `youruser`. SOP-014 § Phase 1 Step 2 calls this username "non-negotiable" — every absolute path in `~/.claude/settings.json` and every homebase symlink target depends on it. If `whoami` returns anything else, do NOT run `homebase bootstrap`; surface SOP-014 § Username drift to the user and walk through that recovery path first.

### Step 2: Run `homebase bootstrap`

```sh
homebase bootstrap
```

Read the output carefully. Each section prints `[OK]`, `[WARN]`, or `[FAIL]`. The summary line names the totals.

### Step 3: Triage failures

For each `[FAIL]`, apply the documented remediation from SOP-014 and re-run `homebase bootstrap`:

| Symptom | Remediation |
|---|---|
| `$HOMEBASE is not a git checkout` | `git clone git@github.com:acme-co/homebase.git ~/code/homebase` |
| `'homebase link' failed` | Read the conflict (usually a real file at `~/.claude/agents/`); merge into homebase, remove the file, re-run. |
| `link-project failed: <path>` | Run `homebase link-project <path>` directly to see the real error. Often a vendored-copy conflict — `homebase migrate <path>` resolves it. |
| `linked but status dirty` | Run `homebase status <path>` for the per-file breakdown. |
| `~/.config/homebase/env does not exist` | Restore from migration bundle, or create with `LINEAR_API_KEY=<key>` then `chmod 600 ~/.config/homebase/env`. |
| `LINEAR_API_KEY entry missing` | Add the line to `~/.config/homebase/env`. |
| `not logged in to github.com` | `gh auth login` — choose SSH, GitHub.com, authorize via browser. |
| `ssh -T git@github.com did not greet` | Confirm `~/.ssh/id_ed25519` (or whichever key is registered) exists and is loaded; `ssh-add ~/.ssh/id_ed25519` if needed. |
| `git user.name / user.email not set` | Restore `~/.gitconfig` from migration bundle, or `git config --global user.name "Operator Name"; git config --global user.email "you@example.com"`. |

For `[WARN]` items: read SOP-014. Most warnings are intentional (e.g., a registered project hasn't been re-cloned yet) and the user decides whether to address now or later.

### Step 4: MCP and Claude Code verification (Phase 3)

After `homebase bootstrap` exits 0, the script's reach ends. Walk the user through SOP-014 Phase 3:

1. Open Claude Code in `~/code/homebase` (or any registered project).
2. On the first tool call to each MCP server, expect: `claude_ai_Gmail`, `claude_ai_Google_Calendar`, `claude_ai_Google_Drive`, `plugin_github_github`, `plugin_chrome-devtools-mcp` connect cleanly. The Google-backed servers may surface a one-tap re-consent on the new device fingerprint — accept once.
3. Confirm `/agents` lists the homebase staff roster.
4. Confirm `/skills` lists the homebase skill set.
5. Make an empty test commit in any project: `git commit --allow-empty -m "chore: post-migration smoke"`. The `commit-msg` hook should fire (proves the project-level symlink chain).
6. If `claude-in-chrome` was active on the source: confirm the Chrome extension is present and authenticated.

Report each step's result back to the user.

### Step 5: Known caveats — talk the user through them

These are first-call prompts no automation can avoid. Surface them to the user as **expected** so they don't read them as failures:

- Apple ID 2FA verification code on first iCloud Keychain access.
- 1Password TouchID re-enrollment on first unlock.
- Google OAuth one-tap re-consent on `claude_ai_*` MCPs.
- GitHub "new device" web prompt on first push from the new Mac.
- Xcode provisioning profile re-download on first iOS build (only relevant if iOS work is active).

### Step 6: Done

Confirm to the user: bootstrap clean + MCP servers connected + test commit fired the hook → migration is transparent. If anything is still red, keep iterating; do not declare done while there are open `[FAIL]` items.

## Related

- `@~/code/homebase/sops/HOMEBASE-SOP-014-MACHINE_MIGRATION.md` — full SOP.
- `~/code/homebase/bin/homebase` — `bootstrap`, `link`, `link-project`, `status` verbs.
- `/finish-work` — for committing the post-migration smoke commit per SOP-001.
