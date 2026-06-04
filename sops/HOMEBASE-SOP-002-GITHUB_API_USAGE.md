# HOMEBASE-SOP-002: GitHub API Usage

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Canonical procedure for routing all GitHub API access through the technical-project-manager (TPM) agent.

## Purpose

Prevent GitHub API rate-limit exhaustion across every homebase-adopting project. GitHub imposes hard limits of 5,000 requests/hour (REST) and 5,000 points/hour (GraphQL). Without coordination, concurrent agents and the root conversation burn through the quota unpredictably, breaking release operations, doc audits, and issue triage.

## Scope

All agents, all projects, all root Claude conversations. No exceptions.

## The Rule

**Only the technical-project-manager agent runs `gh` CLI commands or makes GitHub API calls.** No other agent — and not the root conversation — should execute `gh` commands directly.

Enforcement is automated: `scripts/hooks/gh-cli-guard-hook.sh` is wired into every homebase-adopting project's `.claude/settings.json` as a `PreToolUse[Bash]` hook. Direct `gh` invocations are blocked with an error unless the environment variable `TPM_AUTHORIZED=1` is set (TPM sets this when executing a batch).

### Sibling rule: Linear API (HOMEBASE-SOP-013)

TPM is **also** the sole gatekeeper for Linear API operations. One agent, two APIs. The equivalent PreToolUse hook is `scripts/hooks/linear-cli-guard-hook.sh`; the equivalent authorisation flag is `LINEAR_TPM_AUTHORIZED=1`. Rate-limit discipline, batching, and snapshot-after-mutation requirements are documented in SOP-013. Read-only roadmap verbs (`homebase roadmap render`, `audit`, `portfolio`) may run without authorisation.

---

## For Non-TPM Agents

When you need GitHub data or operations:

1. **DO NOT** run `gh` commands yourself. The hook will block you.
2. **Return a structured request** describing what you need. Example:

   ```
   Action: create-issue
   Title: "GasCalc iOS: Add gas density warning"
   Labels: gascalc, enhancement, P2, ios
   Body file: /tmp/issue-body.md
   Post-creation: set-project-fields --project gascalc --issue {N} --release v1.2 --phase "2: New Tools"
   Epic: link as sub-issue of #1315
   ```

   Other examples:
   - "Need issue #100 details (title, labels, assignees)"
   - "Need to list all open issues with label `logapp-v1.0`"
   - "Need to set Release=v1.1, Phase='2: New Tools' on issue #610 in the gascalc project"

3. The root conversation accumulates requests and delegates them to TPM in a batch.

## For Root Claude

When you or an agent needs GitHub operations:

1. **Accumulate** requests across the current work.
2. **Spawn the TPM agent** with the batch.
3. TPM executes with rate limiting, coalescing, and caching.
4. Use the returned results to continue.

## For TPM (Executing Requests)

When receiving a batch of GitHub API requests:

1. **Check rate limit status**: `gh api rate_limit --cache 30s`.
2. **Read cache**: check `.claude/github-api-cache.json` for cached responses within TTL.
3. **Group requests**: execute all reads before any mutations.
4. **Coalesce reads**: prefer list queries over individual gets when they overlap. (Example: three `gh issue view` calls for #100, #101, #102 all labeled `X` → one `gh issue list --label X`.)
5. **Execute reads** with `--cache 60s` where applicable.
6. **Execute mutations** with a minimum 1-second delay between each (use `gh_mutate_delay` from `scripts/lib/gh-api-helper.sh`).
7. **Monitor quota**: check `x-ratelimit-remaining` after each call. Warn if < 100. Stop if 0 and wait for reset.
8. **Update cache**: write fresh responses to `.claude/github-api-cache.json`.
9. **Return results** as structured output.

---

## Rate-Limit Rules

- **Minimum 1 second** between mutation calls, enforced by `gh_mutate_delay`.
- **Exponential backoff** on 429/403 errors (2s, 4s, 8s, up to 60s max).
- **GraphQL rate-limit errors** arrive as HTTP 200 with `"type":"RATE_LIMIT"` — `gh_api_graphql` detects this.
- **Pre-batch quota check**: if < 100 remaining, proceed cautiously and reduce parallelism.
- **Conditional requests**: use ETags / `--cache` for polling patterns. 304 responses don't count against the limit.

## Coalescing Rules

- Prefer `gh issue list` over multiple `gh issue view` calls when fetching more than two issues.
- Cache reads for 5 minutes (300s TTL by default).
- Mutations are never cached (0s TTL).
- Identical reads within the same batch are deduplicated.

## Helper Library

All `gh api` calls from TPM MUST go through `scripts/lib/gh-api-helper.sh`:

- `gh_api` — wraps `gh api` with retry and backoff.
- `gh_api_graphql` — wraps `gh api graphql` with GraphQL-level error detection.
- `gh_mutate_delay` — enforces mutation spacing.
- `gh_check_rate_limit` — prints current REST / GraphQL quota status.

Example:

```bash
source scripts/lib/gh-api-helper.sh
gh_check_rate_limit

# Reads
gh_api repos/owner/repo/issues --cache 60s

# Mutation
gh_mutate_delay
gh_api -X PATCH repos/owner/repo/issues/100 -f state=closed
```

## Checking Status

```bash
# Quick check from any script
gh api rate_limit --cache 30s -q '.resources.graphql'

# Detailed check via helper
source scripts/lib/gh-api-helper.sh
gh_check_rate_limit
```

## Cache File

`.claude/github-api-cache.json` is a best-effort cache managed by TPM. Schema:

```json
{
  "entries": {
    "issue:100": { "data": {}, "fetched_at": "2026-03-16T12:00:00Z", "ttl_seconds": 300 },
    "issue_list:label=logapp-v1.0": { "data": [], "fetched_at": "...", "ttl_seconds": 120 }
  }
}
```

If missing or corrupt, TPM proceeds without it. The file is gitignored.

## Authorized-Mutation Flag

Certain homebase scripts that are known to make GitHub API calls (e.g. `scripts/set-project-fields.sh`) set `TPM_AUTHORIZED=1` internally for the duration of their run. This allows them to execute under TPM's direction without triggering the guard hook.

Agents and root Claude MUST NOT set `TPM_AUTHORIZED=1` themselves. Only TPM and TPM-blessed scripts set this flag.

---

## Enforcement Summary

- TPM agent definition includes the gatekeeper responsibility explicitly.
- `scripts/hooks/gh-cli-guard-hook.sh` blocks direct `gh` at the Claude Code tool-call layer.
- Agent definitions name this SOP and prohibit direct `gh` usage in their own procedures.
- `scripts/lib/gh-api-helper.sh` provides rate-limit-aware wrappers for TPM's use.
- `scripts/set-project-fields.sh` (a per-project wrapper, used by projects that adopt HOMEBASE-SOP-012 GitHub Project Management) sources the helper library for its mutations.

## Transport fallback (SSH egress blocked)

When `git push` fails with an SSH banner-stage error (`Connection closed`, `Connection reset by peer`, `Connection timed out during banner exchange`), it is a *transport* failure, not an API problem — but the operational impact is the same as an API outage. Two layered fallbacks exist:

- **Ad-hoc pushes** (outside `homebase work finish`): switch the one-shot push to the HTTPS URL form. Recipe lives in `@~/code/homebase/governance/WORKFLOW_QUICKREF.md` § *SSH push fails with banner timeout*. Classified green-list in `@~/code/homebase/governance/AUTONOMY_CHARTER.md` so Claude switches transport without asking.
- **Finish-gate pushes** (`homebase work finish` gate 11): `scripts/work/lib/gates.sh` automatically falls back from `git` to `gh api` (HTTPS to `api.github.com`) when transport breaks (HMB-54). Operator sees a `[warn] gate 11: git transport failed, falling back to gh api` line; the gate proceeds and FF-pushes via `PATCH /repos/{owner}/{repo}/git/refs/heads/main`.

Both fallbacks preserve the steady-state SSH transport — the SSH URL stays in `remote.origin.url`; only the failing invocation switches form.
