# Linear New-App Onboarding Checklist

Checklist for registering a new app as a Linear Project per HOMEBASE-SOP-013, triggered by HOMEBASE-SOP-009 during new-app onboarding.

Copy this file into the session; tick items as completed; do not commit the filled-in copy.

## Mental model refresh

```
Team     = monorepo       (TBL, TFD, HMB — rarely added)
Project  = app            (what you are adding here)
Milestone = release       (created per planned version)
```

A new app almost always becomes a new **Project** inside an existing **Team** — not a new Team.

## Pre-flight

- [ ] App exists in `registry/PROJECTS.md` (run `homebase index` to confirm).
- [ ] App's monorepo has a canonical Team (`TBL`, `TFD`, or `HMB`). If a new monorepo is shipping, extend the Teams canon first.
- [ ] `LINEAR_TPM_AUTHORIZED=1` set for the duration of the batch.
- [ ] `$LINEAR_API_KEY` readable from `~/.config/homebase/env` or already exported.

## Step 1 — Extend the canon

Update **both** files in the same commit:

- [ ] `~/code/homebase/standards/LINEAR_WORKSPACE.md` § Projects — add the new row.
- [ ] `~/code/homebase/scripts/roadmap/linear.rb` `CANONICAL_PROJECTS` — add the `{slug => { team_key, name, owner }}` entry.

Display name convention: exactly the app's display name from `registry/PROJECTS.md`, no version suffix.

## Step 2 — Create the Project

```bash
LINEAR_TPM_AUTHORIZED=1 homebase roadmap bootstrap
```

`bootstrap` is idempotent: it will skip existing Teams, labels, and Projects, and create only the new Project you just added to the canon.

## Step 3 — Capture IDs

```bash
LINEAR_TPM_AUTHORIZED=1 homebase roadmap capture <app>
```

Writes the Team ID + Project ID into `<project>/.homebase/project.yml` under `apps[].roadmap`. Surgical text edit — does not reformat the file.

- [ ] `git diff <project>/.homebase/project.yml` shows only the added `roadmap:` block; nothing else mutated.

## Step 4 — GitHub integration handshake

Linear's GitHub integration is installed at the workspace level. Per-Project repo linking happens in Linear's UI:

- [ ] In Linear → the new Project → GitHub → Connect Repository, point at the app's repo.
- [ ] Sanity test: create a throwaway Linear issue in the Project, confirm a mirror GitHub issue auto-appears, close it, confirm Linear auto-closes.
- [ ] Delete the throwaway issue on both sides.

## Step 5 — Initial Milestones (optional)

If a release is already planned for the new app:

```bash
LINEAR_TPM_AUTHORIZED=1 homebase roadmap milestone create <project-id> v<X.Y.Z> --target YYYY-MM-DD
```

Get `<project-id>` from `homebase roadmap project list --team <KEY>`.

## Step 6 — Snapshot

- [ ] `homebase roadmap render` — regenerates `registry/ROADMAP.md` + `registry/roadmap-snapshot.yml`.
- [ ] `homebase roadmap audit` — must exit 0.
- [ ] Commit with `Closes #<issue>` trailer.

## Finishing

- [ ] `LINEAR_TPM_AUTHORIZED` unset.
- [ ] SOP-009 onboarding checklist marked complete for the "Linear Project" item.
