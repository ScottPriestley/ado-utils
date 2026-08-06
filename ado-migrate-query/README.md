# Azure DevOps Saved Query Migration

`ado-migrate-query.ps1` copies a configured set of saved Azure DevOps queries from one project to another, rewrites project references, and records source-to-target query IDs. It is a query-definition migration helper, not a work item copy tool.

## Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-migrate-query.ps1` | Reads configured source query IDs, rewrites source-project literals and selected unsupported Boolean predicates, creates missing target folders/queries, and records target IDs. | Does not overwrite differing target WIQL, migrate query permissions/favorites, copy work items, or prepare target fields/types/classification paths. |

The checked-in default org/project/query values are environment-specific examples and must be reviewed before live use.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source Work Items Read.
- Target Work Items Read & write.
- Target process fields, states, work item types, Area Paths, and Iteration Paths already prepared for the query WIQL.

## Authentication and minimum PAT scopes

`SourcePat` resolves from SecureString parameter -> `ADO_SOURCE_PAT` -> hidden prompt `Source Azure DevOps PAT (input hidden)`. Target uses `ADO_TARGET_PAT` and `Target Azure DevOps PAT (input hidden)`. `-NonInteractive` rejects missing credentials. PATs are redacted and are not stored in output files.

Minimum scopes are Work Items Read for source and Work Items Read & write for target.

## Safety and rerun behavior

The script creates folders and queries but does not delete. It writes `migration-state.json` in `OutputDirectory` and verifies a state hit by reading the recorded target ID. Existing identical target queries are recorded and skipped. Existing differing WIQL is intentionally not overwritten.

There is no `-WhatIf` or remote dry run. Reruns are stateful but still require review of skipped/differing queries.

## Quick start

```powershell
./ado-migrate-query/ado-migrate-query.ps1 `
  -SourceOrg 'source' -SourceProject 'Source Project' `
  -TargetOrg 'target' -TargetProject 'Target Project' `
  -QueryIds @('00000000-0000-0000-0000-000000000000') `
  -SourcePat $sourcePat `
  -TargetPat $targetPat `
  -OutputDirectory './ado-query-migration-output' `
  -LogDirectory './run-logs' `
  -NonInteractive
```

From this folder:

```powershell
./ado-migrate-query.ps1 `
  -SourceOrg 'source' -SourceProject 'Source Project' `
  -TargetOrg 'target' -TargetProject 'Target Project' `
  -SourcePat $sourcePat -TargetPat $targetPat
```

## Parameters and precedence

| Parameter | Description |
| --- | --- |
| `SourceOrg`, `SourceProject` | Source organization and project. |
| `TargetOrg`, `TargetProject` | Target organization and project. |
| `QueryIds` | Source query GUID array. Defaults in the script are environment-specific. |
| `TargetRootFolder` | Target folder root; default `Shared Queries`. |
| `OutputDirectory` | Default `ado-query-migration-output` beside the script. |
| `SourcePat` / `TargetPat` | Role-specific `SecureString` PATs. |
| `LogDirectory` | Shared JSONL directory; defaults to `logs` beside the script. |
| `NonInteractive` | Rejects missing input. |

PAT precedence is SecureString parameter -> environment variable -> hidden prompt. Organization values accept bare names or Azure DevOps organization URLs.

## Input formats

`QueryIds` is a PowerShell string array of GUIDs. Organization inputs may be `contoso`, `https://dev.azure.com/contoso`, or the supported legacy organization URL form. The script reads source query definitions from Azure DevOps and stores snapshots in JSON.

## Outputs and logs

`OutputDirectory` contains:

```text
migration-state.json
source-queries.json
field-schema.json
success.log
error.log
```

The legacy `success.log` and `error.log` are human-readable per-query logs. The shared logger also creates `ado-migrate-query-success log-<run-id>.jsonl` and `ado-migrate-query-error log-<run-id>.jsonl` under `LogDirectory` or local `logs`, UTF-8 without BOM. JSONL records include `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`.

## Detailed workflow and behavior

The script resolves endpoints and PATs, creates `OutputDirectory`, loads migration state, reads target fields/schema, and processes each source query ID. It can use checked-in fallback WIQL for three known default IDs when source query lookup needs that branch. It rewrites source project names and selected unsupported custom Boolean predicates, creates missing folders, creates missing queries, reads newly created target queries back, and records the target ID.

If a target query already exists with identical WIQL, it is recorded and skipped. Differing target WIQL is refused and logged instead of overwritten.

## Verification checklist

- Run `pwsh -NoProfile -File ./tests/run-offline-checks.ps1`.
- Review `QueryIds`, org/project defaults, and target root folder before any live run.
- Confirm target fields/types/paths used by WIQL exist.
- Review `source-queries.json`, `field-schema.json`, legacy logs, JSONL logs, and `migration-state.json`.
- Open representative target queries and compare WIQL/results manually.

Offline checks make no live calls and do not prove query results are semantically equivalent.

## Troubleshooting

- Differing target WIQL: inspect and decide manually; the script will not overwrite it.
- Missing field/type/path: prepare target process/classification paths and rerun.
- State references missing target ID: remove only the affected state entry after review, then rerun.
- `401`/`403`: verify source/target PAT scope, organization, and project permissions.

## Limitations

No query permissions, favorites, work item data, dashboard widgets, rollback, delete, or dry run. WIQL rewrites are targeted, not a complete language migration.

## Security

Use least-privilege PATs. Protect output JSON and logs because they include WIQL, field names, project names, and query IDs. Never commit PATs or environment-specific state.

## Related workflows

Run after [work item type migration](../ado-migrate-workitemtype/README.md), [Area Paths](../ado-import-area-paths/README.md), and [Iteration Paths](../ado-import-iterations/README.md). For dashboard query migration, use [dashboard migration](../ado-dashboard-migration/README.md). Shared conventions are in the [root README](../README.md).
