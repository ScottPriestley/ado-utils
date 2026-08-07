# Azure DevOps Copy All Work Items

`ado-copy-all-workitems.ps1` copies every work item in a source project into a
target project, preserving rich-text field content exactly.

## Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-copy-all-workitems.ps1` | Discovers every source work item with WIQL, creates each in the target with its supported fields, and recreates parent/child links in a second pass. | Does not copy history, revisions, attachments, comments, tags-only metadata beyond the Tags field, permissions, or links other than parent/child. Identity fields are skipped unless `-CopyIdentityFields` is supplied. |

## Relationship to ado-copy-query-workitems

`ado-copy-query-workitems` copies the items returned by one saved query. This
script is the project-scoped counterpart: it finds work items with WIQL, so it
needs no saved query and therefore **no write access to the source project**.
Nothing is created in the source.

Use the query-scoped script when copying a deliberately chosen subset. Use this
one when standing up a target project from a whole source project.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source Work Items Read; target Work Items Read & write.
- Target process, work item types, fields, Area Paths, and Iteration Paths
  prepared first. Run Area and Iteration migration before this script.

## Authentication and minimum PAT scopes

`SourcePat` resolves from SecureString parameter -> `ADO_SOURCE_PAT` -> hidden
prompt `Source Azure DevOps PAT (input hidden)`. `TargetPat` uses
`ADO_TARGET_PAT` and `Target Azure DevOps PAT (input hidden)`. `-NonInteractive`
fails for missing credentials instead of prompting. PATs are registered for log
redaction and are never written to state or environment variables.

## Formatting fidelity

Rich-text fields such as `System.Description` and
`Microsoft.VSTS.TCM.ReproSteps` are sent byte-for-byte as returned by the source
API. No HTML parsing, rewriting, or sanitising occurs, so source formatting is
preserved.

Attachments and inline images hosted in the source project are **not** copied.
An inline image whose `src` points at a source attachment URL keeps that URL and
will render only for viewers with source project access.

## Classification paths

Area and Iteration Paths are rebased from the source project root onto the
target project root: `Source\Team A\Web` becomes `Target\Team A\Web`. Supply
`-PreserveClassificationPaths` to send them unchanged instead.

If a rebased path does not exist in the target, the create fails and is retried
once with the paths reset to the project root and the state omitted. Items
created that way are counted and listed at the end of the run as reduced
fidelity, and each one is recorded in the error log.

## Identity fields

Fields whose value is an identity, such as `System.AssignedTo`, are skipped by
default and reported at the end of the run. A source identity that does not
exist in the target organization causes the create to fail outright, and most
target projects have different membership. Supply `-CopyIdentityFields` when the
same identities exist in both organizations.

## Safety and rerun behavior

Nothing is deleted. The source-to-target id map is written to `StatePath` after
every successful create, so a rerun skips what already exists rather than
duplicating it. Keep the state file with the run; do not reuse one from a
different source or target project.

There is no `-WhatIf` or remote dry run.

## Quick start

```powershell
./ado-copy-all-workitems/ado-copy-all-workitems.ps1 `
  -SourceProjectUrl 'https://dev.azure.com/source/Source%20Project' `
  -TargetProjectUrl 'https://dev.azure.com/target/Target%20Project' `
  -SourcePat $sourcePat `
  -TargetPat $targetPat `
  -LogDirectory './run-logs' `
  -NonInteractive
```

## Parameters and precedence

| Parameter | Description |
| --- | --- |
| `SourceProjectUrl`, `TargetProjectUrl` | Preferred inputs. Must identify `https://dev.azure.com/{org}/{project}`. |
| `SourceOrganization`, `SourceProject`, `TargetOrganization`, `TargetProject` | Split alternatives for callers that already hold those values. |
| `SourcePat`, `TargetPat` | `SecureString`. Parameter -> environment -> prompt. |
| `StatePath` | Defaults to `ado-copy-all-workitems.state.json` beside the script. |
| `CopyIdentityFields` | Also copy identity-valued fields. |
| `PreserveClassificationPaths` | Send Area and Iteration Paths unchanged. |
| `LogDirectory`, `NonInteractive` | Common to every entry script. |

## Outputs

- Canonical JSONL success and error logs under `-LogDirectory`.
- `StatePath` JSON mapping source work item id to target id.
- `*.failures.json` beside the state file when any item or link fails.

## Scale

WIQL caps a single result set at 20,000 ids, so discovery pages with an id
watermark and is not limited to 20,000 items. Source items are read 200 at a
time through the batch API. Expect roughly one create call per work item; a
large project takes a correspondingly long time.

## Verification checklist

After a run:

- Compare source and target work item counts.
- Open several items and confirm rich-text fields render as they do in the source.
- Confirm Area and Iteration Paths resolved rather than falling back to the root.
- Review the reduced-fidelity list printed at the end of the run.
- Read both JSONL logs and any `*.failures.json`.

A partial run throws after writing the failure summary. Fix the reported cause
and rerun; recorded items are skipped.
