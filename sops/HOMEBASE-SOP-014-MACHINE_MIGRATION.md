# HOMEBASE-SOP-014: Machine Migration

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Canonical procedure for moving the entire homebase-driven working environment to a new Mac (or restoring it after a wipe) with **transparent setup** — sit down at the new machine, open Claude Code, resume work. No re-auth flows beyond what device-binding strictly requires.

## Purpose

The homebase-adopting environment is a distributed identity:

- `~/.claude/` symlinks into `~/code/homebase/` (agents, commands, skills, statusline, agent-signal, **settings.json**).
- `~/.claude/settings.json` is itself a symlink into `homebase/.claude/user-settings.json` (HMB-50). Permissions, plugin toggles, and operator preferences are tracked in git and ride along with `homebase` to every Mac. Pre-symlink local state is moved aside to `~/.claude/settings.json.bak-<timestamp>` on first run.
- 1+ GB of resumable session history under `~/.claude/projects/`.
- Keychain-resident auth for `gh`, the `claude_ai_*` MCP servers, the Anthropic Claude Code login, Google OAuth, GitHub plugin OAuth, 1Password.
- `~/.config/homebase/env` (Linear API key, mode `600`) — the only place the Linear key lives outside the keychain.
- Per-project symlinks injected by `bin/homebase link-project` into every repo registered in `registry/projects.paths`.

Reauthorising every component from scratch costs a workday and quietly breaks MCP tool availability mid-session. This SOP locks in the cheap path and documents the unavoidable corners.

## Scope

Mac-to-Mac migration. macOS only. Both source and destination must run a current macOS. The procedure assumes the destination account is named `youruser` — see § Username drift below.

## Trigger

- Replacing the primary development Mac.
- Restoring after a wipe or hardware failure.
- Setting up a secondary Mac that should mirror the primary's environment.

---

## Phase 0 — Pre-migration prep (OLD machine)

Run all of this before touching the new Mac.

1. **Commit and push everything.** For each path in `registry/projects.paths`:

   ```sh
   for p in $(grep -v '^#' ~/code/homebase/registry/projects.paths); do
     echo "=== $p ==="
     git -C "$p" status --short
     git -C "$p" log @{u}..HEAD --oneline 2>/dev/null || true
   done
   ```

   Resolve uncommitted work, then push. Migration Assistant carries uncommitted state, but pushed-to-remote is the real backstop.

2. **Dump Brewfile** — `brew bundle dump --file=~/Brewfile --force`. Cheap insurance even when source and destination share an architecture.

3. **Baseline `homebase status`** on every active project so the post-migration run has something to compare against:

   ```sh
   for p in $(grep -v '^#' ~/code/homebase/registry/projects.paths); do
     ~/code/homebase/bin/homebase status "$p"
   done
   ```

4. **Recovery codes accessible.** Print or open in 1Password: Apple ID, GitHub, Linear, Google, 1Password emergency kit. At least one of these will demand a code on first use of the new device.

5. **Confirm `~/.config/homebase/env` exists and is mode 600.** `ls -la ~/.config/homebase/env`. The file body matters — Migration Assistant will carry it intact, but verify it again on the new Mac.

6. **Do not sign out of anything.** Apple ID, iCloud, 1Password, Anthropic Claude Code, browser sessions — all stay signed in on the source until migration completes. Signing out invalidates device-trust tokens that Migration Assistant would otherwise carry.

---

## Phase 1 — Primary path: macOS Migration Assistant

Migration Assistant is the only way to reach "transparent" without bespoke tooling. It carries `~/Library/Keychains/login.keychain-db` (the gh token, Google OAuth refresh tokens, Anthropic Claude Code login token, 1Password vault unlock, Apple Developer code-signing certs), the entire user home including `~/.claude/`, `~/.ssh/`, `~/.gitconfig`, shell rc files, `~/.config/`, `~/code/`, and the Homebrew installation.

1. **Boot the new Mac** and complete Setup Assistant.
2. **Set the account username to `youruser`.** This is non-negotiable. The absolute paths in `~/.claude/settings.json` (now a symlink to `homebase/.claude/user-settings.json` per HMB-50), every homebase symlink target (`~/.claude/agents → /Users/youruser/code/homebase/agents`), and every `@~/code/homebase/...` SOP reference depend on it. See § Username drift if this constraint cannot be met.
3. **Use the same Apple ID** to maintain iCloud Keychain continuity.
4. At "Transfer Information to This Mac": choose **From a Mac, Time Machine backup, or Startup disk** → connect via **Thunderbolt 3/4 cable**. Wi-Fi works but is 10–30× slower; the `~/.claude/projects/` payload alone makes wired transfer worth the cable.
5. Select user account `youruser`, Applications, Other files & folders, Computer & network settings. Expect 1–4 hours over Thunderbolt depending on disk size.
6. On reboot, log into `youruser`. macOS prompts for the login keychain password (same as old Mac). Approve any 2FA prompts that fire on the source for Apple ID, iCloud, iMessage device trust.
7. Open Terminal. Confirm `~/code/homebase/bin` is on `PATH` from `~/.zshrc`: `which homebase`.

---

## Phase 2 — Run `homebase bootstrap`

`bin/homebase bootstrap` is the single command that performs the verification gate. It is idempotent — safe to run repeatedly. It re-runs `link` (which now also symlinks `~/.claude/settings.json` → `homebase/.claude/user-settings.json` per HMB-50), invokes `homebase settings doctor` to surface the settings symlink status, walks every path in `registry/projects.paths` and runs `link-project` + `status` on each, validates `~/.config/homebase/env`, checks `gh` auth, tests SSH to GitHub, and confirms git identity.

```sh
homebase bootstrap
```

Each step prints `[OK]`, `[WARN]`, or `[FAIL]`. The summary line names the totals; non-zero exit code if any step fails.

**Expected outcome on a transparent migration:** every step `[OK]` except possibly:

- A `[WARN]` for any project path in the registry that hasn't been re-cloned yet (intentional — the script doesn't auto-clone).
- A `[FAIL]` on `gh auth status` if the keychain didn't carry over the GitHub token. Remediation: `gh auth login` and re-run.

For each `[FAIL]`, the script prints the specific remediation. Apply it, then re-run `homebase bootstrap` until clean.

---

## Phase 3 — MCP and Claude Code verification

`bin/homebase bootstrap` cannot introspect MCP server state — that requires Claude Code running. Open Claude Code in `~/code/homebase`:

1. Confirm the MCP servers connect on first tool call: `claude_ai_Gmail`, `claude_ai_Google_Calendar`, `claude_ai_Google_Drive`, `plugin_github_github`, `plugin_chrome-devtools-mcp`. The Google-backed ones may surface a one-tap re-consent on a new device fingerprint — accept once.
2. Confirm `/agents` lists the homebase staff roster.
3. Confirm `/skills` lists `migrate-machine` (and the rest of the homebase skill set).
4. Make an empty test commit in any project — `git commit --allow-empty -m "chore: post-migration smoke"` — and confirm the `commit-msg` hook fires (proves the project-level symlink chain).

If `claude-in-chrome` was active on the source: confirm the extension is present in Chrome and authenticated. Migration Assistant carries `~/Library/Application Support/Google/Chrome/`, so the extension and its installed state come across. If Chrome Sync is on, that is a second redundant restore path.

---

## Phase 4 — Fallback path: scripted bundle (Migration Assistant unavailable)

Use only when the source Mac is offline, the destination arrived first, or both machines cannot share a network.

1. **On the OLD Mac**, build the bundle:

   ```sh
   tar --exclude='.claude/plugins' \
       --exclude='.claude/cache' \
       --exclude='.claude/paste-cache' \
       --exclude='.claude/file-history' \
       --exclude='.claude/backups' \
       --exclude='.claude/shell-snapshots' \
       --exclude='.claude/telemetry' \
       --exclude='.claude/statsig' \
       -czf ~/migration-bundle.tar.gz \
       -C "$HOME" .claude .ssh .gitconfig .zshrc .zprofile .config Brewfile
   ```

2. **Export the login keychain** (carries gh token, Google OAuth, Anthropic login):

   ```sh
   security export -k ~/Library/Keychains/login.keychain-db -o ~/login-keychain-export.p12
   ```

   Carry this `.p12` separately.

3. **Move both files to the NEW Mac** via USB or another secure channel.

4. **On the NEW Mac:**
   - Install Homebrew (`/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`).
   - `brew bundle --file=~/Brewfile`.
   - Untar: `tar -xzf ~/migration-bundle.tar.gz -C "$HOME"`.
   - Import the keychain via **Keychain Access** GUI (File → Import Items, choose the `.p12`, target the login keychain). Authorise each item to be used by `gh`, `ssh`, `Claude`, etc., when first prompted.
   - Re-clone repositories that weren't bundled: `git clone git@github.com:acme-co/homebase.git ~/code/homebase`, plus each project repo.
   - Run `homebase bootstrap`.

The fallback path will likely require one OAuth re-consent on `claude_ai_*` MCPs and a fresh trust prompt on Apple ID — not transparent, but recoverable.

---

## Known caveats — manually re-confirm even with Migration Assistant

These are first-call prompts that no automation can avoid:

- **Apple ID 2FA trust** — first iCloud Keychain access prompts for a verification code from another trusted device.
- **1Password TouchID** — re-enroll Touch ID for unlock; vault contents and emergency-kit-derived account key migrate intact.
- **Google OAuth on `claude_ai_*` MCPs** — the refresh token is keychain-resident and migrates, but the first call may surface a one-tap re-consent on the new device fingerprint.
- **GitHub "new device" web prompt** — server-side fingerprint may flag a new-device login. Approve once.
- **Apple Developer provisioning profiles** — keychain-resident certs migrate; Xcode may need to re-download profiles. Only relevant if iOS work is active.

---

## Architecture switch — Apple Silicon ↔ Intel

If source and destination architectures differ:

1. After Migration Assistant completes, `brew bundle --file=~/Brewfile` to rebuild bottles for the new architecture.
2. Any binaries Claude Code's `plugins/` directory cached are also architecture-bound; the harness re-downloads them on first use, no manual action needed.

Same-architecture migrations skip both steps — Migration Assistant carries `/opt/homebrew` (Apple Silicon) intact.

---

## Username drift — non-recommended path

If the new account cannot be `youruser` (corporate provisioning, multi-user Mac, etc.), expect breakage in:

- The absolute paths inside `homebase/.claude/user-settings.json` (the canonical user-level settings file `~/.claude/settings.json` symlinks to per HMB-50). They are tracked in git, so editing them is a deliberate review-and-commit rather than a re-prompt loop, but they still need updating once for the new home.
- Every homebase symlink target stored as an absolute `/Users/youruser/...` path. Migration Assistant carries the symlinks, but they will resolve to nonexistent paths.
- Every `@~/code/homebase/...` reference resolves correctly because `~` expands to the new account's home — these are unaffected.

Recovery procedure (only if username drift is unavoidable):

1. Move `~/code/homebase/` under the new home directory (Migration Assistant places it there automatically).
2. Re-run `homebase link` and `homebase link-project <each-project>` so the symlinks point at `$HOME/code/homebase/...` paths instead of the old user's. `homebase link` will move the pre-existing `~/.claude/settings.json` (if any) aside to `~/.claude/settings.json.bak-<timestamp>` and replace it with a symlink to `homebase/.claude/user-settings.json`.
3. Run `homebase settings doctor` to confirm the symlink resolves; if absolute `/Users/youruser/...` paths inside `homebase/.claude/user-settings.json` need updating to the new username, edit + commit them in homebase like any other governance change.

`homebase bootstrap` chains all three steps and is the recommended entry point on the new account's first login.

---

## Related

- `@~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` — issue-first rule applies to post-migration verification commits.
- `@~/code/homebase/sops/HOMEBASE-SOP-003-DOCUMENTATION_GOVERNANCE.md` — file-placement and `@`-ref rules this SOP follows.
- `~/code/homebase/bin/homebase` — `bootstrap`, `link`, `link-project`, `status` verbs used throughout.
- `~/code/homebase/skills/migrate-machine/SKILL.md` — Claude-driven wrapper that walks this SOP on the new Mac.
