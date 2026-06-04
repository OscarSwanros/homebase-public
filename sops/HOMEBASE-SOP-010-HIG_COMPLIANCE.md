# HOMEBASE-SOP-010: HIG Compliance

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Canonical procedure for consulting Apple's Human Interface Guidelines when doing UI, interaction, or platform-convention work on Apple platforms (iOS, iPadOS, macOS, watchOS, tvOS, visionOS).

## Scope

All agents performing code work on Apple-platform projects that adopt this SOP. Adoption is declared in the project's root CLAUDE.md § Adopted SOPs. Projects that ship no Apple-platform apps do not adopt this SOP.

**Agents primarily responsible**: `swift-architect`, `ui-ux-designer`, and the relevant product manager for the Apple-platform app. All other agents must flag in-scope work during review.

---

## 1. When This SOP Applies

Triggered by any code work involving:

- UI layout, controls, or visual hierarchy
- Navigation patterns (tab bars, sidebars, split views)
- Window management or menu bar behaviour (macOS)
- Notifications or alerts
- System integration (sharing, files, drag and drop, Shortcuts)
- Platform-specific interaction patterns (gestures, haptics, context menus)
- Accessibility implementation

Does **not** apply to:

- Backend logic, data models, or networking code with no UI surface
- Documentation-only changes
- Build configuration or CI/CD changes

---

## 2. Procedure

### Step 1: Identify the Relevant HIG Section

Before implementing or reviewing UI work, determine which HIG topic applies. Use the reference index at `https://sosumi.ai/design/human-interface-guidelines` to find the correct Apple documentation URL for the topic.

### Step 2: Fetch and Review the HIG Section

Use `WebFetch` to retrieve the relevant HIG page. The base URL structure is:

```
https://developer.apple.com/design/human-interface-guidelines/{section}
```

Retrieve the specific section, not the entire HIG. If multiple sections are relevant, fetch each one.

### Step 3: Apply HIG Guidance

Incorporate the HIG guidance into your implementation or review. When the HIG prescribes a specific behaviour or pattern, follow it unless there is a documented reason to deviate (see § 5).

### Step 4: Document What Was Checked

In your work output (commit message, PR description, or agent response), note:

- Which HIG section(s) you consulted.
- Any specific guidance that informed your decisions.
- Any intentional deviations and why (see § 5).

---

## 3. Key HIG Areas by Work Type

Use this table to identify which HIG sections to check for common work types. This is a starting point, not exhaustive.

| Work Type | HIG Sections to Check |
|---|---|
| Menu bar apps (macOS) | Menu bar extras, Menus, The menu bar |
| Window management | Windows, Multitasking (iPadOS) |
| Notifications | Notifications |
| Controls | Buttons, Toggles, Pickers, Sliders, Text fields |
| Navigation | Navigation bars, Tab bars, Sidebars, Search |
| Alerts and dialogs | Alerts, Confirmation dialogs, Sheets |
| System integration | Sharing, Files and folders, Drag and drop, Shortcuts |
| Lists and data display | Lists, Tables, Collections |
| Text and typography | Typography, Text fields, Labels |
| Accessibility | Accessibility (all subsections) |
| App lifecycle | Launching, Onboarding, Loading, Status bars |
| Platform conventions (macOS) | The menu bar, Dock, Toolbars |
| Platform conventions (iOS) | Home Screen, Lock Screen, Status bars |

---

## 4. Reference Index

The comprehensive HIG reference index is available at:

```
https://sosumi.ai/design/human-interface-guidelines
```

This index maps HIG topics to their corresponding Apple documentation URLs and is the fastest way to find the correct page to fetch.

---

## 5. Intentional Deviations

A project may intentionally deviate from HIG when:

1. **Product philosophy takes precedence.** HIG may suggest engagement patterns (badges, counts, streaks) that conflict with the project's own principles. In those cases, the project's philosophy wins. The project documents the principle in its root CLAUDE.md (or a dedicated philosophy doc); HIG Compliance respects it.
2. **The product's design language requires it.** Projects with an editorial or brand-specific design aesthetic may diverge from default system styling while still respecting platform interaction patterns.
3. **Accessibility would be harmed.** If following a HIG pattern creates an accessibility regression, deviate in favour of accessibility.

All intentional deviations MUST be documented in the commit or PR with the reason and a link to the project principle or rule that justifies them.

---

## 6. Responsibility

| Role | Responsibility |
|---|---|
| `swift-architect` | Primary enforcer. Must consult HIG before implementing or reviewing UI code on Apple platforms. |
| `ui-ux-designer` | Must consult HIG when designing interactions or layouts for Apple-platform apps. |
| Relevant product manager | Must consult HIG when specifying features that involve platform-native patterns. Project-scoped PMs (per project's root CLAUDE.md) apply. |
| All agents | Must flag UI work that falls under this SOP's scope during reviews. |

---

## 7. Relationship to Other Documents

| Document | Relationship |
|---|---|
| Project's design rules (e.g. `Documentation/Design/DESIGN_RULES.md`) | Defines the project's cross-product design tokens. HIG governs platform-native behaviour. Both apply; HIG takes precedence for platform conventions unless § 5 applies. |
| Project's design philosophy | Explains *why* the project designs the way it does. HIG explains *how* the platform expects things to work. |
| Project's architectural patterns (e.g. `AVFOUNDATION_PATTERNS.md`) | Document Apple framework usage. HIG governs the user-facing behaviour built on top of those frameworks. |
| Project root `CLAUDE.md` Philosophy / Hard Rules | Overrides HIG when they conflict (see § 5). |
| `HOMEBASE-SOP-007-UI_VERIFICATION.md` | Complementary: HIG governs the design; UI Verification governs the observation that it renders. |
