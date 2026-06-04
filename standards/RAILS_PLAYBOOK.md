# Rails Playbook

Reference architecture for deploying Rails apps across every homebase-adopting project.

**Invariants:**
- Rails 8 + SQLite is the default. Apps that need Postgres run it as a Kamal accessory on the same droplet.
- One shared DigitalOcean droplet hosts all web apps until the economics say otherwise.
- Deploys run via `homebase deploy <app> <env>` — SemVer, annotated tags `{app}/web/{version}`, Keep-a-Changelog.
- Each app is self-contained (own Kamal config, own hostname, own volume). Extraction to a dedicated droplet is a one-line change.

## Stack

| Layer | Choice | Rationale |
|---|---|---|
| App runtime | Rails 8 + SQLite | Default in Rails 8. Solid Queue / Cache / Cable eliminate Redis + separate DB for most apps. |
| Host | DigitalOcean droplet | One stack to learn. Cheap. Full control end-to-end. |
| Orchestration | Kamal 2.x | Rails-native. SemVer image tags. Native rollback. Accessories for Postgres / Redis when needed. |
| Routing | `kamal-proxy` (Kamal 2.x built-in) | Hostname-based TLS via Let's Encrypt. Multiple services on the same droplet without port collisions. |
| Registry | GitHub Container Registry (`ghcr.io/<owner>/<app>`) | Free at current scale. Mirrors the mobile artifact pattern. |
| Backups & assets | DigitalOcean Spaces (`homebase-backups` bucket) | S3-compatible. ~$5/mo. SQLite via pre-deploy hook; Postgres via nightly `pg_dump`. |
| Secrets | `.kamal/secrets` (shell-interpreted by Kamal) | No `.env` in repo. Shared tokens pulled from `~/.config/homebase/env` via inline command substitution (see below). |

## Cost Model

Target: **~$30/mo total** for up to ~6 Rails apps on one shared droplet.

- Droplet: `s-2vcpu-4gb` — $24/mo. (Start at `s-1vcpu-2gb` for $12/mo if thriftier; resize if Ruby RAM pressures.)
- Spaces bucket (shared): $5/mo
- DO-managed DNS: free
- GHCR: free for current scale
- Postgres accessory (SHOPOS only): $0 incremental (same droplet)

When the shared droplet cannot carry the load, extract the heaviest app first.

## Shared Droplet

Name: `homebase-shared`. Region: `nyc3` (adjust as needed). Size: `s-2vcpu-4gb`.

One-time bring-up:

```bash
doctl compute droplet create homebase-shared \
  --size s-2vcpu-4gb \
  --image docker-20-04 \
  --region nyc3 \
  --ssh-keys <key-id>

doctl spaces bucket create homebase-backups --region nyc3
```

Then locally:

```bash
mkdir -p ~/.config/homebase
# GHCR classic PAT with write:packages + read:packages
echo "GHCR_TOKEN=<your-token>" > ~/.config/homebase/env
chmod 600 ~/.config/homebase/env
```

The first app to `kamal setup` on the droplet installs `kamal-proxy`; subsequent apps reuse it.

## Declaring an App's Deploy

Add a `deploy:` stanza to the app's entry in `<project>/.homebase/project.yml`:

```yaml
apps:
  - name: studio-web
    path: apps/studio-web
    platforms: [web]
    status: active
    summary: "Multi-tenant client portal — Rails 8."
    brand: arnes-creativo
    deploy:
      image: acme-co/studio-web
      version_file:
        path: config/initializers/version.rb
        language: ruby
        symbol: StudioWeb::VERSION
      validate: bin/ci
      envs:
        production:
          hosts: ["198.51.100.10"]
          traefik_host: studio-web.example.com
          kamal_config: config/deploy.production.yml
          secrets_file: .kamal/secrets
          health_url: https://studio-web.example.com/up
```

Also add the app to `<project>/.homebase/changelogs.conf` so `extract-changelog.sh` can find its changelog:

```bash
resolve_changelog_path() {
  local app="$1" platform="${2:-ios}"
  case "$app" in
    studio-web)    echo "apps/studio-web/CHANGELOG.md" ;;
    # other apps…
  esac
}
```

## The `.kamal/secrets` File

Kamal's secrets loader captures `VARIABLE=VALUE` assignments and silently ignores free-standing shell commands on their own lines (`source`, `export`, `echo`). Anything dynamic must live inside a command substitution on the right-hand side of a `=`.

Shared tokens (GHCR password, per-app Postgres passwords, DO Spaces keys) live in `~/.config/homebase/env` (chmod 600, outside any git tree). The `.kamal/secrets` file pulls them inline with `grep`/`cut`:

```bash
# Example: SiteDB .kamal/secrets
RAILS_MASTER_KEY=$(cat config/master.key)
KAMAL_REGISTRY_PASSWORD=$(grep -E '^GHCR_TOKEN=' "$HOME/.config/homebase/env" | cut -d= -f2-)
POSTGRES_PASSWORD=$(grep -E '^DIVESITES_POSTGRES_PASSWORD=' "$HOME/.config/homebase/env" | cut -d= -f2-)

# Derived values can reference earlier assignments normally.
DATABASE_URL=postgis://sitedb:${POSTGRES_PASSWORD}@sitedb-postgres:5432/sitedb
```

**Do not** `source "$HOME/.config/homebase/env"` at the top and reference `$GHCR_TOKEN` below. Kamal's parser skips the `source`, `$GHCR_TOKEN` stays empty, and the eventual `docker login -p` surfaces as `flag needs an argument: 'p'` — easy to misdiagnose as a token problem.

Convention for per-app tokens in `~/.config/homebase/env`: `<APP>_POSTGRES_PASSWORD=...` (uppercase, underscore-separated). Generate once with `openssl rand -base64 32 | tr -d '/+=\n'` and append via `>>`.

Adding a per-app secret — appending to `~/.config/homebase/env`, adding the `grep | cut` loader line to `.kamal/secrets`, and declaring the variable under `env.secret` in `config/deploy.*.yml` — is routine config wiring per `@~/code/homebase/governance/AUTONOMY_CHARTER.md` (green-list). Claude completes this end-to-end as part of the feature work that introduced the secret; it does not require separate operator confirmation.

## The Deploy Pipeline (12 phases)

Every `homebase deploy <app> <env>` invocation runs exactly these:

| # | Phase | Action |
|---|---|---|
| 1 | Resolve | `<app>` + `<env>` → project path + deploy stanza via the registry. |
| 2 | Preflight | Clean tree, on `deploy.branch` (default `main`), up-to-date, `docker` / `kamal` / `gh` / `ruby` present, GHCR auth present. |
| 3 | Version read | Parse SemVer from `version_file`. `--version=X.Y.Z` validates strictly greater than current; otherwise `--patch` (default), `--minor`, or `--major`. |
| 4 | Changelog move | `## [Unreleased]` → `## [X.Y.Z] - YYYY-MM-DD` in the app's CHANGELOG. Refuses if `[Unreleased]` is empty. |
| 5 | Version bump | Rewrite the constant in `version_file`. |
| 6 | Validate | Run `deploy.validate` (defaults to `bin/ci`). Blocks the release on failure. Always runs, even in dry-run. |
| 7 | Commit | `Release <App> <version>` (SOP-001 exempt prefix). |
| 8 | Build + push | `kamal build push --version=X.Y.Z` to GHCR. |
| 9 | Deploy | `kamal deploy --version=X.Y.Z -c <kamal_config>`. Kamal auto-rolls-back on failure. Post-deploy HTTP probe against `health_url`. |
| 10 | Tag | Annotated `{app}/web/{version}` tag, message from `scripts/extract-changelog.sh`. |
| 11 | Push | `git push origin <branch> --follow-tags`. |
| 12 | Reopen | Empty `## [Unreleased]` added back, committed with `Post-release:` prefix, pushed. |

`--dry-run` executes phases 1–3 and 6; prints but does not run 4–5 or 7–12.

## Rollback

```
homebase rollback <app> <env> --to X.Y.Z
```

Thin wrapper around `kamal rollback`. Host-side container swap only — Git tags stay in place.

If the target version's image is no longer resident on the host (rare — Kamal keeps the previous version by default), redeploy from scratch instead:

```
homebase deploy <app> <env> --version X.Y.Z
```

## Extraction: Moving an App to Its Own Droplet

### Signals to extract
- Sustained **>50% droplet RAM** attributed to one app (`docker stats`).
- Sustained **>60% CPU over 7 days** attributed to one app.
- An app needs a capability the shared droplet can't provide — larger volume, specific region, regulatory isolation.

### Procedure
1. `doctl compute droplet create <app>-web --size <chosen> --image docker-20-04 --region <region>`
2. Copy volume/DB data from shared → new.
   - SQLite: `ssh shared 'sqlite3 /data/<app>.sqlite3 ".backup /tmp/b.sqlite3"' && scp shared:/tmp/b.sqlite3 new:/var/lib/docker/volumes/<app>_data/_data/`
   - Postgres accessory: `pg_dump | ssh new 'pg_restore'` (offline or dual-run as policy requires).
3. Edit the app's `config/deploy.production.yml`: change `servers.web: [<old>]` → `[<new>]`. Commit.
4. Drop DNS TTL to 60 s an hour before cutover.
5. `kamal setup -c config/deploy.production.yml` against the new droplet.
6. `homebase deploy <app> production` — deploys to the new host with a fresh SemVer.
7. Flip DNS.
8. After 48 h clean traffic: `kamal app remove -c config/deploy.production.yml` against the OLD host to free its resources on the shared droplet.

No homebase config change is required. The command interface is unchanged before and after extraction.

## Creating a New Rails App

Future work (tracked separately): `homebase new-rails` will scaffold a new Rails 8 app inside a chosen monorepo (studio or field-suite), pre-wired for deploy.

Until then, new apps are added by hand:

1. `cd <monorepo>/apps && rails new <slug> --database=sqlite3 --skip-git`
2. Add `<slug>/config/initializers/version.rb`: `module <App>; VERSION = "0.0.0"; end` (placeholder; first deploy ships `0.1.0`).
3. Add `<slug>/CHANGELOG.md` in Keep-a-Changelog format with `[Unreleased]` populated by the initial release notes (no baseline row yet — the first deploy rotates it to `[0.1.0]`).
4. Write `<slug>/config/deploy.production.yml` mirroring an existing app.
5. Write `<slug>/.kamal/secrets` (see the `.kamal/secrets` section above — inline `grep`/`cut`, no `source`).
6. Add the `deploy:` stanza to the monorepo's `.homebase/project.yml`.
7. Add the app to `.homebase/changelogs.conf`.
8. Point DNS at the shared droplet.
9. `homebase deploy <slug> production --setup --version=0.1.0` — the `--setup` flag routes Phase 9 through `kamal setup` to provision kamal-proxy and accessories before deploying. Subsequent deploys are plain `homebase deploy <slug> production`.

## Related

- `@~/code/homebase/sops/HOMEBASE-SOP-005-RELEASE_PROCESS.md` — release process across all platforms.
- `@~/code/homebase/sops/HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` — commit / issue discipline.
- `@~/code/homebase/standards/LOGGING.md` — Sentry four-signal observability.
- `@~/code/homebase/standards/SENTRY.md` — canonical Sentry org.
