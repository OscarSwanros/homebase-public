---
name: release
description: "Wrapper around `homebase work ship`. Use when releasing any app — for web apps it dispatches to `homebase deploy`; for mobile/desktop it prints the SOP-005 phase guide; in both cases finishes by closing the Linear Milestone."
---

# Release — `homebase work ship` wrapper

The CLI is the aggregator. This skill is a thin wrapper that explains the dispatch.

## Run

```
homebase work ship <APP> <VERSION>
```

## What it does

1. **Web apps** (when `apps[<slug>].deploy` is declared in `project.yml`): dispatches to `homebase deploy <APP> production --version=<VERSION>`. The 12-phase Kamal pipeline runs (preflight, validate, image build, push, traffic shift, post-deploy verify).
2. **Mobile / desktop apps**: prints the remaining HOMEBASE-SOP-005 phase checklist as a guided release path (changelog promote, version bump, store metadata localisation, fastlane build, tag, store upload).
3. **Always**: closes the matching Linear Milestone via `homebase roadmap project ship <APP> v<VERSION>` so the roadmap reflects shipped state.

## Charter red-list

The deploy primitive is gated. Set `HOMEBASE_DEPLOY_CONFIRMED=1` only after explicit operator confirmation. The work-cli-guard hook blocks `homebase deploy` and `kamal *` without the env var.

## Authorisation

- Linear Milestone close: `LINEAR_TPM_AUTHORIZED=1` (TPM gatekeeper).
- Web deploy: `HOMEBASE_DEPLOY_CONFIRMED=1` (Charter red-list).
- Mobile flows: each fastlane / store-upload step has its own auth (App Store Connect, Play Console). The skill prints the checklist; the operator runs each step.

## Hotfix path

For P0 emergency releases, use `homebase work start --hotfix <KEY>` instead. See `/hotfix`. The hotfix kind skips gates 6 (changelog can be added in the release commit), 7 (issue may not exist yet), 11 (PR optional).

## Related

- `homebase deploy <APP> <ENV>` — the actual deploy primitive (web).
- `homebase roadmap project ship <APP> <VERSION>` — Linear Milestone close.
- `@~/code/homebase/standards/WORKFLOW_CONTRACT.md` § release_gates — full contract.
- `@~/code/homebase/sops/HOMEBASE-SOP-005-RELEASE_PROCESS.md` — explanation: why these phases, what each phase verifies.
- `@~/code/homebase/sops/HOMEBASE-SOP-006-HOTFIX_PROCESS.md` — explanation: when to hotfix vs wait.
