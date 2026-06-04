# HOMEBASE-SOP-015: Apple Toolchain Usage

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md),
> each project's `.homebase/workflow.yml`, and
> [`@~/code/homebase/.homebase/dependencies.yml`](../.homebase/dependencies.yml).
> This SOP explains the *why* behind specific contract clauses; do not
> follow it as a procedure — run `xcodebuildmcp` instead.

Canonical procedure for routing all Apple-platform toolchain invocations
through the `xcodebuildmcp` CLI rather than raw `xcodebuild`, `xcrun simctl`,
or bare `simctl`.

## Purpose

Three pressures push every Apple-platform workflow onto a wrapper CLI:

1. **Token efficiency.** `xcodebuild`'s prose log dumps and `xcrun simctl`'s
   inconsistent subcommand surface force every agent to re-derive build,
   test, sim, and UI-automation conventions session after session.
   `xcodebuildmcp` exposes a discoverable workflow tree
   (`xcodebuildmcp --help` → `xcodebuildmcp tools` →
   `xcodebuildmcp <workflow> --help`) that primes the agent in one round
   trip.
2. **Structured output.** `xcodebuildmcp` returns parseable JSON-like
   results for build outcomes, test failures, and simulator state.
   Raw `xcodebuild` requires the agent to parse multi-thousand-line
   xcpretty-style logs — slow and brittle.
3. **UI automation.** xcodebuildmcp's `ui-automation` workflow gives us a
   first-class surface for tap / swipe / type / screenshot /
   view-hierarchy / accessibility inspection on a running simulator.
   HOMEBASE-SOP-007 currently mentions `xcrun simctl io booted screenshot`
   as a manual supplementary tool; the canonical SOP-007 render-and-observe
   gate will migrate to `xcodebuildmcp ui-automation` in a follow-up issue.

## Scope

- **Gated**: `xcodebuild ...` (any subcommand or path-prefixed form),
  `xcrun simctl ...` (any subcommand), bare `simctl ...`.
- **Out of scope** (passes through the gate freely):
  `xcrun --find <tool>`, `xcrun lipo`, `xcrun otool`, `xcrun codesign`,
  `xcrun altool`, `xcrun swift`, `xcrun swiftc`, `xcrun dwarfdump`,
  `xcrun atos`, `pkill -f xcodebuild`, `killall xcodebuild`, `which
  xcodebuild`, `command -v xcodebuild`, `type xcodebuild`.

The allow-list covers binary-inspection / signing / compiler-frontend
utilities that xcodebuildmcp doesn't wrap, plus the standard process-mgmt
and existence-check vocabulary.

## The Rule

**Raw `xcodebuild`, `xcrun simctl`, and bare `simctl` are prohibited.**
Use `xcodebuildmcp` for every Apple-platform build, test, run, install,
sim management, UI automation, debugging, and device interaction.

Enforcement is automated:
`scripts/hooks/xcodebuild-cli-guard-hook.sh` is wired into every
homebase-adopting project's `.claude/settings.json` as a `PreToolUse[Bash]`
hook. Direct invocations are blocked unless the environment variable
`XCODEBUILDMCP_AUTHORIZED=1` is set at Claude fork time.

### Sibling rules

- **`gh` CLI** (HOMEBASE-SOP-002) — `scripts/hooks/gh-cli-guard-hook.sh` +
  `TPM_AUTHORIZED=1`.
- **Linear API** (HOMEBASE-SOP-013) — `scripts/hooks/linear-cli-guard-hook.sh`
  + `LINEAR_TPM_AUTHORIZED=1`.

All three guards follow the same shape: detect the raw CLI, allow with an
explicit env-var escape hatch, block otherwise. Mass-allow rules in
`.claude/user-settings.json` should refer to the *wrapper* (`xcodebuildmcp`,
`gh`, `homebase`), not the raw underlying tool.

---

## The Wrapper: xcodebuildmcp

- **Source**: [getsentry/xcodebuildmcp](https://www.xcodebuildmcp.com/docs)
- **Install**: `brew tap getsentry/xcodebuildmcp && brew install xcodebuildmcp`
  (or `npm install -g xcodebuildmcp@latest` — Homebrew is canonical).
- **Pinned version**: `.homebase/dependencies.yml` →
  `dependencies.xcodebuildmcp.version`. Bootstrap FAILs (not warns) on
  any drift between the installed version and the pin.
- **Skill**: `skills/xcodebuildmcp-cli/SKILL.md` (vendored from upstream,
  symlinked into `~/.claude/skills/xcodebuildmcp-cli/` by
  `bin/homebase link`). The skill primes Claude with the discovery flow
  and CLI-not-MCP-server posture homebase chooses.

### Discovery flow

```
xcodebuildmcp --help                      # top-level + workflow list
xcodebuildmcp tools                       # all 79+ tools across workflows
xcodebuildmcp <workflow> --help           # tools in one workflow
xcodebuildmcp <workflow> <tool> --help    # arguments for one tool
```

Use this flow once per session and stop. Memorising tool lists is wasted
context — the help surface is the contract.

### Workflows we care about

| Workflow | Replaces | When to reach for it |
|---|---|---|
| `simulator` | `xcodebuild build/test/run` on sim | Local build/test/run loop |
| `simulator-management` | `xcrun simctl boot/erase/list/io` | Sim lifecycle |
| `device` | `xcodebuild` + `ios-deploy` | Physical-device flows |
| `ui-automation` | `xcrun simctl io ... screenshot` + manual taps | SOP-007 render-and-observe (pending follow-up to wire formally) |
| `debugging` | LLDB attach by hand | Inspect a running sim/device process |

There are more workflows; this is the homebase-relevant subset. See
`xcodebuildmcp --help` for the full set.

---

## Escape Hatch

`XCODEBUILDMCP_AUTHORIZED=1` lets a blocked command through. **Genuine
one-off only.** Examples that justify it:

- `xcodebuild -showBuildSettings` while triaging a build-graph issue
  xcodebuildmcp doesn't surface.
- `xcrun simctl status_bar override` for an Apple-Frameworks experiment
  no workflow covers yet.

The env var is captured at Claude's fork time. Inline
`XCODEBUILDMCP_AUTHORIZED=1 xcodebuild ...` and mid-session
`export XCODEBUILDMCP_AUTHORIZED=1` do **not** affect what the hook sees.
Set the value once via `.claude/settings.local.json` `env` block + relaunch
Claude. Then unset before the next session.

Setting the var permanently in a shell rc defeats the gate. Do not.

## Session-Learned Gotchas

These come from real Apple-platform sessions and are pinned here until
they grow into a standalone `standards/APPLE_BUILD.md` companion (the
SOP-013 ↔ `standards/LINEAR_WORKSPACE.md` precedent):

- **Cross-project framework resolution: use the workspace, not the bare
  `.xcodeproj`** — in monorepos where an app's `.xcodeproj` references
  sibling Xcode sub-projects (e.g. GasCalc ↔ DiveUnitKit / DFUI / DiveLog /
  OnboardingKit), `xcodebuildmcp simulator {build,test,build-and-run}`
  invoked with `--project-path .../<App>.xcodeproj` fails with
  `unable to resolve module dependency: '<SiblingModule>'` for every
  sibling import. The bare `.xcodeproj` doesn't pull cross-references in
  on its own. Use `--workspace-path iOS/Suite.xcworkspace --scheme <App>`
  instead — the top-level `Suite.xcworkspace` *is* the build graph; the
  per-app `.xcodeproj` is a participant. SPM-style deps declared inside
  the `.xcodeproj` (`XCLocalSwiftPackageReference` /
  `XCRemoteSwiftPackageReference` — e.g. `sentry-cocoa`,
  `DaltonIntentsKit`) resolve fine either way; the failure mode is
  specific to sibling `.xcodeproj` cross-imports. Symptom check: a
  failure list of four or more "unable to resolve module dependency"
  errors hitting *only* sibling modules and never the SPM ones is the
  fingerprint — switch to the workspace path and rerun, don't reach for
  `-resolvePackageDependencies` or `derivedDataPath` tricks.
- **Worktree SourceKit "No such module" noise** — in a `git worktree`
  checkout, Xcode's editor-indexer can emit `No such module
  'DaltonIntentsKit'` (or any other local SPM/sub-project module) on
  every Swift import line because the indexer hasn't materialised the
  build graph for the worktree path yet. These are SourceKit
  *indexing* warnings, not compiler errors. The actual build, run via
  `xcodebuildmcp simulator …`, resolves modules correctly. Don't edit
  imports to chase a fix — trust the build, ignore the indexer until
  Xcode catches up.
- **`.appex` testable-import limit** — `@testable import
  <SomeWidgetExtension>` finds the swiftmodule but fails at link stage
  because an `.appex` target does not produce a linkable library.
  Workaround: extract shared code into an SPM package (preferred) or a
  small framework target consumed by both the extension and the test
  bundle.
- **AppIntents literal-default rule** — the AppIntents metadata processor
  rejects non-literal `default:` expressions on `@Parameter`. E.g.
  `default: Measurement(value: 30, unit: .meters)` is rejected because
  `Measurement(...)` is a constructor call, not a literal. Use primitive
  types (`Double`, `Int`, `String`) with literal defaults; convert to
  richer types at the call site.

## Adoption

Projects opt in by declaring `xcodebuild_via_mcp_cli` under
`hard_rules:` in their `.homebase/workflow.yml`. The renderer will then
include the gate in the project's `CLAUDE.md` `## Hard Rules` block, and
the PreToolUse hook will fire on every Bash call from agents working in
that project's tree.

Initial adoption:

- **homebase** itself — already declared in
  `homebase/.homebase/workflow.yml`. (Homebase doesn't run xcodebuild
  itself, but adopting the rule makes the gate visible in homebase's
  rendered CLAUDE.md and exercises the hook test in homebase's CI.)
- **Apple-platform projects** — GasCalc (iOS + Android), LogApp (iOS),
  Link Companion (macOS), PhotoFix (iOS), Capture (iOS + macOS), Bookshelf (iOS).
  Rollout is one Linear issue per project, coordinated by TPM.

Non-Apple-platform projects (StudioWeb, ShopOS, SiteDB,
acme.example.com) should not adopt the slug — they have no
`xcodebuild`/`simctl` invocations to gate.

## Bootstrap Integration

`bin/homebase bootstrap` performs the install + version pin check via the
`bootstrap_xcodebuildmcp()` helper:

1. Reads the pin from `.homebase/dependencies.yml`.
2. Fails fast if Homebrew is missing.
3. Installs the formula if absent; reconciles if the installed version
   differs from the pin (FAIL with upgrade/downgrade instructions).
4. Backs up any third-party `~/.claude/skills/xcodebuildmcp-cli/` real
   directory so the homebase symlink can land cleanly.
5. Diffs the vendored `skills/xcodebuildmcp-cli/SKILL.md` against the
   upstream-for-pinned-version copy from
   `/opt/homebrew/Cellar/xcodebuildmcp/<version>/libexec/skills/xcodebuildmcp-cli/SKILL.md`.
   Drift = bootstrap FAIL, not warn — the dependency state is in
   lockstep with homebase's git or the system doesn't run.

The `homebase deps verify` subcommand runs the same checks without
re-installing. Use it in CI and at session start to gate stale machines.

## Sync Flow (When xcodebuildmcp Releases an Update)

1. `brew upgrade xcodebuildmcp` (locally).
2. `homebase deps sync xcodebuildmcp` — copies the new upstream
   `SKILL.md` into `skills/xcodebuildmcp-cli/SKILL.md`. Does NOT bump the
   version pin; the operator reviews the diff first.
3. Inspect the diff (`git diff skills/xcodebuildmcp-cli/SKILL.md`). Skill
   content shapes agent behaviour; an automatic upstream merge could
   silently re-steer every agent on every Mac.
4. `homebase deps bump xcodebuildmcp <new-version>` — bumps the pin in
   `.homebase/dependencies.yml`. (Or hand-edit + commit.)
5. Commit both files under the same `Refs HMB-NNN` trailer (a chore-kind
   issue titled `Sync xcodebuildmcp skill + pin to vX.Y.Z`).
6. `homebase bootstrap` on every active Mac picks up the new pin.

## For Agents (Non-TPM)

When you need a build, test, sim, or UI-automation operation:

1. **Do NOT** run `xcodebuild` or `xcrun simctl` directly — the hook will
   block you.
2. Invoke the `xcodebuildmcp` workflow. Default to discovery
   (`xcodebuildmcp --help`) once per session, then use the specific tool
   for the rest.
3. If a workflow doesn't cover what you need (rare), surface it to the
   operator with the proposed escape-hatch invocation. Don't reach for
   `XCODEBUILDMCP_AUTHORIZED=1` yourself — the operator decides.

## Related

- **Skill**: `~/.claude/skills/xcodebuildmcp-cli/SKILL.md` (symlinked from
  `skills/xcodebuildmcp-cli/SKILL.md`).
- **Vendor metadata**: `skills/xcodebuildmcp-cli/HOMEBASE.md` (sync flow,
  not visible to Claude's skill loader).
- **Pin manifest**: `.homebase/dependencies.yml`.
- **Schema**: `schemas/dependencies.schema.json`.
- **Hard rule**: `governance/HARD_RULES.yml` → `xcodebuild_via_mcp_cli` (#17).
- **HOMEBASE-SOP-007** (UI Verification): pending follow-up to formalise
  `xcodebuildmcp ui-automation` as the canonical render-and-observe
  surface, replacing the legacy `xcrun simctl io booted screenshot` flow
  currently described there.

---

## Enforcement Summary

- `scripts/hooks/xcodebuild-cli-guard-hook.sh` blocks raw
  `xcodebuild`/`xcrun simctl`/`simctl` at the Claude Code Bash-tool layer.
- `bin/homebase bootstrap` installs and version-pins xcodebuildmcp; fails
  on any drift in installed version or vendored skill content.
- `homebase deps verify` reruns the drift checks without installing —
  for CI and session-start sanity.
- `governance/HARD_RULES.yml` records the rule at slug
  `xcodebuild_via_mcp_cli` (#17); the renderer joins it into each
  adopting project's `CLAUDE.md` `## Hard Rules` block.
