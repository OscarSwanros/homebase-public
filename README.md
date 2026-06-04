# Homebase

**A governance framework for running multiple software projects with AI coding agents.**

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
