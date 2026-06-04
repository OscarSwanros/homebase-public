# Linear Workspace Bootstrap Plan (Generated)

> Emitted by `homebase roadmap bootstrap --dry-run` to stdout. This file is the
> canonical **shape** of that output — the actual plan is re-emitted on every
> dry-run and should be reviewed in the terminal, not from this file.

`bootstrap` is idempotent. On every run it:

1. Queries live Teams.
2. For each canonical Team: skips if it exists, otherwise creates it.
3. For each canonical Label: checks presence, creates if missing.
4. For each canonical Project: checks presence in its Team, creates if missing.

The plan's mutation sequence comes entirely from the canonical tables in `scripts/roadmap/linear.rb` (`CANONICAL_TEAMS` and `CANONICAL_PROJECTS`), which MUST be kept in sync with `standards/LINEAR_WORKSPACE.md`.

## Example dry-run output (abbreviated)

```
─── HOMEBASE-SOP-013 Bootstrap Plan ──────────────────────────────────────

TEAM  TBL  Studio
      Example holding company — several brands publishing distinct products …
  + create team
  + label    roadmap
  + label    p0
  + label    p1
  + label    p2
  + label    p3
  + label    blocked
  + project  StudioWeb (studio-web)
  + project  Bookshelf (bookshelf)
  + project  Capture (capture)
  + project  Operator Name (acme-co)

TEAM  TFD  Field Suite
      Suite of apps for the scuba diving industry …
  + create team
  + labels … (6)
  + projects: GasCalc, LogApp, Link Companion, PhotoFix, ShopOS, SiteDB

TEAM  HMB  Homebase
      The company itself — CLI, SOPs, standards, governance, agents, skills.
  ✓ team exists
  + labels … (as needed)
  + project  Homebase (homebase)

──────────────────────────────────────────────────────────────────────────
```

The `✓` marker indicates an idempotent skip; `+` marks a mutation that will run on non-dry-run execution.

## Approval discipline

For net-new workspace bootstrap (first run), TPM MUST:

1. Emit the dry-run output, show it to the operator, get explicit approval of the mutation sequence.
2. Then execute without `--dry-run`.
3. Re-render the snapshot and commit `registry/ROADMAP.md` + `registry/roadmap-snapshot.yml`.

For subsequent runs (new-app onboarding), dry-run then execute is still the pattern, but approval can be implicit for additive-only changes.

## Rollback guidance

If a mutation fails partway through:

- Teams / Projects / Labels already created are **not** rolled back automatically.
- Re-run `homebase roadmap bootstrap` — it is idempotent; existing resources are skipped on name/key match.
- If a Team was created with the wrong identifier: Linear reserves keys forever, so the recovery is to **pick a different key** for the correct Team, add it to the canon, and re-bootstrap. Do not attempt to force a key collision.

## Canonical file references

- `scripts/roadmap/linear.rb` — `CANONICAL_TEAMS` and `CANONICAL_PROJECTS` arrays.
- `standards/LINEAR_WORKSPACE.md` — the human-readable canon; must match the Ruby file.
- `sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md` § Bootstrap Procedure — the full procedure.
