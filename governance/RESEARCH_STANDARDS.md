# Customer Research Standards

Artifact standards for the `Customers/` directory. Governed by [HOMEBASE-SOP-011 Customer Research](../sops/HOMEBASE-SOP-011-CUSTOMER_RESEARCH.md).

This is a reference for projects that adopt HOMEBASE-SOP-011 and set up their own `Customers/` structure.

---

## Directory Layout

```
Customers/
  README.md              # customer-to-app mapping
  <persona>/             # one directory per persona (real person or archetype)
    PROFILE.md           # who they are
    THINKING_PATTERNS.md # how they think — 6-category analysis
    apps.md              # which apps are built for them and why
    research/            # dated raw artifacts (empty until first session)
      YYYY-MM-DD-<type>-<topic>.md
```

`<persona>` slugs are lowercase, hyphenated: `operator`, `new-diver`, `shop-operator`, `client`. No spaces.

## Artifact Types

Every artifact in `research/` must declare its type in the filename and the document header.

| Type | Filename prefix | Description |
|---|---|---|
| **Interview** | `YYYY-MM-DD-interview-<topic>.md` | Structured notes from a direct conversation with a real customer |
| **Observation** | `YYYY-MM-DD-observation-<topic>.md` | Notes from watching the customer work (not prompted) |
| **Analysis** | `YYYY-MM-DD-analysis-<topic>.md` | Synthesis across multiple observations or inputs — often the bridge between raw research and THINKING_PATTERNS updates |
| **Hypothesis** | `YYYY-MM-DD-hypothesis-<topic>.md` | A claim that needs validation — useful for archetypes where direct observation is not possible, or for self-research when the builder is testing an assumption |

## Artifact Format

Every research artifact in `research/` must include:

```markdown
# [Type]: [Topic]

**Date:** YYYY-MM-DD
**Participants:** [who was present — for interviews; "self" for journaling; "n/a" for analyses]
**Context:** [what prompted this — a scheduled interview, watching them work, a conversation, a synthesis pass]
**Persona:** [real | archetype | self]

## Transcript / Notes

[Raw content — conversation transcript, observation notes, analysis, or hypothesis statement]

## Key Observations

- [What surprised or confirmed something]
- [New pattern noticed]
- [Contradiction with existing assumptions]

## Open Questions

- [What remains unclear]
- [What to explore in the next session]

## Implications

- [Link to specific app/feature this affects]
- [How this should change an existing assumption]
- [Did this update PROFILE.md or THINKING_PATTERNS.md? Name the sections touched.]
```

The **Implications** section is how research connects to product decisions. If a research session has no implications, it's either not ready to end or the session didn't earn its keep — close it honestly and move on.

## Privacy

**The test**: Would the customer be comfortable reading this document?

### Store

- Synthesized thinking patterns.
- Generalised pain patterns.
- Language patterns (vocabulary, not private statements).
- Workflow patterns (abstracted).

### Do NOT store

- Specific client names, business-sensitive financial information, or personal relationship context.
- Verbatim quotes from private conversations without consent.
- Anything that feels like surveillance rather than understanding.

**Abstraction is the protection.** "She batches client management into morning blocks" is useful and non-invasive. "She spends 45 minutes every morning answering Maria's emails about the rebrand" is too specific.

**Archetypes** are exempt from consent (no real person to consult), but must still be grounded in real evidence. Mark speculation explicitly: `[hypothesis — needs validation]`.

**For third-party real customers** (beyond self and close collaborators): require formal consent, explicit scope, right to review and removal.

## Synthesis Cadence

After each research session:

1. Add the raw artifact to `research/`.
2. Review `THINKING_PATTERNS.md` — does this session reveal something new or contradict something existing?
3. If yes, update the relevant category with the new insight and today's date.
4. Review `PROFILE.md` — does this session change the customer's profile?
5. If yes, update PROFILE.md.

`THINKING_PATTERNS.md` should always reflect the current best understanding. It does not grow indefinitely — it evolves. When a new insight supersedes an old one, replace it. When confidence increases, note it.

## Language of Provenance

Use these markers consistently in persona files so agents know how much weight to give each claim:

| Marker | Meaning |
|---|---|
| `(YYYY-MM-DD)` | Observation from a dated research artifact — highest confidence |
| `[hypothesis — needs validation]` | Inferred or assumed; mark explicitly and schedule research to confirm or refute |
| `[research gap]` | No data yet; agents must not invent this |
| `[supersedes earlier]` | Updated insight replacing an older claim — optionally link to the previous research artifact |

## README.md

The `Customers/README.md` file at the top of the directory indexes all personas and maps them to the apps they're the target for. A small table is enough:

```markdown
# Customers

This project builds apps for these personas. Each entry maps to a directory with PROFILE, THINKING_PATTERNS, apps.md, and a research folder.

| Persona | Directory | Type | Apps | Notes |
|---|---|---|---|---|
| the operator | `operator/` | Real | GasCalc | Builder-as-customer — self-research only |
| New diver | `new-diver/` | Archetype | LogApp | Synthesized from industry research + product history |
| Shop operator | `shop-operator/` | Archetype | ShopOS | Synthesized from dive-shop observation and support tickets |
```

See [HOMEBASE-SOP-011 Customer Research](../sops/HOMEBASE-SOP-011-CUSTOMER_RESEARCH.md) for governance and [templates/Customers/](../templates/Customers/) for scaffolds to copy.
