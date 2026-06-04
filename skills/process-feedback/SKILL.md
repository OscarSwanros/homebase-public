---
name: process-feedback
description: "Process a single piece of actionable user feedback (email, in-app form, App Store review) into a Linear issue against the app's project, with the required Acceptance Criteria block. Lighter-ceremony sibling of /process-interview; feedback is actionable by default — non-actionable inputs route to /process-interview or are handled directly."
---

# Process Feedback

Process **one** piece of user feedback into a Linear issue against the
app's Linear Project.

Feedback is actionable by default. The two classes this skill handles
are `feature-request` and `bug` — both produce a Linear issue with a
mandatory `## Acceptance Criteria` block. Praise, questions, confusion
notes, and miscellaneous inputs do **not** produce tracked work from
this skill — they route to `/process-interview` (if they carry pattern
signal about the user) or get handled by the operator directly.

This is the lightweight sibling of `/process-interview`. Interviews
gather personality and pattern data; their output lives in
`Customers/{persona}/...` and synthesises across many sessions. Feedback
files work — its output lives in Linear. There is no on-disk feedback
artifact; the Linear issue is the durable record.

**Scope:** projects whose `.homebase/project.yml` declares `apps[]`.
The resolved app entry must have `roadmap.enabled: true` and both
`linear_team_id` and `linear_project_id` set — otherwise the skill
exits with a setup hint and does nothing.

## Input

The user pastes the feedback into the conversation. A typical message
looks like:

```
Even with Technical Diver mode enabled, the Best Gas calculator doesn't
allow you to select trimix, making it unsuitable for technical diving.

Can you add the ability to see trimix mixes on this screen?

--- Technical Information ---
App: GasCalc 1.1.2 (1)
iOS: 26.4.2
Device: iPhone
Technical Diver: Yes
…
```

The user **may** also specify a **source channel** —
`in-app` | `email` | `app-store` | `slack` | `other`. If unstated, ask
once; default to `in-app` if the operator skips (the
`--- Technical Information ---` footer is the in-app feedback form's
signature, so this is the most common case).

If the body is empty, or `App:` is absent and the user did not name
the app, ask. Do not file anything until the input is clear.

## Procedure

### Step 1: Parse the input

- Split the body from any `--- Technical Information ---` footer
  (or equivalent delimiter — be tolerant: `---Technical Information---`,
  `=== TECH ===`, etc.).
- From the footer, extract a key/value map. Recognise `App`, `iOS`,
  `Android`, `OS`, `Device`, `Locale` as canonical; preserve every other
  key verbatim (app-specific settings like `ppO₂ Limits`, `SAC Rate`,
  etc. matter for reproducing bugs).
- From `App: <name> <version>` extract `app_alias` (the name) and
  `app_version` (the rest of that line).

### Step 2: Resolve the app and the Linear coordinates

- Resolve `app_alias` to an absolute project + app path using the
  **Alias Index** in `~/code/homebase/registry/PROJECTS.md`.
- From the resolved app path, walk up to the project root and read its
  `.homebase/project.yml`. Find the `apps[]` entry whose `name` or
  `aliases` matches `app_alias`.
- Read:
  - `roadmap.enabled` (bool)
  - `roadmap.linear_team_id`
  - `roadmap.linear_project_id`
- **Hard exit:** if `roadmap.enabled` is false or either id is missing,
  stop. Tell the operator exactly what's missing in `project.yml` and
  exit without filing anything. There is no artifact fallback.

### Step 3: Classify

Pick exactly one:

| Class | Means | This skill files? |
|---|---|---|
| `feature-request` | User wants something the app doesn't do. | **Yes** |
| `bug` | User reports incorrect behaviour or a crash. | **Yes** |
| `praise` | Thanks / positive note. | No — reply to the user directly. |
| `confusion` | User couldn't find / understand something. | No — reclassify as `bug` (UX) or `feature-request` (missing capability), or route to `/process-interview` if it's pattern signal. |
| `question` | User is asking how to do X. | No — answer directly. |
| `other` | Doesn't fit above. | No — operator decides. |

For genuinely ambiguous input you cannot resolve from context, ask once.
Do not generalize this to routine decisions where you have the inputs.
If the classification is ambiguous, propose your best pick with a
one-line justification and ask the user.

**Non-actionable exit.** For `praise`, `confusion`, `question`, or
`other`: state the classification, give the routing hint from the table
above, and stop. Do not file anything.

### Step 4: File the Linear issue (`feature-request` or `bug` only)

1. **Title** — ≤ 80 chars, imperative mood. Example:
   `Best Gas: recommend trimix when Technical Diver mode is on`.

2. **Description** — real newlines, not `\n` escapes (per the Linear
   MCP plugin's instructions). Must contain, in order:

   ```markdown
   <one-line summary of the problem and intended outcome>

   **Source:** in-app | email | app-store | slack | other

   > <verbatim quote, single blockquote — preserve the user's voice,
   > self-correction, hedging, and vocabulary; DO NOT paraphrase>

   ## Technical context

   | Field | Value |
   |---|---|
   | App | <name> <version> |
   | OS | <iOS|Android|OS> <version> |
   | Device | <device> |
   | Locale | <locale> |
   | <app-specific key> | <value> |
   …

   ## Acceptance Criteria

   - [ ] <criterion 1>
   - [ ] <criterion 2>
   …
   ```

   Optional sections (include when the operator or consulted agents
   have produced them) — placed **between** the technical context and
   the Acceptance Criteria block:

   - `## Implementation pointers` — bulleted file paths and short
     notes about where the gap lives. Useful when a domain agent (PM,
     architect, science advisor) has already inspected the code as
     part of the feedback intake.
   - `## Resolved design questions` — bulleted decisions for
     questions the AC settles, so the implementer doesn't re-litigate
     them.

   The `## Acceptance Criteria` heading + at least one `- [ ]` checkbox
   are **mandatory** — `scripts/hooks/linear-cli-guard-hook.sh`
   (validated by `scripts/lib/ac-regex.sh`) rejects creates that lack
   them.

3. **Optional: resolve the `roadmap` label.** Call
   `mcp__plugin_linear_linear__list_issue_labels` filtered by the
   resolved `teamId` (and `name: "roadmap"` for a direct lookup); pass
   its id in `labels` on the create. If the lookup fails or the label
   isn't present, omit `labels` — `roadmap` is convention, not a
   hard gate.

4. **Create the issue.** Call
   `mcp__plugin_linear_linear__save_issue` with:

   - `team` — `linear_team_id` from project.yml
   - `project` — `linear_project_id` from project.yml
   - `title`
   - `description`
   - `labels` (optional, only if the roadmap label resolved)

   Do **not** pass `id` — that turns the call into an update and
   bypasses the AC create-gate.

5. **Hook rejection.** If the linear-cli-guard hook rejects the create
   (missing AC, malformed description), surface the rejection to the
   operator verbatim and confirm a corrected AC block before retrying.
   Do not silently retry.

### Step 5: Report

Print a concise summary:

- **Linear:** `<KEY-N>` + URL.
- **Classification:** `feature-request` or `bug`.
- **App / Project:** resolved app name + project.
- **Anything missing:** e.g. source channel defaulted to `in-app`,
  `roadmap` label not found and omitted, ambiguous classification
  confirmed with operator.

## Notes

- One feedback per run. If the user pastes multiple items, ask which
  one to process and tell them to re-run for the others.
- The skill files a Linear issue but does **not** commit code. The
  operator decides whether to start tracked work against the new
  issue (`homebase work start <KEY>` → implement → finish) immediately
  or queue it for later.
- Preserve the user's voice in the Quote. Self-correction, hedging,
  and vocabulary choices (e.g. "Best Gas calculator", "trimix mixes")
  are signal — do not normalise them.
- Tech-context tables matter for bug repro. Even if a field looks
  irrelevant ("Standard Mixes: Disabled"), keep it — reproducing the
  bug may depend on it.
- For safety-critical apps (e.g. GasCalc), consider consulting the
  app's PM agent and domain advisor (e.g. `diving-product-manager`,
  `dive-science-advisor`) **before** filing — their bullets compose
  into the Acceptance Criteria block as a safety contract. This is
  optional and operator-driven, not a step the skill mandates.

## Related

- `~/code/homebase/skills/process-interview/SKILL.md` — sibling skill;
  the non-actionable route for pattern-signal feedback.
- `~/code/homebase/registry/PROJECTS.md` — Alias Index used in Step 2.
- `~/code/homebase/sops/HOMEBASE-SOP-013-ROADMAP_MANAGEMENT.md` and
  `~/code/homebase/standards/LINEAR_WORKSPACE.md` — Linear issue
  conventions (Team / Project / Milestone roles, label set).
- `~/code/homebase/scripts/lib/ac-regex.sh` — the regex contract the
  description must satisfy on create.
- `~/code/homebase/scripts/hooks/linear-cli-guard-hook.sh` — the hook
  that enforces the AC contract at MCP-call time.
