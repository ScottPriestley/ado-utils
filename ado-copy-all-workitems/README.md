# Azure DevOps Copy All Work Items

`ado-copy-all-workitems.ps1` copies every work item in a source project into a
target project, preserving rich-text field content exactly.

## Using the tool

**What it does:** Finds every work item in a source project and re-creates each one in a target project, keeping rich-text fields (like descriptions and repro steps) exactly as they appear in the source. Once every item is created, it makes a second pass to reconnect parent/child relationships between the copied items.

**When to use it:** You're standing up a target project from an entire source project — not just a subset. If you only want a deliberately chosen set of items (say, the results of one saved query), use `ado-copy-query-workitems` instead — this script is the whole-project counterpart to that one, and needs no write access to the source project at all (nothing is ever created in the source).

**What it will NOT do:** It does not copy work item history/revisions, attachments, comments, or any relationship other than parent/child (other link types are not recreated). Fields whose value is a person (like "Assigned To") are skipped by default, because the same person may not exist in the target organization — you can turn this on with a switch if the same people exist in both places. Kanban board fields tied to the source project's boards are dropped since they wouldn't mean anything in the target. Nothing is ever deleted, and there's no rollback.

**Before you start, have ready:**
- The source project URL and the target project URL.
- A PAT for the source org with **Work Items (Read)** access.
- A PAT for the target org with **Work Items (Read & write)** access.
- The target project's process, work item types, fields, Area Paths, and Iteration Paths already set up — and specifically, run the Area Path and Iteration Path migration tools in this repo first if you haven't already.

**How to run it:**

1. Open PowerShell in the repo folder.
2. Run the script, pointing it at the source and target project URLs:

```powershell
./ado-copy-all-workitems/ado-copy-all-workitems.ps1 `
  -SourceProjectUrl 'https://dev.azure.com/source/Source%20Project' `
  -TargetProjectUrl 'https://dev.azure.com/target/Target%20Project' `
  -LogDirectory './run-logs'
```

3. You'll be prompted for your source and target PATs if you didn't supply them.
4. This can take a while for a large project — expect roughly one API call per work item.
5. If a run gets interrupted or partly fails, rerun the same command. It keeps track of what's already been copied and skips it rather than duplicating it.

**What to expect afterward:**
- A summary at the end of the run, including a callout of anything copied with reduced fidelity (for example, an item that had to be created without its original status because the target process doesn't allow it).
- A small state file mapping source item IDs to target item IDs — keep this with the run, and don't reuse it for a different source/target pairing.
- A log folder with a success log and an error log.
- If any items or links failed outright, a separate failures file listing exactly what didn't come across, so you know what to check or fix before rerunning.
- If the source project uses a work item type the target doesn't have, the run will call that out by name at the end rather than failing silently — you'd set that type up in the target and rerun to pick up the items that were skipped.

There's no preview/dry-run mode — running it does the copy.

## Technical reference

### Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-copy-all-workitems.ps1` | Discovers every source work item with WIQL, creates each in the target with its supported fields, and recreates parent/child links in a second pass. | Does not copy history, revisions, attachments, comments, tags-only metadata beyond the Tags field, permissions, or links other than parent/child. Identity fields are skipped unless `-CopyIdentityFields` is supplied. |

### Relationship to ado-copy-query-workitems

`ado-copy-query-workitems` copies the items returned by one saved query. This
script is the project-scoped counterpart: it finds work items with WIQL, so it
needs no saved query and therefore **no write access to the source project**.
Nothing is created in the source.

Use the query-scoped script when copying a deliberately chosen subset. Use this
one when standing up a target project from a whole source project.

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source Work Items Read; target Work Items Read & write.
- Target process, work item types, fields, Area Paths, and Iteration Paths
  prepared first. Run Area and Iteration migration before this script.

### Authentication and minimum PAT scopes

`SourcePat` resolves from SecureString parameter -> `ADO_SOURCE_PAT` -> hidden
prompt `Source Azure DevOps PAT (input hidden)`. `TargetPat` uses
`ADO_TARGET_PAT` and `Target Azure DevOps PAT (input hidden)`. `-NonInteractive`
fails for missing credentials instead of prompting. PATs are registered for log
redaction and are never written to state or environment variables.

### Formatting fidelity

Rich-text fields such as `System.Description` and
`Microsoft.VSTS.TCM.ReproSteps` are sent byte-for-byte as returned by the source
API. No HTML parsing, rewriting, or sanitising occurs, so source formatting is
preserved.

Attachments and inline images hosted in the source project are **not** copied.
An inline image whose `src` points at a source attachment URL keeps that URL and
will render only for viewers with source project access.

### Classification paths

Area and Iteration Paths are rebased from the source project root onto the
target project root: `Source\Team A\Web` becomes `Target\Team A\Web`. Supply
`-PreserveClassificationPaths` to send them unchanged instead.

### Targeted retry on create failure

If a work item create fails for a reason other than a missing work item type
(see below), the script inspects the error text before giving up rather than
discarding classification paths and state on every failure:

- If the message matches a `State`/`Reason` field error (`field 'State'`,
  `field 'Reason'`, `not in the list of supported values`, `TF237124`), the
  first retry resends every field except `System.State` and `System.Reason`.
- If the message matches a classification-path error (`TF51011`, `Area Path`,
  `Iteration Path`, `classification`), the first retry resends every field
  with `System.AreaPath` and `System.IterationPath` reset to the target
  project root, overriding `-PreserveClassificationPaths` for that item only.
- If the message matches neither pattern, both reductions are applied
  together on the first retry, since the cause is unclear.

If the targeted retry still fails, one further attempt drops state and
resets classification together. Items created on either retry are counted
and listed at the end of the run as reduced fidelity ("created without
original state" / "area/iteration path" / both), and each one is recorded in
the error log along with the original failure reason. A work item that fails
every attempt is recorded in `*.failures.json` and puts the run in a
partial-failure outcome.

### Parent/child link recreation (second pass)

Items are created first, in id order, before any link is recreated, because a
parent may not exist yet when its child is created. After all creates in a
run, the script walks each source item's captured relations and, for every
`System.LinkTypes.Hierarchy-Reverse` (child-to-parent) relation where both
the child and its parent were themselves copied, adds the equivalent link
between the two target items.

- A link Azure DevOps reports as already existing (`already exists`,
  `VS402313`, `RelationAlreadyExists`) is counted as already present, not a
  failure. This makes rerunning a completed migration report its links as
  unchanged rather than as new failures.
- A link PATCH that fails with `TF51541` ("The Area/Iteration ID is not
  recognized") means the child item's own stored Area/Iteration Path no
  longer resolves to a live classification node. The script retries the same
  link once, in the same PATCH, adding the child's Area and Iteration Path
  again by name (rebased unless `-PreserveClassificationPaths` was used) to
  force Azure DevOps to re-resolve the id. If that retry also fails, the
  link is recorded as failed.
- Any other link failure is recorded in the error log and in
  `*.failures.json` under `linkFailures`, and puts the run in a
  partial-failure outcome.

The run prints how many links were recreated and, separately, how many were
already present.

### Work item types missing from the target

A work item type the target process does not define cannot be created. The first
item of such a type produces a 404, after which every remaining item of that type
is skipped without another API call rather than collecting hundreds of identical
failures.

The run ends by naming the missing types and the number of items affected, and
exits with a partial-failure result. Migrate the target process first (see
[ado-migrate-workitemtype](../ado-migrate-workitemtype/README.md)) and rerun to
pick those items up; recorded items are skipped on the rerun.

### Board fields

Fields named `WEF_<guid>_*` are per-board artefacts Azure DevOps generates for
Kanban state, such as `System.ExtensionMarker`, `Kanban.Column`, and
`Kanban.Lane`. The GUID identifies a board in the **source** project, so the
target has no matching field and rejects the whole work item with `TF51535`.
They carry no content worth migrating and are excluded.

### Identity fields

Fields whose value is an identity, such as `System.AssignedTo`, are skipped by
default and reported at the end of the run. A source identity that does not
exist in the target organization causes the create to fail outright, and most
target projects have different membership. Supply `-CopyIdentityFields` when the
same identities exist in both organizations.

### Safety and rerun behavior

Nothing is deleted. The source-to-target id map is written to `StatePath` after
every successful create, so a rerun skips what already exists rather than
duplicating it. Keep the state file with the run; do not reuse one from a
different source or target project.

There is no `-WhatIf` or remote dry run.

### Quick start

```powershell
./ado-copy-all-workitems/ado-copy-all-workitems.ps1 `
  -SourceProjectUrl 'https://dev.azure.com/source/Source%20Project' `
  -TargetProjectUrl 'https://dev.azure.com/target/Target%20Project' `
  -SourcePat $sourcePat `
  -TargetPat $targetPat `
  -LogDirectory './run-logs' `
  -NonInteractive
```

### Parameters and precedence

| Parameter | Description |
| --- | --- |
| `SourceProjectUrl`, `TargetProjectUrl` | Preferred inputs. Must identify `https://dev.azure.com/{org}/{project}`. |
| `SourceOrganization`, `SourceProject`, `TargetOrganization`, `TargetProject` | Split alternatives for callers that already hold those values. |
| `SourcePat`, `TargetPat` | `SecureString`. Parameter -> environment -> prompt. |
| `StatePath` | Defaults to `ado-copy-all-workitems.state.json` beside the script. |
| `CopyIdentityFields` | Also copy identity-valued fields. |
| `PreserveClassificationPaths` | Send Area and Iteration Paths unchanged. |
| `LogDirectory`, `NonInteractive` | Common to every entry script. |

### Outputs

- Canonical JSONL success and error logs under `-LogDirectory`.
- `StatePath` JSON mapping source work item id to target id.
- `*.failures.json` (same base name as `StatePath` with a `.failures.json`
  extension) when any item or link fails, containing a single object with
  `workItemFailures` (each `{ SourceId, Type, Error }`) and `linkFailures`
  (each `{ ChildSourceId, ParentSourceId, Error }`). The file is written even
  when one of the two arrays is empty.

### Scale

WIQL caps a single result set at 20,000 ids, so discovery pages with an id
watermark and is not limited to 20,000 items. Source items are read 200 at a
time through the batch API. Expect roughly one create call per work item; a
large project takes a correspondingly long time.

### Verification checklist

After a run:

- Compare source and target work item counts.
- Open several items and confirm rich-text fields render as they do in the source.
- Confirm Area and Iteration Paths resolved rather than falling back to the root.
- Review the reduced-fidelity list printed at the end of the run.
- Read both JSONL logs and any `*.failures.json`.

A partial run throws after writing the failure summary. Fix the reported cause
and rerun; recorded items are skipped.
