# ADO Utils

PowerShell utilities for auditing and migrating selected Azure DevOps data. The repository favors explicit inputs, additive operations, resumable state, per-run JSONL logs, and offline verification; it is not a complete Azure DevOps project-cloning product.

## Repository workflows and exclusions

Each top-level script now lives in its own folder with a dedicated README:

| Script | Capability | Important exclusions |
| --- | --- | --- |
| [ado-project-setup](ado-project-setup/README.md) | PC-friendly launcher for selecting and running the project setup migration sequence through a local WPF UI and `ado-migrate://` protocol entry point. Optional Step 0 can migrate the process template and, in "Full automation" mode, create the target project itself. | Does not migrate permissions, store PATs, or determine the final Production hosting location for HTML/scripts. Creates the target project only when Step 0's "Full automation" mode is selected; otherwise the target project must already exist. |
| [ado-copy-test-management](ado-copy-test-management/README.md) | Copies Test Plans, suite trees, Test Case work items, rich-text fields, and suite membership to another project. Falls back to Work Item Tracking source discovery when the source identity can read work items but the Test Plan service rejects source discovery because of licensing or service-specific project visibility. | Does not migrate history, attachments, test runs/results, shared-step artifacts, identity mapping, permissions, reusable shared-step artifacts, or cross-organization configuration IDs. Dynamic/requirement suites are copied as static suites unless opted out. WIT fallback fidelity depends on source test work-item links. |
| [ado-copy-query-workitems](ado-copy-query-workitems/README.md) | Copies one saved query, its returned work items, supported fields, and query relationships to another project. | Does not clone every field, attachment, history entry, identity, or external relation. Classification paths are rewritten to the target root unless `-PreserveClassificationPaths` is used. |
| [ado-copy-all-workitems](ado-copy-all-workitems/README.md) | Copies every work item in a source project, discovered with WIQL so no saved query and no source write access are needed. Rich-text fields are copied byte-for-byte and parent/child links are recreated in a second pass. | Does not copy history, revisions, attachments, comments, permissions, or links other than parent/child. Identity fields are skipped unless `-CopyIdentityFields` is used. |
| [ado-delete-query-test-scripts](ado-delete-query-test-scripts/README.md) | Builds a review manifest for test artifacts returned by one saved query and, only with `-Apply` plus exact confirmation, deletes reviewed Test Management artifacts. | Does not delete arbitrary Work Item Tracking records. Relationship queries and title-based resolution are opt-in. |
| [ado-extract-discussions](ado-extract-discussions/README.md) | Executes one saved query and exports its selected fields plus paged comments to CSV. | Does not export revisions, attachments, relations, or restore data. |
| [ado-migrate-query](ado-migrate-query/README.md) | Copies a configurable query-ID set, rewrites project references, and records completed target IDs. | Does not overwrite differing target WIQL or migrate query permissions/favorites. Its checked-in defaults are environment-specific and must be reviewed. |

Other folder workflows:

- [Dashboard migration](ado-dashboard-migration/README.md)
- [Process field extraction](ado-field-extraction/README.md)
- [Area Path import and migration](ado-import-area-paths/README.md)
- [Default area configuration](ado-set-default-area/README.md)
- [Iteration Path import and migration](ado-import-iterations/README.md)
- [Wiki extraction, load, and direct migration](ado-migrate-wiki/README.md)
- [Inherited-process migration](ado-migrate-process/README.md)
- [Inherited-process work item type migration](ado-migrate-workitemtype/README.md)

`AdoUtils.Common.psm1` is the shared runtime contract; `tests/run-offline-checks.ps1` is an offline verifier, not an Azure DevOps entry script. Generated output folders, CSVs, logs, ZIP files, and the separate `New folder` web application are not migration entry scripts.

Repository root is intentionally kept lean: shared module plus this index README, with all script entry points organized under their own folders.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Network access to the intended Azure DevOps organizations for live runs.
- Project/process permissions matching the operation.
- PATs with the minimum scopes listed below; Azure DevOps permissions can still restrict an otherwise scoped PAT.
- Review input files, target projects, and script defaults before any write or delete operation.

## Authentication and minimum PAT scopes

PAT resolution is consistent unless a folder README states an exception: a supplied `SecureString` parameter wins, otherwise the role-specific environment variable is read, otherwise a hidden prompt is used. The variables are `ADO_PAT`, `ADO_SOURCE_PAT`, and `ADO_TARGET_PAT`. `ado-extract-discussions/ado-extract-discussions.ps1` prompts for a fresh PAT when `-Pat` is omitted and does not read `ADO_PAT`. `ado-delete-query-test-scripts/ado-delete-query-test-scripts.ps1 -PromptForPat` intentionally ignores `-Pat` and the normal parameter path and forces the hidden prompt. `-NonInteractive` turns every missing interactive input into an error.

The exact shared prompts are:

```text
Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)
Source Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)
Target Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)
Azure DevOps PAT (input hidden)
Source Azure DevOps PAT (input hidden)
Target Azure DevOps PAT (input hidden)
```

Root URL inputs use the literal prompts `Source URL`, `Source Query URL`, `Target URL`, `Target Project URL`, and `Enter the Azure DevOps Project URL (e.g. https://dev.azure.com/contoso/ProjectName)` as applicable. `AdoUtils.Common.psm1` owns the shared project URL parsing contract for scripts that accept full project URLs. PATs are converted to authorization headers in memory, registered for log redaction, and neither cached nor written back to environment variables. Do not put PATs in plain-text command arguments.

| Workflow | Source/read PAT | Target/write PAT |
| --- | --- | --- |
| Copy Test Management artifacts | Test Management: Read; Work Items: Read | Test Management: Read & write; Work Items: Read & write |
| Copy query and work items | Work Items: Read | Work Items: Read & write |
| Test-artifact cleanup | Work Items: Read; Test Management: Read | Test Management: Read & write |
| Discussion export | Work Items: Read | None |
| Query migration | Work Items: Read | Work Items: Read & write |
| Dashboard migration | Work Items: Read; Team dashboards: Read | Work Items: Read & write; Team dashboards: Manage |
| Field extraction | Process: Read; Work Items: Read | None |
| Area/Iteration migration | Work Items: Read | Work Items: Read & write |
| Wiki migration | Project/team metadata and Code/Wiki: Read | Project/team metadata and Code/Wiki: Read & write |
| Process migration | Process and Work Items: Read | Process and Work Items: Read & write |
| Work item type migration | Process and Work Items: Read | Process and Work Items: Read & write |
| Project setup launcher | Work Items, Process (Step 0), Team dashboards, Code/Wiki, Test Management (Step 8), Project/team metadata: Read | Work Items, Process (Step 0), Code/Wiki, Test Management (Step 8): Read & write; Team dashboards: Manage; Team Settings: update permission |

## Safety and rerun behavior

No script performs an implicit delete. The only delete workflow requires `ado-delete-query-test-scripts/ado-delete-query-test-scripts.ps1 -Apply`, an explicit reviewed manifest, a current result-set match, and an exact confirmation phrase; Test Plan/Suite deletion can cascade inside Azure DevOps.

Most migration workflows create missing objects and reuse or skip matches. That does not make every rerun consequence-free: some workflows patch matching objects, the wiki tools update non-identical pages, query/work-item copy updates IDs recorded in its state file, and process migration applies best-effort patches. Conflicting target content is either refused, skipped, or reported according to the folder README. Keep state and manifests with the run they belong to.

`-WhatIf` is honored only by scripts using `SupportsShouldProcess`; iteration workbook import also requires `-Apply`, and dashboard classification repair uses `-WhatIfOnly`. Wiki `-NoExecute` loads functions for testing and is not a remote migration preview. Preview paths do not claim post-write verification when no writes occurred.

## Quick start

Use explicit non-secret inputs and a `SecureString` PAT. This example performs the read-only discussion export:

```powershell
$pat = Read-Host 'Azure DevOps PAT (input hidden)' -AsSecureString
./ado-extract-discussions/ado-extract-discussions.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Project' `
  -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -Pat $pat `
  -LogDirectory './run-logs' `
  -NonInteractive
```

Examples for the other script folders:

```powershell
./ado-copy-query-workitems/ado-copy-query-workitems.ps1 `
  -SourceQueryUrl 'https://dev.azure.com/source/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -TargetProjectUrl 'https://dev.azure.com/target/Project' `
  -SourcePat $sourcePat -TargetPat $targetPat -NonInteractive

./ado-copy-test-management/ado-copy-test-management.ps1 `
  -SourceProjectUrl 'https://dev.azure.com/source/Source%20Project' `
  -TargetProjectUrl 'https://dev.azure.com/target/Target%20Project' `
  -SourcePlanIds @(123) `
  -SourcePat $sourcePat -TargetPat $targetPat -NonInteractive

# Manifest/review pass only; no deletion.
./ado-delete-query-test-scripts/ado-delete-query-test-scripts.ps1 `
  -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -Pat $pat -ManifestPath './review.csv' -NonInteractive

./ado-migrate-query/ado-migrate-query.ps1 `
  -SourceOrg 'source' -SourceProject 'Source Project' `
  -TargetOrg 'target' -TargetProject 'Target Project' `
  -QueryIds @('00000000-0000-0000-0000-000000000000') `
  -SourcePat $sourcePat -TargetPat $targetPat -NonInteractive
```

For a broader project migration, use this order: process/WIT foundation, Area and Iteration Paths, dashboard export/query/import, then wiki content. Run dashboard step 4 only as the documented path-repair branch.

## Parameters and precedence

All 19 entry scripts expose `-LogDirectory` and `-NonInteractive`; all PAT parameters are `SecureString`. Common values use parameter -> environment -> prompt precedence for PATs and parameter -> prompt for required non-secret values.

Script-folder-specific parameters:

| Script | Parameters |
| --- | --- |
| `ado-copy-test-management/ado-copy-test-management.ps1` | `SourceProjectUrl`, `TargetProjectUrl`, `SourceOrg`, `SourceProject`, `TargetOrg`, `TargetProject`, `SourcePlanIds`, `SourcePat`, `TargetPat`, `StatePath` (default `ado-copy-test-management.state.json`), `LogPath`, `AdditionalFieldReferenceNames`, `PreserveClassificationPaths`, `SkipNotifications`, `DoNotConvertDynamicSuitesToStatic`, `CopyStandaloneTestCasesWhenSuitesUnavailable`, `WhatIf`, common logging switches. |
| `ado-copy-query-workitems/ado-copy-query-workitems.ps1` | `SourceQueryUrl`, `TargetProjectUrl`, `QueryFolder` (default `Shared Queries`), `SourcePat`, `TargetPat`, `StatePath` (default `ado-copy-query-workitems.state.json`), `LogPath`, `PreserveClassificationPaths`, common logging switches. |
| `ado-delete-query-test-scripts/ado-delete-query-test-scripts.ps1` | `QueryUrl`, `Pat`, `PromptForPat`, `DeleteWorkItemTypes`, `RequiredWorkItemType`, `ManifestPath`, `LogPath`, `ForceOverwriteManifest`, `AllowTitleResolution`, `AllowRelationshipResults`, `Apply`, `ConfirmationText`, `SkipNotifications`, common logging switches. |
| `ado-extract-discussions/ado-extract-discussions.ps1` | `ProjectUrl`, `QueryUrl`, `Pat`, common logging switches. Output CSV is query-specific and timestamped beside the script. |
| `ado-migrate-query/ado-migrate-query.ps1` | `SourceOrg`, `SourceProject`, `TargetOrg`, `TargetProject`, `QueryIds`, `TargetRootFolder`, `OutputDirectory`, `SourcePat`, `TargetPat`, common logging switches. |
| `ado-migrate-process/ado-migrate-process.ps1` | `SourceOrganization`, `SourceProcess`, `SourcePat`, `TargetOrganization`, `TargetProcess`, `TargetPat`, `TargetProject`, `ProcessMode` (`FullAuto`, `AssistedManual` default, or `ExportOnly`), common logging switches. |
| `ado-migrate-wiki/ado-migrate-wiki.ps1` | `SourceOrganization`, `SourceProject`, `SourceWikiName`, `TargetOrganization`, `TargetProject`, `TargetWikiName`, `ApiBaseUri`, `AllowMissingAttachments`, `StrictAttachmentValidation`, `SkipPageOrder`, `NoExecute`, `SourcePat`, `TargetPat`, common logging switches. |
| `ado-project-setup/ado-project-setup-runner.ps1` | `SourceProjectUrl`, `TargetProjectUrl`, `Steps` (default: all except process migration), `ProcessName`, `ProcessMode`, `DefaultAreaPath`, `SourceWikiName`, `TargetWikiName`, `RunRoot`, `ProgressPath`, `SourcePat`, `TargetPat`, `NonInteractive`. Wraps other entry scripts in-process rather than exposing `LogPath`/`StatePath` directly; see its own README for run-root and state-file layout. |

`LogPath` parameters control legacy human-readable script logs where present; they do not replace the shared JSONL logs controlled by `LogDirectory`.

## Input formats

- Query URLs must have `https://dev.azure.com/{org}/{project}/_queries/query/{guid}/`; the cleanup script additionally requires the `dev.azure.com` host and a GUID.
- Project URLs must identify `https://dev.azure.com/{org}/{project}`.
- Test Management copy can migrate every source plan or only the numeric `SourcePlanIds` supplied. `SourceProjectUrl` and `TargetProjectUrl` are preferred; split organization/project parameters are retained for non-interactive callers that already have those values.
- `QueryIds` is a PowerShell string array of GUIDs.
- Cleanup manifests are CSV files generated by the discovery pass; do not hand-substitute a stale manifest for a different query result.
- Script-folder entry points otherwise obtain data directly through Azure DevOps REST responses. Folder-specific CSV, XLSX, JSON, and Markdown schemas are documented in their READMEs.

## Outputs and logs

Every entry run immediately creates two unique UTF-8-without-BOM JSON Lines files under `-LogDirectory`, or under a `logs` directory beside the entry script when omitted:

```text
<script-base>-success log-<UTC timestamp>-<8 hex>.jsonl
<script-base>-error log-<UTC timestamp>-<8 hex>.jsonl
```

Non-error records go to the success log; error records go to the error log. Each line is one JSON object with `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`. Both files exist even when one remains empty. Registered PATs, authorization values, and common secret query parameters are redacted.

Entry-point auxiliary outputs are:

- Query/work-item copy: state JSON, optional text log, a `*.failures.json` summary, and console summary JSON.
- Test Management copy: state JSON, optional text log, and console summary JSON. The state maps source plan IDs, suite IDs, Test Case work item IDs, and suite-case memberships to target artifacts for reruns.
- Cleanup: review manifest CSV, optional `*.unresolved.csv`, `*.delete-results.csv`, and a human-readable log.
- Discussion export: a uniquely timestamped `AdoWorkItemDiscussions-<queryId>-<timestamp>.csv` beside the script per run, appended one completed work item at a time within that run.
- Query migration: `migration-state.json`, `source-queries.json`, `field-schema.json`, plus legacy `success.log` and `error.log` in `-OutputDirectory`.

## Detailed workflow and behavior

`ado-copy-test-management/ado-copy-test-management.ps1` reads selected or all source Test Plans, creates target plans, recreates suite hierarchy, creates Test Case work items, patches rich-text fields without HTML conversion, and links mapped cases into mapped suites. The default copied rich-text fields are `System.Description` and `Microsoft.VSTS.TCM.Steps`; `AdditionalFieldReferenceNames` can include custom rich-text fields. State is saved after every successful artifact creation. If the source Test Plan REST API returns the Azure DevOps `TF400409` web-execution license error, or a Test Plan service `TF200016`/project-visibility error after the Core project lookup has resolved the project, the script falls back to Work Item Tracking discovery for Test Plan/Test Suite/Test Case work items and reconstructs a best-effort graph from their work-item links. If no suite-case membership is visible through available APIs, `-CopyStandaloneTestCasesWhenSuitesUnavailable` copies visible source Test Case work items as standalone target Test Cases without suite links. If source point configuration IDs cannot be applied to the target suite, the script retries suite membership using target defaults and logs a warning.

`ado-copy-query-workitems/ado-copy-query-workitems.ps1` validates both URLs, reads the saved query/WIQL, creates or reuses the target query path, executes the source query, copies supported work-item fields, saves each source→target ID immediately, then recreates supported query relations. An identical target query is skipped; a differing query may be patched by this workflow. A recorded target work item is reused and updated. Individual item/relation failures are summarized and cause a final terminating partial-failure error.

`ado-delete-query-test-scripts/ado-delete-query-test-scripts.ps1` resolves the saved query, rejects ambiguous result shapes unless explicitly allowed, maps only permitted test types to Test Management identifiers, and writes a review manifest. Apply mode refuses an implicit or changed manifest, requires the exact displayed confirmation, records prior successful deletes, and targets only reviewed Test Management API objects. Partial failures are logged and fail the run.

`ado-extract-discussions/ado-extract-discussions.ps1` pages work-item IDs below the WIQL result limit, pages each comments collection, and appends one CSV row per completed ID within that run's uniquely timestamped output file. It always starts a fresh CSV; it does not read or skip IDs from a prior run's file.

`ado-migrate-query/ado-migrate-query.ps1` reads each configured query, optionally uses checked-in fallback WIQL for three known default IDs, rewrites source-project literals and unsupported custom Boolean predicates, creates missing folders/query, freshly reads a created query, and records its target ID. A state hit is verified by target ID. An existing identical query is recorded and skipped; differing WIQL is never overwritten.

## Verification checklist

Before a live run:

- Confirm source/target organizations, projects, IDs, input files, PAT scopes, and output locations.
- Run `pwsh -NoProfile -File ./tests/run-offline-checks.ps1` and, on Windows, `powershell.exe -NoProfile -File ./tests/run-offline-checks.ps1`.
- Start with manifest, preview, `-WhatIf`, or `-WhatIfOnly` where the selected script actually supports it.

After a live run:

- Read the final outcome and both JSONL logs; empty error log plus a success message is necessary but not universal proof of semantic equivalence.
- Review auxiliary failure/skip files and manually inspect representative target data.
- Treat code read-back checks as scoped checks only: they verify selected paths/content/WIQL, not permissions, history, dashboards rendering, every field, or external references.

The repository's offline checks use mocks/static assertions and make no live Azure DevOps calls. They prove local contracts and representative branches, not live service permissions or end-to-end correctness.

## Troubleshooting

- Missing input under `-NonInteractive`: supply the parameter or appropriate PAT environment variable.
- `401`: verify PAT organization, expiry, and scope. `403`: verify both PAT scope and the identity's project/process permission.
- Conflict/differing target: inspect the target and the relevant state/manifest; do not delete or overwrite merely to force a rerun.
- Partial query/work-item copy: retain the state file, fix the reported item/relation issue, and rerun.
- Locked discussion CSV: close the file; export retries file-sharing failures before terminating.
- Dashboard, wiki, path, and process-specific errors: use the linked folder README.

## Limitations

These utilities do not provide transactional rollback, a universal dry run, automatic permission migration, or full-fidelity project cloning. API behavior, extensions, custom processes, identities, cross-project links, and concurrent edits can require manual follow-up. Offline verification never contacts Azure DevOps, and this documentation does not claim a live validation run.

## Security

Use short-lived least-privilege PATs. Prefer `SecureString` parameters or process-scoped environment variables, clear environment variables after use, never commit credentials, and protect logs/exports/state because they can contain project names, IDs, work-item text, WIQL, and wiki content even after PAT redaction. Redaction is defense in depth, not permission to log arbitrary secrets.

## Related workflows

- Field extraction can inform process planning before WIT migration.
- WIT migration should precede queries that depend on custom types/fields.
- Area and Iteration Paths should precede queries that filter on classification paths.
- Dashboard step 1 can run early for inventory; steps 2–3 depend on target preparation.
- Wiki migration is usually last because page links can refer to final project structures.
