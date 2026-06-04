---
name: process-interview
description: "HOMEBASE-SOP-011 customer-research synthesis. Use when processing an interview transcript, observation, or analysis session into a structured research artifact and updating THINKING_PATTERNS.md."
---

# Process Interview — HOMEBASE-SOP-011 Wrapper

Process a customer interview / observation / analysis into a structured research artifact, and update the relevant persona's `THINKING_PATTERNS.md`.

**Scope**: projects that adopt HOMEBASE-SOP-011 Customer Research (declared in the project's root `CLAUDE.md` § Adopted SOPs).

## Canonical Process

Follow **HOMEBASE-SOP-011** § 3 (Research Artifact Standards) and § 4 (Synthesis Cadence).

## Input

The user provides:

- A transcript, observation notes, or analysis text (pasted into the conversation).
- Optionally: which persona this is about (if not obvious from the content).
- Optionally: a topic label (if not obvious).

## Procedure

### Step 1: Identify the Persona, Type, and Topic

From the transcript, determine:

- **Persona**: the project's `Customers/README.md` maps personas to apps. Pick the one that matches.
- **Type**: `interview` (structured conversation), `observation` (watching them work), `analysis` (synthesis of multiple sessions), or `hypothesis` (claim needing validation).
- **Topic**: 2–3 words for the filename slug (e.g., `content-workflow`, `client-onboarding`).

For genuinely ambiguous input you cannot resolve from context, ask once.
Do not generalize this to routine decisions where you have the inputs.
If anything is ambiguous, ask the user before writing anything.

### Step 2: Create the Research Artifact

Write to `Customers/{persona}/research/{YYYY-MM-DD}-{type}-{topic}.md` using today's date.

Use the format from the project's `Customers/RESEARCH_STANDARDS.md` (which mirrors `~/code/homebase/governance/RESEARCH_STANDARDS.md`):

```markdown
# {Type}: {Topic}

**Date:** {YYYY-MM-DD}
**Participants:** {who was present}
**Context:** {what prompted this}

## Transcript

{Clean up obvious transcription errors; add paragraph breaks; DO NOT paraphrase or summarise. The customer's actual words are the data.}

## Key Observations

- New patterns not previously documented
- Confirmations of existing THINKING_PATTERNS entries
- Contradictions with existing assumptions
- The customer's own framing vs. the builder's framing

## Open Questions

{What remains unclear — what to explore next time}

## Implications

{Links to specific apps/features this affects, with concrete reasoning}
```

### Step 3: Analyse Against the Six Categories (HOMEBASE-SOP-011 § 5)

Read the current `Customers/{persona}/THINKING_PATTERNS.md`. For each of the six categories, evaluate whether the session reveals anything:

1. **Mental Models** — how they conceptualise their domain.
2. **Pain Patterns** — friction they have normalised.
3. **Decision Heuristics** — how they decide / prioritise.
4. **Emotional Landscape** — what creates stress, confidence, anxiety.
5. **Language Patterns** — vocabulary, not industry terms.
6. **Workflow Observations** — their actual day.

For each category:

- **New observation**: add it with the date tag `*(YYYY-MM-DD)*`.
- **Confirms existing**: note the confirmation, do not duplicate.
- **Contradicts existing**: update the entry, noting the evolution.
- **Changes design implications**: update them.

### Step 4: Update THINKING_PATTERNS.md

Write the updated file. Preserve existing observations that are not contradicted; add new observations under the appropriate category with a date tag. **Each category MUST carry a "Design implications" subsection** (per HOMEBASE-SOP-011 § 5) that translates the observed patterns into concrete product guidance — update or add it for any category that changed in this session, even if you only added a single observation.

### Step 5: Privacy Check (real customers only)

Before committing, verify:

- No specific third-party names (abstract them: "a client" not "Cronos").
- No financial details beyond what's relevant to the business model.
- The "would the customer be comfortable reading this?" test passes on `THINKING_PATTERNS.md` and synthesis docs.

Raw transcripts in `research/` may retain names as spoken (the customer participated in creating them). Abstraction applies to synthesis, not to raw source.

### Step 6: Report

Summarise to the user:

- Path of the new research artifact.
- Which THINKING_PATTERNS categories were updated.
- 2–3 key insights.
- Open questions worth exploring next session.
- Any implications for active development.

## Notes

- Voice-transcription errors are common; preserve the customer's vocabulary — that vocabulary IS the data for Language Patterns.
- Watch for the customer's framing vs. the builder's framing — the difference often matters more than the content.
- Self-correction moments are high-signal: when the customer corrects the interviewer's word choice, they are revealing their mental model.

## Related

- `@~/code/homebase/sops/HOMEBASE-SOP-011-CUSTOMER_RESEARCH.md` — full SOP.
- `@~/code/homebase/governance/RESEARCH_STANDARDS.md` — artifact standards and templates.
- The project's `Customers/README.md` — persona-to-app mapping for Step 1.
- `~/code/homebase/skills/process-feedback/SKILL.md` — sibling skill for
  single-datapoint actionable user feedback (feature-request / bug). It
  files a Linear issue against the app's project with the mandatory
  `## Acceptance Criteria` block; there is no on-disk feedback artifact —
  the Linear issue is the durable record. Non-actionable inputs (praise,
  questions, pattern signal about the user) route to `/process-interview`
  instead.
