# HOMEBASE-SOP-011: Customer Research

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Canonical procedure for creating, maintaining, and using customer-research artifacts across every homebase-adopting project. Makes the person behind each product visible to every agent, so features are built from observed behavior rather than assumptions.

## Scope

Opt-in per project. Projects that adopt HOMEBASE-SOP-011 declare it in their root CLAUDE.md § Adopted SOPs, create a `Customers/` directory, and populate it with per-persona profiles (real customers or documented archetypes).

**When this SOP is adopted**, it applies to all agents involved in feature design, development, or review in that project.

## 1. Customer Context Is Mandatory for Feature Work

Before designing or building a new feature, the responsible agent MUST consult:

1. `Customers/<persona>/PROFILE.md` — who the customer is (identity, professional context, relationship to technology).
2. `Customers/<persona>/THINKING_PATTERNS.md` — how they think, decide, and work.

Applies to: new features, significant UI changes, workflow redesigns, product strategy decisions.

Does **not** apply to: bug fixes, infrastructure changes, or documentation-only work.

If `THINKING_PATTERNS.md` has no data for a relevant category, **name the gap — do not invent assumptions to fill it.** "Research gap" is an acceptable output of a feature evaluation.

## 2. Real Customers vs Archetypes

Two valid persona types:

| Type | Example | Sourcing |
|---|---|---|
| **Real customer** | A specific named person (e.g. "the operator", a named client) | Observations and interviews with that person. Subject to privacy guardrails (§ 5). |
| **Archetype** | A composite persona (e.g. "new-diver", "shop-operator") | Synthesized from multiple observations, industry research, and product history. Useful for B2C products where the customer base is broad. |

Both use the same artifact structure. The difference is in the sourcing: real customers require direct observation; archetypes require documented synthesis. Archetypes should cite the sources that inform them (industry data, support tickets, past user research, existing product docs).

**Rule**: an archetype is not a fiction. Every claim in an archetype's PROFILE or THINKING_PATTERNS must trace back to observed evidence (even if aggregated from many sources). If a claim is speculation, mark it `[hypothesis — needs validation]` or leave the field empty with `[research gap]`.

## 3. Research Artifact Standards

### When to create an artifact

- A structured interview with the customer (real person).
- An observation session (watching them work).
- A synthesis session analyzing multiple observations or research inputs.
- A hypothesis session — noting a claim that needs validation.

### Format

See [RESEARCH_STANDARDS](../governance/RESEARCH_STANDARDS.md) for the full template. Summary:

- **Location**: `Customers/<persona>/research/`.
- **Naming**: `YYYY-MM-DD-<type>-<topic>.md` where `<type>` is `interview`, `observation`, `analysis`, or `hypothesis`.
- **Required sections**: Date, participants, context, transcript/notes, key observations, open questions, implications.

### No binary files

Audio/video recordings stay external (local machine, cloud storage). Only markdown transcripts and notes enter the repo.

## 4. Synthesis Cadence

After each research session:

1. Add the raw artifact to `Customers/<persona>/research/`.
2. Review `THINKING_PATTERNS.md` — does this session reveal something new or contradict something existing?
3. If yes, update the relevant category with the new insight and today's date.
4. Review `PROFILE.md` — does this session change who the customer is (new role, new tools, new context)?
5. If yes, update PROFILE.md.

`THINKING_PATTERNS.md` evolves — it does not grow indefinitely. When a new insight supersedes an old one, replace it. When confidence increases, note it.

## 5. Six Categories in THINKING_PATTERNS.md

| Category | What to Capture | Agent Use Case |
|---|---|---|
| **Mental Models** | How they conceptualize their domain | Data models, information architecture |
| **Pain Patterns** | Friction they have normalized | Feature validation: does this address a documented pain? |
| **Decision Heuristics** | How they decide, evaluate, prioritize | Information hierarchy: what is visible vs hidden |
| **Emotional Landscape** | What creates stress, confidence, anxiety | What feels prescriptive vs supportive |
| **Language Patterns** | Their actual vocabulary, not industry terms | UI copy, brand voice calibration |
| **Workflow Observations** | What their actual day looks like | Interaction models: batch vs interleaved, sync vs async |

Each category must include a **Design implications** section that translates observed patterns into concrete product guidance.

## 6. Privacy Guardrails (Real Customers Only)

**The test**: Would the customer be comfortable reading this document?

### What to store

- Synthesized thinking patterns.
- Generalised pain patterns.
- Language patterns (vocabulary, not private statements).
- Workflow patterns (abstracted).

### What NOT to store

- Specific client names or business-sensitive information.
- Personal relationship context.
- Verbatim quotes from private conversations without consent.
- Financial details beyond what is relevant to understanding their business model.
- Anything that feels like surveillance rather than understanding.

### Abstraction is the protection

- "She batches client management into morning blocks" — useful, non-invasive.
- "She spends 45 minutes every morning answering Maria's emails about the rebrand" — too specific.

### Third-party customers (beyond self and close collaborators)

Require explicit consent, define scope, provide right to review and removal.

### Archetypes

No consent needed (no real person to consult), but archetypes must be grounded in real evidence. Do not use an archetype as cover for fabricated patterns.

## 7. Self-Research (Builder-as-Customer)

When the builder is also a customer of the product (a common pattern for personal-brand or hobbyist tools), self-research requires different methods:

- **Workflow journaling** — catching yourself in workarounds.
- **Language auditing** — what words do you actually use?
- **Decision introspection** — when deciding "from the gut," documenting what the gut responds to.
- **Friction threshold calibration** — "Would someone with my interests but NOT my builder context accept this?"

The self-research test: "Would a non-builder version of me tolerate this?"

Same document structure, same categories, different process. The risk is that the builder tolerates friction in tools they built. Watch for "I can just..." statements — those are the patterns a non-builder customer would not accept.

## 8. Responsibility

| Role | Responsibility |
|---|---|
| **Product manager(s)** for the product/brand | Primary owners of customer research for the relevant persona(s). Structure interviews, synthesize findings, maintain PROFILE and THINKING_PATTERNS. |
| **`ui-ux-designer`** | Consults workflow observations and language patterns (impacts UI design) |
| **`brand-manager`** | Consults language patterns and emotional landscape (impacts voice and tone) |
| **`copywriter`** | Consults language patterns (impacts UI copy) |
| **All agents** | Must consult customer context before feature work, per this SOP |

## 9. Relationship to Other Documents

| Document | Relationship |
|---|---|
| Project's strategic persona doc (e.g. CUSTOMER_DEFINITION, PRODUCT_STRATEGY) | Strategic: who we build for (broad). Customer research is tactical: how they think. |
| `Customers/<persona>/PROFILE.md` | Canonical per-persona detail |
| Project design philosophy doc | Customer research grounds design philosophy in observed behavior |
| Project activation doc | Customer research reveals the specific friction users have normalized |

## 10. Starter Template

To set up customer research in a new project:

```bash
# From the project root
cp -r ~/code/homebase/templates/Customers .
# Rename Customers/<persona>/ to match your actual persona slug
# Fill in PROFILE.md, THINKING_PATTERNS.md, apps.md
# Leave research/ empty until your first session
```

Templates include section headers, examples in brackets, and explicit `[research gap]` / `[hypothesis — needs validation]` markers to make provenance visible.
