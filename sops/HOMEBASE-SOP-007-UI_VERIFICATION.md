# HOMEBASE-SOP-007: UI Verification

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

## Purpose

Prevent the failure mode where an agent ships a UI change based on code that "looks right" without checking whether it actually renders correctly in a browser (or on-device). Type checks and test suites verify code correctness. They do not verify feature correctness. Visual regressions, layout bugs, z-index collisions, margin math, and interaction issues are invisible to static analysis — they are only visible when the UI is rendered.

## Scope

All agents, all projects that adopt this SOP (declared in the project's root CLAUDE.md § Adopted SOPs).

## When to Perform

This SOP is triggered by any change to user-facing rendering:

**Web**

- HTML templates (`.erb`, `.html`, `.html.tmpl`, `.gohtml`, etc.)
- CSS / SCSS / Tailwind classes in markup
- JavaScript / Stimulus / React / Vue affecting layout or interaction
- Assets loaded by a view (images, fonts, SVGs)
- Jekyll layouts, partials, or includes

**Apple**

- SwiftUI `View` bodies, `ViewModifier`s, custom layouts
- UIKit view controllers, storyboards, xibs
- Colors, typography, spacing tokens consumed by a rendered view

The Stop-hook auto-triggers on Swift files whose path contains `/Views/`, `/Screens/`, `/Components/`, or `/UI/`, OR whose filename matches `*View.swift`, `*Screen.swift`, `*Sheet.swift`, `*Cell.swift`, `*Layout.swift` (HMB-19). A bare `.swift` change in non-UI paths with non-UI filenames (e.g. `DaltonApp.swift`'s init logic, repositories, services) does NOT auto-trigger — gate 9 only fires on real rendering surfaces. If your change does have a rendering effect but isn't auto-detected, add the trailer manually; the hook accepts the trailer regardless of the file path.

**Android**

- Composable `@Composable` functions, custom layouts
- XML layouts, drawables consumed by a rendered view

**Does NOT apply to**

- Pure model, service, networking, migration, or test changes with no rendered surface
- Build configuration, CI, Dockerfile, deploy scripts
- Documentation-only changes (even when they include screenshots)
- Copy-only changes to already-rendered strings where the layout cannot shift (rare — when in doubt, verify)

## The Rule

**A UI-touching change is not complete until it has been rendered and observed.** Never claim a UI change done without a live-render check. Never push a UI commit without citing the verification in the commit trailer.

Three things must happen before the commit is pushed:

1. The change is rendered — dev server running and the relevant route loaded, or the app built and run on a simulator/device.
2. The change is observed — a screenshot is captured through Chrome MCP (web) or a simulator screenshot (Apple/Android).
3. The commit message carries a `Verified in browser:` trailer (or `Verified on simulator:` / `Verified on device:`) with a one-sentence observation of what was checked.

## Procedure

### Step 1: Start the Rendering Environment

Each project documents its dev-server commands in its own root CLAUDE.md or app CLAUDE.md. Common patterns:

- Web (Rails): `bin/dev` from the app root
- Web (Go/Jekyll/etc.): project-specific `make dev`, `go run`, `bundle exec jekyll serve`, etc.
- Apple: build and run on simulator via Xcode or `xcodebuild`
- Android: build and run on emulator via `./gradlew installDebug` or Android Studio

If the environment cannot be started, STOP. Report the blocker to the user. Do NOT claim the change complete.

### Step 2: Navigate to the Affected Surface

Use Chrome MCP for web:

- `mcp__claude-in-chrome__navigate` to the page that contains the change.
- Verify the change renders as intended.
- Check adjacent surfaces for regressions — a change to a hero section can shift everything below it.

For Apple and Android, bring the simulator/emulator forward and navigate to the affected screen.

### Step 3: Observe

Capture evidence:

- **Web** — screenshot via Chrome MCP. `mcp__claude-in-chrome__read_page` returns structure; use `mcp__claude-in-chrome__computer` or a Chrome DevTools MCP screenshot for pixels.
- **Apple** — simulator screenshot (`xcrun simctl io booted screenshot` or Xcode's screenshot button).
- **Android** — emulator screenshot via `scripts/android/screencap-verify.sh <label>` (preferred). The wrapper produces both a full-resolution `/tmp/<label>-raw.png` for ImageMagick pixel sampling AND a downscaled `/tmp/<label>.png` (long edge ≤ 1600px) safe to `Read` into agent context. A bare `adb exec-out screencap -p > /tmp/s.png` works on small AVDs but tall-screen devices (Pixel 10 Pro: 1280×2856) trip the 2000px many-image dimension cap when multiple captures land in one session — see HMB-29.

Check both the golden path and at least one edge case:

- Different viewport sizes (mobile + desktop for web) when layout is responsive.
- Dark mode when the design supports it.
- Empty state, loaded state, error state when the surface has state.

**Sample for color, Read for layout.** When the question is "did the tint apply?" or "is this exactly statusDanger?", pixel-sample the raw artifact (`magick /tmp/<label>-raw.png -format "%[pixel:p{X,Y}]" info:`) — that's a numeric assertion that doesn't require the image to enter agent context at all. Reserve the downscaled preview Read for layout/structural inspection ("does the logapp header look right next to the segment row"). The wrapper exists to make this split cheap; ignore it and you'll burn context on full-resolution captures past the dimension cap.

### Step 4: If Broken, Iterate Before Committing

If the render does not match intent, fix and re-render. Do NOT commit the broken attempt. Do NOT push it. The verification trailer certifies the rendered state — lying in it is a far worse violation than the original bug.

### Step 5: Commit with Verification Trailer

The commit message must include a trailer on its own line, after the issue reference. Example:

```
Close jarring break between hero and product demo on homepage

The product demo section pulled up 6rem over the hero, covering the
bottom of the paragraph and half of the CTA buttons.

Verified in browser: homepage at 1440w and 390w — hero paragraph and
both CTAs render fully; no overlap with product demo section below.

Closes #218
```

Acceptable trailer prefixes:

- `Verified in browser:` — web changes checked via Chrome MCP or a manual browser session.
- `Verified by XCUITest:` — Apple-platform changes certified by a passing XCUITest run. Names the test and destination. **This is the gate on Apple platforms** (see § Apple-platform Gate).
- `Verified on simulator:` — supplementary evidence on Apple platforms; accepted indefinitely for back-compat and for projects that have not yet adopted XCUITest coverage on the touched surface, but does NOT satisfy the gate on its own for new Apple-platform UI work. On Android, this remains the gate (until an instrumented-test gate lands).
- `Verified on device:` — physical-device check, supplementary only on Apple platforms.
- `UI verification waived:` — Apple-platform escape hatch per the waiver clause in § Apple-platform Gate. Cites the reference component and the follow-up issue.
- `UI verification skipped:` — permitted ONLY when the change genuinely has no rendered surface (see Scope exclusions). State the reason after the colon. Expect TPM to challenge this on audit.

The trailer must follow the one-sentence-observation format. `Verified in browser: looks good` is not an observation. `Verified in browser: /portal/123 renders the retry button without the orange badge; flash message dismisses on click` is.

**Trailer placement.** The hook (`scripts/hooks/ui-verification-check.sh`) is line-anchored, not git-trailer-block-style — it accepts the trailer anywhere in the commit body that starts a line with one of the accepted prefixes (`Verified in browser:`, `Verified by XCUITest:`, etc.). Both of the following pass:

```
… body …

Verified in browser: /case-A renders cleanly

Closes #218
```

```
… body …

Closes #218
Verified in browser: /case-B renders cleanly
```

The trailer-block placement (alongside `Closes` / `Co-Authored-By` after the last blank line) is the canonical form for git-trailer interop and is what `homebase work finish --append-closing` produces. The body-line placement is also valid by hook semantics. If a finish fails on `ui-verified` despite a trailer being present, the actual cause is almost always one of: misspelt prefix (e.g. "Verified on Browser:" with capital B), missing colon, the line starts with whitespace or a quote prefix (`> Verified in browser:`), or the relevant commit on the branch was amended after the trailer was added and the new SHA never carried it. Re-check the prefix and the git log before assuming the parser is at fault. (HMB-45 Finding 5 reproduction, §Step 5 of HOMEBASE-SOP-007.)

### Step 6: Push

Push only after the verification trailer is in place. The Stop-hook blocks session termination when unverified UI commits remain.

## Apple-platform Gate

For any change to a SwiftUI `View` body, `ViewModifier`, UIKit view controller, storyboard/xib, or shared design token consumed by a rendered surface, the verification gate is a passing XCUITest. Manual `xcrun simctl io booted screenshot` sessions are **supplementary evidence** on Apple platforms, not the gate. A screenshot certifies a moment; a UI test certifies a regression boundary.

### What the test must do

1. **Launch with bypass arguments.** Use `XCUIApplication().launchArguments` / `launchEnvironment` to skip onboarding, legal disclaimers, and any first-run gates so the test starts on a deterministic surface. LogApp's reference pattern: `-hasCompletedOnboarding YES -hasAcknowledgedSafetyDisclaimer YES`.
2. **Navigate via accessibility identifiers, not coordinates or visible labels.** Every interactive surface introduced or modified by the change MUST carry an `.accessibilityIdentifier(_:)` so the test can address it without depending on copy or geometry. Reuse existing identifiers (`settings_button`, etc.) where possible.
3. **Assert on the affordance.** The test must assert the *thing the change introduced* — `XCTAssertTrue(app.buttons["import_csv_cta"].exists)`, `XCTAssertTrue(app.staticTexts["Our other apps"].waitForExistence(timeout: 2))`, sheet presentation, navigation push, etc. A test that only launches the app does not certify the change.

### How to run it

```sh
xcodebuild test \
  -workspace <Workspace>.xcworkspace \
  -scheme <Scheme> \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  -only-testing:<UITestTarget>/<TestClass>/<testMethod>
```

Each Apple-platform project's `.homebase/workflow.yml` (or its app CLAUDE.md) declares the workspace, scheme, and UITest target — agents read it, they do not guess.

### Commit trailer

```
Verified by XCUITest: SlateUITests/SettingsViewUITests/test_settingsScreen_showsOurOtherAppsSection — passes on iPhone 17 Pro (iOS 18.2).
```

The trailer names the test and the destination. `Verified on simulator:` (manual screenshot) MAY appear alongside `Verified by XCUITest:` as supplementary evidence but does NOT satisfy the gate on its own for new Apple-platform UI work.

### Waiver clause (one-off escape hatch)

An operator MAY ship an Apple-platform UI change without a new XCUITest only when **all** of the following hold:

1. The change is a near-exact mirror of an already-shipping or already-tested UI in the same codebase (same component, same call-site shape, same data flow). Cosmetic deltas — different copy, different SF Symbol, different destination URL — are inside the waiver. Different state machines, different presentation modes, or new user-input affordances are NOT.
2. The reference is cited explicitly in the commit body by file path or by another app's already-shipped feature in the same monorepo (e.g. *"mirrors `GasCalc/Settings/SettingsView.swift` `otherAppsSection`, shipped in GasCalc 4.x"*).
3. The commit carries the trailer `UI verification waived: <reason citing the reference>` instead of `Verified by XCUITest:`.
4. The waiver is logged as a follow-up issue to add the missing test in the next maintenance cycle, and that issue identifier (Linear `KEY-N` or GitHub `#N`) is referenced in the trailer.

The waiver is one-off per change, not a per-codebase posture. Repeated waivers against the same reference component are a smell — at the second waiver, write the test.

### Why XCUITest specifically

`xcrun simctl` does not expose tap/swipe/type. AppleScript control of `Simulator.app` is unreliable headless. `cliclick` / `idb` / `idevice_id` are out-of-tree dependencies. Computer-use MCP is not granted at "click" tier for the iOS Simulator and dragging it in mid-session is brittle. XCUITest is the only verification path that (a) runs unattended, (b) runs in CI, (c) survives Xcode upgrades, (d) produces a green/red signal an agent can act on without a human in the loop. Snapshot tests (e.g. SnapshotTesting) are an *additional* tool for visual regression but the load-bearing property the SOP requires is **runnable assertion** — a snapshot test that drifts silently is no better than a screenshot.

## Enforcement

Three layers:

1. **Project Hard Rule.** Each adopting project cites HOMEBASE-SOP-007 as a Hard Rule in its root `CLAUDE.md`.
2. **Commit-message convention.** HOMEBASE-SOP-001 § B3 requires the `Verified …` trailer on UI-touching commits.
3. **Stop-hook.** `scripts/hooks/ui-verification-check.sh` (symlinked from homebase) inspects unpushed commits for UI-file changes; blocks stop if the trailer is missing.

### Hook Modes

The Stop-hook reads `HOMEBASE_UI_VERIFICATION` from the environment:

| Value | Behavior |
|---|---|
| unset or `strict` | Default. Blocks **every** Stop that sees an outstanding unverified UI commit. No warn-once dedupe — strict means strict. The earlier "warn-once-then-fall-silent" design was retired in the TFD-1408 retrospective because it was a single point of failure: one warning per session effectively let the rest of the session fall back to warn mode. |
| `warn` | Never blocks. Prints the violation on stderr the first time per SHA per session (deduped via `.claude/.ui-verification-warned`), then stays silent on repeats. Use on remote/headless machines where Chrome MCP and simulators aren't available. |
| `off` | Skips the check entirely. Escape valve of last resort — HOMEBASE-SOP-007 still applies; you're just turning off the automated gate. |

The default is `strict`. Override via shell profile on hosts that can't render a browser or boot a simulator. The SOP still mandates verification before a UI commit is declared done — the hook modes exist so agents stuck in an environment that physically can't satisfy the rule don't spin on every Stop event.

### Exclusions

The hook's UI pattern is narrowed by an exclusion list. Files under these paths are treated as non-rendered and skipped before the UI pattern is evaluated:

- `**/fixtures/**/*.html` — test fixtures
- `**/vendor/**`, `**/node_modules/**` — third-party
- Any path a project declares in its own `.ui-verification-excludes` file (one glob per line), for project-specific cases (design-system preview pages, static sandbox fixtures, etc.)

A commit that only touches excluded paths will not trigger the hook. A commit that touches both an excluded path and a real rendered surface still needs the verification trailer — the hook evaluates the remaining files after exclusion.

## Failure Mode This Prevents

A five-commit cycle on a web homepage, three failed fixes claimed complete without browser verification. Each iteration, the user returned with a screenshot showing the change still broken. The Chrome MCP tool was available throughout; it was only used on the fourth attempt. The rule existed in CLAUDE.md as general guidance but was treated as optional. This SOP and the accompanying hook make it a gate.

## Related

- `HOMEBASE-SOP-001-DEVELOPMENT_WORKFLOW.md` § B3 — verification trailer format
- `HOMEBASE-SOP-010-HIG_COMPLIANCE.md` — HIG consultation for Apple UI (complementary: HIG governs the design; HOMEBASE-SOP-007 governs the verification that it renders)
- `scripts/hooks/ui-verification-check.sh` — Stop-hook enforcement (symlinked from homebase)
