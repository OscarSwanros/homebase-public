# HOMEBASE-SOP-012: GitHub Project Management

> **Status**: explanation, not control flow. The control flow lives in
> [`@~/code/homebase/standards/WORKFLOW_CONTRACT.md`](../standards/WORKFLOW_CONTRACT.md)
> and each project's `.homebase/workflow.yml`. This SOP explains the
> *why* behind specific contract clauses; do not follow it as a
> procedure — run `homebase work` instead.

Canonical procedure for managing GitHub Projects V2 fields, options, and item assignments via the API across every homebase-adopting project that uses Projects V2.

> **Status: LEGACY.** HOMEBASE-SOP-013 (Roadmap Management via Linear) supersedes this SOP for all new roadmap work. SOP-012 remains in force for any project that still operates a GitHub Projects V2 board — its constraints and recovery procedures apply unchanged as long as such a board exists. New apps and new roadmaps SHOULD adopt SOP-013 instead.

## Purpose

Prevent accidental destruction of project board data when modifying field schemas. The GitHub Projects V2 GraphQL API has destructive mutations that silently wipe item assignments when used incorrectly. This SOP documents the safe approaches and recovery procedures.

## Scope

**Applies to**: All agents that interact with GitHub Projects V2 via the GraphQL API or `gh` CLI. Opt-in — projects that don't use Projects V2 do not adopt this SOP. New roadmap work should adopt **HOMEBASE-SOP-013** instead of this SOP.

---

## BANNED MUTATION

> **`updateProjectV2Field` with `singleSelectOptions` is BANNED.**
>
> Do not call it. Do not attempt it with a rebuild plan. Do not try to work around it. There are ZERO acceptable uses of this mutation.
>
> This is a hard rule with no exceptions.

### Why It Is Banned

The `updateProjectV2Field` GraphQL mutation **replaces the entire option set** for a single-select field. It does not merge or append. The API does not accept option IDs in the input, so there is no way to preserve existing option-to-item mappings.

**What happens when you call it:**

1. You call `updateProjectV2Field` with a `singleSelectOptions` array that includes the new option plus all existing option names.
2. GitHub creates entirely new option objects with new internal IDs.
3. Every project item that was assigned to one of the old options now points to a non-existent ID.
4. All field assignments across every item on the board silently become unset.
5. There is no undo, no warning, and no error message.
6. Non-label-backed field assignments (typically Phase, Sprint, custom) cannot be recovered. Label-backed fields (typically Release, Priority) can only be partially recovered from labels.

**This applies to ALL single-select fields**: Status, Phase, Release, Sprint, and any custom single-select fields.

### Incident History

This ban exists because this exact mistake has happened **twice on the same project's boards**, both times causing significant data loss and manual recovery work:

**Incident 1 (2026-03, Field Suite → GasCalc Roadmap):** An agent used `updateProjectV2Field` to add a single-select option to the "Release" field on the GasCalc Roadmap project board. All existing release assignments across every item were destroyed. The project's local SOP for this rule was created in response.

**Incident 2 (2026-03-14, Field Suite → LogApp Roadmap):** Despite the project SOP existing, an agent used `updateProjectV2Field` twice — once on the Phase field and once on the Release field — to add Android options to the LogApp Roadmap project board. All iOS release AND phase assignments were destroyed. Release assignments were partially recovered from labels. Phase assignments for iOS issues were permanently lost.

The pattern generalises to every Projects V2 board in every project: the failure mode is structural to the API, not specific to any product. The rules below are therefore universal.

### What To Do Instead

**To add a new option to a single-select field:** Tell the user to add it via the GitHub web UI. Navigate to project settings, find the field, click the option menu, and add the option. The web UI preserves existing option IDs and all assignments.

**To set a field value on an issue:** Use the project's local `scripts/set-project-fields.sh` wrapper (if the project provides one) or call `updateProjectV2ItemFieldValue` directly (the safe, per-item mutation).

---

## Safe Operations

These API operations do NOT destroy assignments and are safe to use:

| Mutation | Effect |
|---|---|
| `updateProjectV2ItemFieldValue` | Sets one field value on one item. **This is what you should use.** |
| `addProjectV2ItemById` | Adds an issue/PR to a project. |
| `deleteProjectV2Item` | Removes an item from a project. |
| `updateProjectV2` | Updates project title/description/visibility. |

### Using `scripts/set-project-fields.sh`

If the project provides a `scripts/set-project-fields.sh` wrapper (optional but recommended for projects with multiple boards), use it as the canonical interface for setting Release, Phase, and other single-select fields. The wrapper:

- Reads field IDs from `<project>/.homebase/project-fields.yml`.
- Uses `updateProjectV2ItemFieldValue` internally (the safe mutation).
- Hardcodes current option IDs. If option IDs change after an incident, the script must be updated.

Example invocation pattern:

```bash
scripts/set-project-fields.sh --project <board> --issue <N> --release <value> --phase <value>
```

Project-specific usage, argument conventions, and field/board inventory live in the project's own docs.

---

## Destructive Operations — NEVER Use

| Mutation | Effect | Allowed? |
|---|---|---|
| `updateProjectV2Field` (with `singleSelectOptions`) | Replaces ALL options, wipes ALL assignments | **NEVER** |
| `deleteProjectV2Field` | Removes the field entirely | **NEVER** |

---

## Recovery Procedure

If a field mutation has destroyed item assignments, use this procedure to rebuild them.

### Prerequisites

You need a source of truth for what the assignments should be. Common sources:

- **Issue labels** (e.g., an `<app>-v1.0` label maps to Release = "v1.0"). This is the primary recovery mechanism.
- **Milestone assignments.**
- **A pre-mutation backup** (if you dumped items before the change).

**Note**: fields that have no label-backed source of truth (commonly Phase, Sprint, custom) CANNOT be recovered unless a backup was taken.

### Step-by-Step Recovery

#### Step 1: Get the Current Field Option IDs

After a wipe, all options have new IDs. You need the current IDs:

```bash
gh project field-list <PROJECT_NUMBER> --owner <OWNER> --format json | \
  jq '.fields[] | select(.name == "<FIELD_NAME>") | .options'
```

#### Step 2: Build a Mapping from Labels

```bash
# Find all issues with a specific release label
gh issue list --label "<app>-v1.0" --state all --limit 200 --json number --jq '.[].number'
```

#### Step 3: Get Project Item IDs

```bash
gh project item-list <PROJECT_NUMBER> --owner <OWNER> --limit 300 --format json > /tmp/items.json
```

Cross-reference issue numbers against the item dump to get project item IDs.

#### Step 4: Batch-Update Items

For each item, use the SAFE mutation:

```bash
gh api graphql -f query='
  mutation {
    updateProjectV2ItemFieldValue(input: {
      projectId: "<PROJECT_ID>"
      itemId: "<ITEM_ID>"
      fieldId: "<FIELD_ID>"
      value: { singleSelectOptionId: "<OPTION_ID>" }
    }) {
      projectV2Item { id }
    }
  }
'
```

#### Step 5: Update `scripts/set-project-fields.sh`

After recovery, update the hardcoded option IDs in the project's wrapper script so future field assignments use the correct IDs.

#### Step 6: Verify

```bash
gh project item-list <PROJECT_NUMBER> --owner <OWNER> --limit 300 --format json | \
  jq '.items[] | select(.release == null or .release == "") | .title'
```

---

## Related

- `HOMEBASE-SOP-002-GITHUB_API_USAGE.md` — TPM gatekeeper; all `gh` invocations route through TPM. This SOP concerns what TPM (or any agent with direct API access) must and must not do once authorised.
- Project-specific docs — projects commonly keep the `project-fields.yml` schema and a project-board inventory in their own `Documentation/` directory.
