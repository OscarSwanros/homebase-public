# Homebase

**A governance framework for running multiple software projects with AI coding agents.**

> **⚠️ Status: not actively maintained, not built for widespread adoption.**
> This is a point-in-time snapshot published as a companion to an essay —
> *[Risk-management lessons from cave diving, applied to working with coding
> agents](https://oscarswanros.com/2026/05/29/risk-management-lessons-from-cave-diving-applied-to-working-with-coding-agents/)* —
> not a product. It's shared to read, learn from, and fork — not to install and
> rely on. There is no support, no roadmap, and no commitment to respond to
> issues or pull requests. If something here is useful, take it and make it your
> own.

Homebase is the "company HQ" for a one-operator (or small-team) software shop: a
single repository that holds your **staff** (reusable AI agents), your
**handbook** (SOPs), your **operating contract** (the rules agents must follow),
and the **CLI + git hooks + CI** that enforce all of it. Individual projects —
each with its own product, stack, and customers — consume homebase by reference
and symlink, so the operating rhythm is identical everywhere while the
project-specific context stays in each project.

> **This is a reusable, anonymized release of a working internal system.** The
> portfolio, roadmap, brand-specific agents, and infrastructure identifiers you
> see are **fictional placeholders** (`your-org`, `acme.example.com`, a "Studio"
> / "Field Suite" example portfolio) that demonstrate the format. It's an
> *opinionated* system extracted from one real setup — expect to adapt it, not
> drop it in unchanged.

## Mental model — CEO + Staff

- **Homebase is the company.** HQ + staff + handbook.
- **Agents are staff** (`agents/`). They travel between projects, picking up
  project-specific context from each project's `CLAUDE.md` at runtime.
- **Projects are engagements.** Each has its own product and domain; the
  operating rhythm is company-wide.
- **SOPs are the handbook** (`sops/`). Written once, read everywhere.

## What's in here

| Directory | What it holds |
|---|---|
| `agents/` | Project-agnostic AI staff (architects, QA, PM, design, copy, etc.) |
| `sops/` | Standard operating procedures (development, release, hotfix, onboarding, …) |
| `governance/` | The agent operating contract, autonomy charter, hard-rules registry, risk model |
| `standards/` | Cross-project technical facts (logging, Linear workspace topology, Rails playbook) |
| `scripts/` | The `homebase work` CLI gates, git hooks, deploy/roadmap tooling |
| `schemas/` | JSON-Schemas validating the YAML config surfaces |
| `templates/` | Scaffolds for new projects, agents, and config |
| `registry/` | Generated map of consuming projects (fictional example included) |
| `bin/homebase` | The operator-facing CLI |
| `CLAUDE.md` | The master doc Claude Code loads every session — the full map |

## Requirements & assumptions

Homebase is opinionated about its environment. It assumes:

- **macOS** + **zsh/bash** (the bootstrap path is built around macOS; scripts are POSIX-ish bash).
- **[Claude Code](https://claude.com/claude-code)** as the agent runtime — agents, skills, hooks, and settings are wired into `~/.claude/`.
- **git** + the **`gh` CLI** (authenticated) for the GitHub-gatekeeper workflow.
- **Ruby** (system Ruby is fine) for the registry/roadmap tooling.
- *Optional:* **Linear** (issue tracking / roadmap substrate), **Sentry**
  (errors), **Kamal** (Rails deploys). The framework runs without them; the
  integrations are opt-in per project via `.homebase/project.yml`.

A convention the whole system leans on: homebase lives at **`~/code/homebase`**
and your projects live as siblings under `~/code/`. You can change this, but
several docs and examples assume it.

## Quick start

```sh
# 1. Clone homebase to the conventional location
git clone <your-fork-url> ~/code/homebase
cd ~/code/homebase

# 2. One-time per machine: symlink agents/skills/settings into ~/.claude/
bin/homebase link

# 3. Confirm the CLI is wired up
bin/homebase help
bin/homebase roster      # lists the agent staff
bin/homebase sops        # lists the SOPs
```

`bin/homebase link` symlinks `~/.claude/{agents,skills,statusline-command.sh,agent-signal.sh,settings.json}`
to homebase, so every Claude Code session on this machine inherits the staff and
operating contract. It moves any pre-existing real `~/.claude/settings.json`
aside to a timestamped backup first.

## Onboarding a project

Each project keeps its own product/domain context but borrows homebase's
operating rhythm. To wire one up:

```sh
# 1. Create the symlinks (git hooks, scripts, .claude/settings.json) and
#    scaffold the project's .homebase/project.yml. Idempotent.
bin/homebase link-project ~/code/my-project

# 2. Fill in ~/code/my-project/.homebase/project.yml
#    (name, display_name, domains, apps[]; see templates/project.yml.tmpl)

# 3. Regenerate the registry and commit it
bin/homebase index
git add registry/ && git commit   # registry/PROJECTS.md + projects.paths

# 4. Verify every expected symlink resolves back to homebase
bin/homebase status ~/code/my-project
```

After this, the project's commits are governed: every change needs a tracked
issue, commit messages are policy-checked, and sessions can't end with unpushed
work. A project that *shouldn't* be symlink-linked (read-only inclusion in the
registry) can use `bin/homebase register <path>` instead of `link-project`.

Promoting an older, vendored setup to symlinks? Use `bin/homebase migrate <path>` once.

## New-machine setup

After Migration Assistant or a fresh clone, a single idempotent command wires
everything up:

```sh
bin/homebase bootstrap
```

`bootstrap` runs `link`, walks every path in `registry/projects.paths` applying
`link-project` + `status`, validates the external secrets file
(`~/.config/homebase/env`, mode 600), confirms `gh` auth and SSH connectivity to
GitHub, and prints a per-step `[OK]` / `[WARN]` / `[FAIL]` summary (non-zero
exit on any failure). The full procedure lives in
`sops/HOMEBASE-SOP-014-MACHINE_MIGRATION.md`.

## CLI reference

```
homebase <verb> [args]

  link                         Symlink ~/.claude/{agents,skills,settings,…} → homebase
  link-project <path>          Create project-level symlinks (hooks, scripts, settings)
  migrate <path>               Replace vendored copies with symlinks (idempotent)
  status <path>                Verify every expected symlink points to homebase
  bootstrap                    First-run on a new machine: link + walk every project
  register <path>              Add a project to the registry (no symlinks)
  index [--check]              Regenerate registry/PROJECTS.md from each project.yml
  list                         Print the registry to stdout
  roster | sops                List the agent staff / the SOPs
  work <sub> [args]            Workflow control plane (start/checkpoint/finish/ship/…)
  roadmap <sub> [opts]         Linear roadmap ops (render/audit/portfolio/bootstrap/…)
  deploy <app> <env>           Deploy an app via Kamal (12-phase pipeline)
  render-claudemd <path>       Re-render a project's CLAUDE.md from its workflow.yml
  settings doctor              Verify/repair the portable ~/.claude/settings.json symlink
  help                         Full usage
```

## How enforcement works

Homebase is **default-deny across six layers** — PreToolUse hooks, git hooks,
session-lifecycle hooks, the `homebase work` CLI gates, and CI. The intent is
that an agent literally cannot commit without a tracked issue, cannot bypass the
commit-message policy, and cannot end a session with uncommitted or unpushed
work. See `governance/RISK_MANAGEMENT.md` for the "inverted Swiss cheese"
rationale and `governance/AGENT_OPERATING_CONTRACT.md` for the ten rules every
agent inherits.

The thinking behind this default-deny posture — borrowed from how cave divers
build redundant, independent safety layers — is laid out in the companion essay:
*[Risk-management lessons from cave diving, applied to working with coding
agents](https://oscarswanros.com/2026/05/29/risk-management-lessons-from-cave-diving-applied-to-working-with-coding-agents/)*.

## A session in practice

Here's what it looks like to actually use this — a walkthrough against the
fictional example portfolio (`GasCalc`, the safety-critical gas calculator in
the `Field Suite` monorepo). You talk to Claude Code in plain language; the
framework turns that into tracked, gated, reviewed work.

---

> **You:** "Let's add a Maximum Operating Depth warning to GasCalc — it should
> flag when the diver's gas mix becomes unsafe past a certain depth."

**Claude doesn't start editing.** First it checks for in-flight work and routes
the request to the right staff:

```
$ homebase work status
No active work-state.
```

It pulls in two specialists from `agents/`:

- **`diving-product-manager`** — confirms scope: *is this in GasCalc's remit, and
  what's the right UX for a safety warning?*
- **`dive-science-advisor`** — the **final authority** on the physics. It
  supplies the ppO₂ → MOD formula and the safe limits, and (per its charter) no
  safety-critical feature ships without its sign-off.

**Issue first — it files one, it doesn't ask you to.** Product work needs a
tracked issue with acceptance criteria, so `technical-project-manager` (the sole
Linear gatekeeper) creates it:

```
TFD-214  "GasCalc: warn when gas mix exceeds safe MOD"
  ## Acceptance Criteria
  - [ ] MOD computed from FO₂ and a configurable ppO₂ limit (default 1.4 bar)
  - [ ] Warning shown on the results screen when planned depth > MOD
  - [ ] Formula reviewed and signed off by dive-science-advisor
```

```
$ env LINEAR_TPM_AUTHORIZED=1 homebase work start TFD-214
✔ work-state created · branch tfd-214 · worktree .worktrees/tfd-214/
✔ Linear TFD-214: Backlog → In Progress
→ cd .worktrees/tfd-214
```

**The work happens.** `swift-architect` advises on where the calc lives; the
warning gets implemented. Now a commit — and here a guardrail fires:

```
$ git commit -m "add MOD warning"
✗ blocked (commit-msg hook): no issue trailer found.
  Every commit must reference its issue: add `Refs TFD-214`.
```

So it commits the way the contract requires:

```
$ env HOMEBASE_WORK_AUTHORIZED=1 git commit -m "feat(gascalc): warn when planned depth exceeds MOD

Compute MOD from FO₂ and a configurable ppO₂ limit; surface a
results-screen warning when the planned depth is deeper than the mix
allows.

Refs TFD-214

Co-Authored-By: Claude <noreply@anthropic.com>"
✔ commit-sop-check · trailer OK · one issue scope OK
```

**Safety sign-off before close.** `dive-science-advisor` reviews the implemented
formula against its reference values and confirms it's correct — that's the
acceptance criterion that gates the feature.

**Closing out runs every gate at once:**

```
$ env LINEAR_TPM_AUTHORIZED=1 HOMEBASE_WORK_AUTHORIZED=1 \
    homebase work finish --append-closing
✔ working tree clean
✔ trailers valid · closing keyword present (Closes TFD-214)
✔ required checks passed (build + tests)
✔ rebased onto origin/main · fast-forward pushed
✔ Linear TFD-214: In Progress → Done · worktree torn down
```

No unreferenced commit ever landed, no safety-critical change shipped without the
domain authority's sign-off, and the session can't end with anything uncommitted
or unpushed. That's the whole point: **the rails are the product.**

---

The same shape applies everywhere — `"let's fix the onboarding copy on
StudioWeb"` pulls in `copywriter` + `web-frontend-architect`; `"bump ShopOS to
v0.3 and deploy"` runs the release flow and the Kamal pipeline. Governance edits
that don't need an issue take the lighter chore path
(`homebase work chore "fix typo in SOP-001"`). You stay in plain language; the
framework keeps the work tracked, reviewed, and reversible.

## Making it yours

This release ships fictional example content. Before relying on it, replace:

1. **The registry** (`registry/PROJECTS.md`, `ROADMAP.md`, `projects.paths`,
   `roadmap-snapshot.yml`) — regenerated by `bin/homebase index` /
   `homebase roadmap render` once you register your own projects.
2. **The example agents** — `agents/example-product-pm.md` and
   `agents/example-reviewer.md` are templates; copy one per brand/lens and fill
   in the bracketed placeholders. The other agents are project-agnostic and
   usable as-is.
3. **Infrastructure identifiers** — search for `your-org`, `your-sentry-org`,
   `acme.example.com`, `linear.app/your-workspace`, and the `acme-co/homebase`
   workflow refs; substitute your own. `standards/SENTRY.md` and
   `standards/LINEAR_WORKSPACE.md` are the main homes for these.
4. **Secrets** — nothing secret ships here. The scripts read credentials from an
   external `~/.config/homebase/env` (mode 600) and per-project `.kamal/secrets`;
   create those yourself. The repo only contains the *patterns* for reading them.

## License

Released under the MIT License — see `LICENSE`. Set the copyright holder to your
own name/organization before publishing.
