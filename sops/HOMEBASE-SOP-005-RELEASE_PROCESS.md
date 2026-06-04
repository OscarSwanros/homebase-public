# HOMEBASE-SOP-005: Release Process

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Canonical procedure for releasing any app on any platform across every homebase-adopting project.

## Purpose

Ensure every release follows a consistent, repeatable process that covers changelog finalization, version bumping, metadata localization, validation, tagging, distribution, and post-release cleanup. Ad-hoc releases produce inconsistent store listings, missed localizations, untagged shipping points, and silent regressions in follow-up releases.

## Scope

**Applies to**: All apps on all platforms. Platform-specific steps are marked with `[iOS]`, `[Android]`, or `[Web]`.

**Agents involved**: `technical-project-manager` (coordination), the relevant language architect (iOS/Swift → `swift-architect`; Android → `kotlin-systems-architect`; Rails/web → `rails-architect`; Go → `go-architect`), `copywriter` (localization), and the relevant product manager (release-note review and scope sign-off).

**Per-project specifics.** Projects document their own app inventory, platform matrix, and release-note surface map in their own release docs (e.g. `Documentation/Release/RELEASE_MATRIX.md`). This SOP is the universal procedure; the project matrix is the universal procedure's data.

## Procedure

### Phase A: Pre-Release Preparation

#### Step 1: Finalize the Changelog

1. Open the app's `CHANGELOG.md`.
2. Move all entries under `## [Unreleased]` to a new section: `## [X.Y.Z] - YYYY-MM-DD`.
3. Write entries from the user's perspective (benefit-focused, not implementation details).
4. Use only these categories, in this order: `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, `Security`.
5. Omit empty categories.
6. Follow the project's `CHANGELOG_FORMAT.md` for detailed formatting rules if one exists.

#### Step 2: Bump the Version

| Platform | Action |
|---|---|
| `[iOS]` | Update `MARKETING_VERSION` in the Xcode project. Increment `CURRENT_PROJECT_VERSION`. |
| `[Android]` | Update `versionName` in the app's `build.gradle.kts`. `versionCode` may be auto-resolved from the Play Console at deploy time if the project configures it that way. |
| `[Web]` | Update the app's version constant (e.g. `APP::VERSION` in a version initializer). |

**Version scheme**: Semantic Versioning (MAJOR.MINOR.PATCH). See the Tagging Convention appendix below.

#### Step 3: Update Store Metadata (primary locale)

`[iOS/Android]` only:

1. Run the project's changelog-to-release-notes generator if one exists (commonly `scripts/changelog-to-release-notes.sh {app} {version}`).
2. Review generated text in the metadata directory.
3. **Major releases**: Review and update `description.txt`, `keywords.txt`, `promotional_text.txt`, `subtitle.txt`.
4. **Minor/patch releases**: Only `release_notes.txt` needs updating.

#### Step 3b: Update Public-Facing Release-Note Surfaces

Every public-facing surface that duplicates release notes (marketing site changelog YAML, RSS, help-center announcement, etc.) MUST be updated before tagging. Each project's release doc enumerates the surfaces that apply per app.

This step is a **blocking gate** — the release MUST NOT proceed to Phase B until every applicable surface is updated.

#### Step 4: Localize Metadata

`[iOS/Android]` only, when the project ships in more than one locale:

1. Engage the `copywriter` agent to translate updated release notes into each supported locale.
2. The copywriter must follow the project's `LOCALIZATION_GUIDE.md`.
3. **Major releases**: Also translate description, promotional text, and subtitle.
4. Place translated files where the project's fastlane metadata pipeline expects them.
5. Honour store character limits and no-emoji rules.

#### Step 5: Localize In-App Strings

If the release adds new user-facing strings, update the localization bundles (`Localizable.strings`, `strings.xml`, `config/locales/*.yml`, etc.) for every supported language before tagging.

#### Step 6: Regenerate Screenshots (Major Releases or UI Changes Only)

Follow the project's screenshot pipeline (commonly a fastlane lane). Review raw captures and confirm framed composites meet store dimension rules.

#### Step 7: Run Full Validation

Run the project's full CI suite locally (localization + metadata + unit + UI tests as applicable). Every check MUST pass. If any check fails, STOP and fix the issue.

#### Step 7b: Pre-Release Approval

Obtain scope sign-off from the relevant product manager. For safety-critical products, obtain domain-expert sign-off as well. Patch releases may accept PM-only sign-off unless the patch touches a safety-critical surface.

### Phase B: Release Execution

**Secrets pre-flight `[Web]`** — for Kamal-deployed apps, all `SENTRY_DSN`-style secrets MUST already be wired through `~/.config/homebase/env`, the project's `.kamal/secrets`, and the `env.secret` declaration in `config/deploy.*.yml` BEFORE Phase B begins. This wiring is routine config work that Claude completes autonomously while building the feature that introduced the secret — see `@~/code/homebase/governance/AUTONOMY_CHARTER.md` (green-list). It is not a release-time decision.

**Local-ship pre-flight `[Mobile/Desktop]`** — apps with a `ship:` stanza in `project.yml` (HMB-69) replace Steps 9 + 10 + 11 + 12 + 13 with a single command:

```bash
homebase work ship <app> <X.Y.Z> <target>
```

where `<target>` is one of the targets declared under `ship.targets` (typically `testflight`, `appstore`, `mac-appstore` for iOS; `playstore-internal`, `playstore-prod` for Android). The verb:

- runs blocking pre-flight gates (tree clean, branch, CHANGELOG header for `<X.Y.Z>` with today's date, version-file constant matches `<X.Y.Z>`, optional `validate_lane` fastlane lane);
- tier-gates **red-tier** targets (`appstore`, `playstore-prod`, `mac-appstore`) behind `HOMEBASE_SHIP_CONFIRMED=1` (operator-only env var; see `@~/code/homebase/governance/WORKFLOW_QUICKREF.md`);
- invokes `bundle exec fastlane deploy app:<fastlane_app> track:<track>` locally;
- creates and pushes the annotated tag `<app>/<tag_platform>/<X.Y.Z>` with the `scripts/extract-changelog.sh` body;
- prints a delegate-to-TPM instruction to close the Linear Milestone (Step 14b folded in; the milestone close is a TPM Linear mutation, not a ship-verb action — HMB-77).

`--dry-run` previews the full sequence without side effects. Use it before red-tier ships.

Steps 9–13 below describe the per-step semantics that the verb automates. They remain the canonical reference for apps that have NOT yet adopted the `ship:` stanza — and as the fallback recipe when the verb is unavailable.

#### Step 8: Commit

Stage all changes (changelog, version bump, metadata, localized strings, screenshots).

```bash
git commit -m "Release {AppName} {version}"
```

`Release ...` is an exempt subject prefix (see HOMEBASE-SOP-001 § Exempt Commits) — no issue reference is required.

#### Step 9: Tag

Tags MUST be annotated. Format: `{app}/{platform}/{version}`.

```bash
git tag -a {app}/{platform}/{version} -m "$(scripts/extract-changelog.sh {app} {version})"
```

The `scripts/extract-changelog.sh` helper is provided by homebase and extracts the relevant changelog section into the tag message. See the Tagging Convention appendix below for tag format rules.

#### Step 10: Push

```bash
git push origin main --tags
```

#### Step 11: Wait for CI

The project's tag-triggered release workflow fires on the matching pattern. Verify:

- All CI checks pass.
- GitHub Release is created with archive artifact and changelog.

### Phase C: Distribution

#### Step 12: Upload to Store

| Platform | Method |
|---|---|
| `[iOS]` | Download archive from the GitHub Release and upload via Xcode/Transporter, OR run `fastlane deploy` locally. |
| `[Android]` | `fastlane deploy` to the internal or production track per project policy. |
| `[Web]` | `homebase deploy <app> <env>` — orchestrates the 12-phase web deploy pipeline (see Appendix: Web Deploy Pipeline below). Incident rollback: `homebase rollback <app> <env> --to <previous-version>`. |

#### Step 13: Upload Metadata

`[iOS/Android]` only:

- `fastlane metadata app:{app} platform:{platform} [skip_screenshots:true]`
- Use `skip_screenshots:true` when screenshots haven't changed.

#### Step 14: Submit for Review

- `[iOS]`: Submit in App Store Connect. Verify "What's New" text in all languages.
- `[Android]`: Submit in Google Play Console. Review store listing in all languages.

#### Step 14b: Roadmap Graduation (SOP-013 integration)

Apps that have adopted HOMEBASE-SOP-013 (i.e. `project.yml` `apps[].roadmap.enabled: true`) close their Linear release Milestone when the release ships. This is a Linear mutation, so it is **delegated to `technical-project-manager`** (the Linear API gatekeeper, SOP-013) — homebase does not mutate Linear from the ship path.

> **HMB-77:** the old `homebase roadmap project ship <app> v<X.Y.Z>` verb was retired (individual milestone mutations live in the Linear MCP, not the roadmap glue). The `homebase work ship` verb prints a delegate-to-TPM instruction as its final step rather than shelling out to it.

After the release artifact has shipped, ask the TPM to mark the release Milestone `v<X.Y.Z>` on the app's Linear Project as shipped (via the Linear MCP `save_milestone`, or the Linear UI), then re-render the registry (`homebase roadmap render`, tracked as its own chore/issue per the issue-first rule).

- **Non-blocking**. Milestone closure does not block the release; if it can't happen immediately, the release still ships and the TPM closes the milestone within 24 h.
- **Skip** for apps that have not adopted SOP-013.

### Phase D: Post-Release

#### Step 15: Website / Announcement (Major or Notable Releases)

For major or notable releases, author the blog post, update the app's public page, and announce on owned channels. For small patch releases, no additional action is needed beyond the Step 3b surface updates already done in Phase A.

#### Step 16: Cleanup

1. Add an empty `## [Unreleased]` section back to `CHANGELOG.md`.
2. Commit: `Post-release: open {AppName} {version} unreleased section`.
3. Push to `main`.

`Post-release: ...` is an exempt subject prefix.

### Phase E: Product Readiness Verification

#### Every Release (Including Patches)

- [ ] Changelog entry in Keep-a-Changelog format
- [ ] Store "What's New" text drafted and localized for every supported locale
- [ ] Every public-facing release-note surface updated (Step 3b)
- [ ] All new user-facing strings localized
- [ ] No known data-integrity regressions
- [ ] For safety-critical products: domain-expert sign-off on any calculation or advisory change

#### Minor Releases (New Features)

- [ ] All "every release" items above
- [ ] Premium/free tier boundary verified (if applicable)
- [ ] Store screenshots still accurate
- [ ] Store keyword review

#### Major Releases

- [ ] All "minor release" items above
- [ ] Full store metadata refresh (all fields, all languages)
- [ ] Website app page updated
- [ ] Blog post drafted
- [ ] Performance benchmarks met
- [ ] Accessibility audit (VoiceOver/TalkBack, Dynamic Type, contrast)

## Appendix: Tagging Convention

### Tag Format

```
{app}/{platform}/{version}
```

| Component | Values | Notes |
|---|---|---|
| `app` | Lowercase app slug | Defined in the project's release matrix |
| `platform` | `ios`, `android`, `web`, `macos` | One platform per tag |
| `version` | SemVer | `MAJOR.MINOR.PATCH`, with optional pre-release suffix |

**Examples**: `gascalc/ios/1.0.0`, `logapp/ios/3.0.0`, `gascalc/android/1.0.0`, `shopos/web/1.0.0`, `gascalc/ios/1.1.0-beta.1`.

### Tag Rules

1. Tags are always **annotated** (`git tag -a`), never lightweight.
2. Tag message contains the relevant changelog section, produced by `scripts/extract-changelog.sh`.
3. CI parses the tag by splitting on `/` to extract `APP`, `PLATFORM`, `VERSION`.
4. Pre-release versions use SemVer suffixes: `-alpha.N`, `-beta.N`, `-rc.N`.
5. Each platform has its own tag-triggered release workflow, invoked from the project's `.github/workflows/` via the reusable homebase workflow `release-*.yml` (per project adoption).

### Versioning (SemVer)

- **MAJOR**: Breaking changes, major redesigns, data migration required.
- **MINOR**: New features, backward-compatible additions.
- **PATCH**: Bug fixes, performance improvements, no new features.

## Appendix: Web Deploy Pipeline

`homebase deploy <app> <env>` runs a 12-phase pipeline that subsumes Phases A–D of this SOP for web apps. The app declares its configuration once in `<project>/.homebase/project.yml` (see `standards/RAILS_PLAYBOOK.md`); the CLI does the rest.

| # | Phase | Action |
|---|---|---|
| 1 | Resolve | `<app>` + `<env>` → project path + deploy stanza via the registry. |
| 2 | Preflight | Clean tree, on `deploy.branch` (default `main`), up-to-date, `docker` / `kamal` / `gh` / `ruby` present, GHCR auth present. |
| 3 | Version read | Parse SemVer from `version_file`. `--version=X.Y.Z` must be strictly > current; otherwise `--patch` (default), `--minor`, or `--major`. |
| 4 | Changelog move | `## [Unreleased]` → `## [X.Y.Z] - YYYY-MM-DD`. Refuses if `[Unreleased]` is empty. |
| 5 | Version bump | Rewrite the constant in `version_file` (Ruby or Go). |
| 6 | Validate | Run `deploy.validate` (default `bin/ci`). Blocks on failure. Always runs, even in dry-run. |
| 7 | Commit | `Release <App> <version>` (HOMEBASE-SOP-001 exempt prefix). |
| 8 | Build + push | `kamal build push --version=X.Y.Z` to GHCR. |
| 9 | Deploy | `kamal deploy --version=X.Y.Z -c <kamal_config>`. Kamal auto-rolls-back on failure; homebase then retries the health probe against `health_url`. |
| 10 | Tag | Annotated `{app}/web/{version}` tag with changelog body from `scripts/extract-changelog.sh`. |
| 11 | Push | `git push origin <branch> --follow-tags`. |
| 12 | Reopen | Empty `## [Unreleased]` added back, committed with `Post-release:` prefix, pushed. |

`--dry-run` executes 1–3 and 6; prints but does not run 4–5 or 7–12.

`--setup` routes Phase 9 through `kamal setup` instead of `kamal deploy`, provisioning kamal-proxy and accessories on a fresh host before deploying. Use once per app+env for first-time deploys (idempotent, safe to re-run). Pair with `--version=X.Y.Z` to ship a specific initial version.

Rollback is a host-side container swap; Git history is untouched. If the target image is no longer resident on the host, `homebase deploy <app> <env> --version=<older>` redeploys from scratch.

See `standards/RAILS_PLAYBOOK.md` for the full reference architecture (shared DO droplet, extraction runbook, cost model).

## Appendix: Patch Release Quick-Reference

A streamlined checklist for bug-fix-only releases (PATCH version bumps). Steps marked N/A may be skipped for patches.

For `[Mobile/Desktop]` apps that have adopted the `ship:` stanza (HMB-69), Steps 9 + 10 + 11 + 12 + 13 + 14b collapse to a single command — see the **Local-ship pre-flight `[Mobile/Desktop]`** callout in Phase B above. The table below remains the manual fallback recipe.

| # | Step | Action | Notes |
|---|------|--------|-------|
| 1 | Finalize Changelog | Move `[Unreleased]` entries to `[X.Y.Z] - YYYY-MM-DD` | Same as full release |
| 2 | Bump Version | Update version constant / plist / gradle as applicable | Same as full release |
| 3 | Update Release Notes | Run the project's changelog-to-release-notes generator | Only `release_notes.txt` needs review |
| 3b | Update Public Surfaces | Update site changelog YAML, announcement surfaces | **Mandatory** — Step 3b |
| 4 | Localize Release Notes | Translate to every supported locale | Release notes only |
| 5 | Localize In-App Strings | Only if the patch adds/changes user-facing strings | Often N/A |
| 6 | Screenshots | N/A unless the patch changes a screenshot scene | Usually skip |
| 7 | Run Validation | Project's full CI suite | Must pass |
| 8 | Commit | `Release {AppName} {version}` | Same as full release |
| **9–13** | **Local ship (HMB-69)** | **`homebase work ship <app> <X.Y.Z> <target>` collapses Tag + Push + Wait-for-CI + Upload-to-Store + Upload-Metadata** | **Only for `[Mobile/Desktop]` apps with a `ship:` stanza. Red-tier targets need `HOMEBASE_SHIP_CONFIRMED=1`.** |
| 9 | Tag (fallback) | Annotated tag with extracted changelog | Same as full release; used by apps without `ship:` stanza |
| 10 | Push (fallback) | `git push origin main --tags` | Same as full release; used by apps without `ship:` stanza |
| 11 | Wait for CI (fallback) | Verify GitHub Actions passes and release is created | Same as full release; CI-tag-driven path only |
| 12 | Upload to Store (fallback) | Binary upload via Xcode / fastlane (`[iOS/Android]`) or `homebase deploy <app> <env>` (`[Web]`) | Same as full release; CI-tag-driven path only |
| 13 | Upload Metadata | `skip_screenshots:true` | Always skip screenshots on patches |
| 14 | Submit for Review | App Store Connect / Google Play Console | Same as full release |
| 15 | Website | N/A — no blog post (Step 3b already done) | |
| 16 | Cleanup | Reopen `## [Unreleased]` section | Same as full release |
