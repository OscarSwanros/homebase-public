# HOMEBASE-SOP-008: Failure State Data Preservation

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

## Purpose

Prevent the failure mode where a pipeline — any multi-step process that consumes user-generated inputs — presents the user with a Retry-or-Discard binary that gates access to their own raw data. Users invest real time producing recordings, transcripts, drafts, uploads, and narration. When a downstream step fails, that raw input still belongs to them. It must always be recoverable.

## Scope

All agents, all projects that adopt this SOP.

Applies to any UI that renders a terminal failure state after the user has produced inputs the failing step consumed. Example pipelines:

- Post-transcription or post-analysis failure (user has the recording and transcript).
- Form-submission failure after a file upload (user has the file).
- Form-submission failure after a long-form draft (user has the draft).
- File-import failure after parse (user has the raw bytes).
- Any multi-step flow where work is captured before the failing step.

## The Rule

**A failure-state screen must offer a way to save every raw artifact the user produced before the failure.** The user decides whether to retry, recover the inputs, or discard — but "retry or discard" alone is a violation. Recovery is the first-class option, not a hidden escape.

Three requirements:

1. **Inventory** — For every failure state, enumerate what inputs the user generated before the failure. Treat the file on disk, the in-memory transcript, the uploaded blob, the unsaved draft all as artifacts.
2. **Offer** — For each artifact present, render a save action in the failure UI. Disable or hide the action only when the artifact genuinely does not exist (e.g., no transcript yet if transcription itself was the failing step).
3. **Order** — Save actions appear visually **before** (above or to the left of) Retry and Discard. The ordering communicates "your work is safe here" without requiring reassurance copy.

## Procedure

### Step 1: Identify Failure States

When designing or reviewing any multi-step flow, list the terminal failure states — the screens the user reaches when a step fails and no automatic recovery is possible.

### Step 2: Enumerate Artifacts at Each Failure Point

For each failure state, answer: "At this point, what has the user produced that now exists (on disk, in memory, or in transit)?" Include:

- Files already written to disk or temp directories
- State held in memory by the session
- Uploads completed before the failing step
- Drafts or form inputs the user typed

### Step 3: Render a Save Action per Artifact

Each artifact gets its own action, labeled for what it is (e.g., `Save Video…`, `Save Transcript…`, `Save Draft…`). Ellipsis indicates a system dialog (NSSavePanel, `<input type=file>` save target, or equivalent).

Place the save actions above or to the left of Retry / Discard. Group them visually so the preservation options read as a unit.

### Step 4: Verify the Save Path

Exercise each save action end-to-end before shipping. Confirm:

- The saved file opens in a reasonable external viewer.
- The saved content matches what the user expects (video plays; transcript has the narration; draft has the text).
- Save failures surface a readable error — never fail silently.

### Step 5: Cite in the Commit

Include a brief note in the commit message for any change that adds or modifies a failure-state screen:

```
Failure-state artifacts preserved: Save Video, Save Transcript
```

Or, if a failure state legitimately has nothing to preserve (the failing step was the first input-consuming step):

```
Failure-state: no user artifacts present before failure
```

## Anti-Patterns

- **Retry / Discard with no save option** — the violation this SOP exists to prevent.
- **Save hidden behind a menu** — the save action is the primary affordance; if a user has to discover it, it's too late.
- **Wrapping save actions inside Retry** — a retry flow that happens to save a copy is not a save action. The user must be able to preserve without also re-running the failed step.
- **Generic "Export" buttons** — name the artifact (`Save Video`, `Save Transcript`). "Export" is vague and implies transformation.
- **Destructive prominence** — making Discard the primary call-to-action signals "throw it away" by default. Retry or the save actions belong as the emphasized option, never Discard.

## Notes

- This is a product principle, not a code rule. The same discipline applies to designs in Figma or other tools before a single line is written.
- When adding a new pipeline stage, treat this SOP as a design input — fit the new stage into the existing failure UI's artifact inventory.
- The rule extends to pipelines whose output could be reconstructed from the input — never assume "they can just redo it." A 10-minute narrated walkthrough is not a thing the user redoes cheerfully.

## Adoption

Each adopting project cites HOMEBASE-SOP-008 as a Hard Rule in its root CLAUDE.md and grounds the rule in its own product philosophy where applicable. Projects that design flows without user-generated inputs (e.g., pure dashboarding tools with no capture step) may opt out.
