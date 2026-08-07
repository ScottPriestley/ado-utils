# Azure DevOps Discussion Export

`ado-extract-discussions.ps1` executes one saved Azure DevOps query, exports the query-selected work item fields, and includes paged discussion comments for each record. It is read-only against Azure DevOps and creates a new CSV for each run.

## Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-extract-discussions.ps1` | Reads one saved query's WIQL, executes it, exports the selected query columns, pages each returned work item's comments, and writes one CSV row per completed work item. | Does not export revisions, attachments, relations, history, identity mappings, or restore/import data. |

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source project read access.
- A saved query URL for the source project.
- Work Items Read PAT scope.
- Disk access to write `AdoWorkItemDiscussions-<queryId>-<timestamp>.csv` beside the script.

## Authentication and minimum PAT scopes

`Pat` resolves from SecureString parameter -> hidden prompt `Azure DevOps PAT (input hidden)`. This script intentionally asks for a fresh PAT when `-Pat` is omitted instead of using `ADO_PAT`, so a stale environment token cannot silently drive the export. `-NonInteractive` rejects missing values instead of prompting. PATs are registered for redaction and not written to the CSV or logs.

Minimum scope is Work Items Read. Project permission can still block comments or work items.

## Safety and rerun behavior

The script performs read-only Azure DevOps calls and never deletes or writes remote data. It writes a fresh `AdoWorkItemDiscussions-<queryId>-<timestamp>.csv` beside the script on every run. It does not append to or resume from previous exports.

There is no `-WhatIf` because the only writes are local CSV/log files. CSV file-sharing conflicts are retried and then surfaced as errors.

## Quick start

```powershell
$pat = Read-Host 'Azure DevOps PAT (input hidden)' -AsSecureString
./ado-extract-discussions/ado-extract-discussions.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Project' `
  -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -Pat $pat `
  -LogDirectory './run-logs' `
  -NonInteractive
```

From this folder:

```powershell
./ado-extract-discussions.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Project' `
  -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -Pat $pat
```

## Parameters and precedence

| Parameter | Description |
| --- | --- |
| `ProjectUrl` | Azure DevOps project URL. Prompts as `Project URL` when omitted. Must match the query URL's organization and project. |
| `QueryUrl` | Saved query URL. Prompts as `Query URL` when omitted. |
| `Pat` | Default role `SecureString` PAT. |
| `LogDirectory` | Shared JSONL directory; defaults to `logs` beside the script. |
| `NonInteractive` | Rejects missing inputs instead of prompting. |

PAT precedence is SecureString parameter -> hidden prompt. `ProjectUrl` and `QueryUrl` use parameter -> prompt.

## Input formats

`ProjectUrl` must identify `https://dev.azure.com/{org}/{project}`. `QueryUrl` must identify `https://dev.azure.com/{org}/{project}/_queries/query/{queryId}/`, and the organization/project must match `ProjectUrl`.

Flat saved queries return their direct work item IDs. Tree and relationship queries return relation endpoints; the script de-duplicates source and target IDs before exporting records.

## Outputs and logs

`AdoWorkItemDiscussions-<queryId>-<timestamp>.csv` is written beside the script and includes one completed row per work item. Previous exports are left untouched.

Rows include `QueryId`, `QueryName`, the saved query's selected columns in query order, and `Discussions`. Custom fields such as `Process sequence ID` are included when the saved query selects them.

Every run creates `ado-extract-discussions-success log-<run-id>.jsonl` and `ado-extract-discussions-error log-<run-id>.jsonl` in `LogDirectory` or local `logs`, UTF-8 without BOM. Records include `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; secrets are redacted.

## Detailed workflow and behavior

The script parses the project and query URLs, resolves the PAT, reads the saved query WIQL, executes the query, de-duplicates the returned work item IDs, reads the query-selected fields for each work item, pages comments for each work item, and appends the CSV row only after that work item is complete. It logs progress and final outcome through the shared logger.

## Verification checklist

- Run `pwsh -NoProfile -File ./tests/run-offline-checks.ps1`.
- Confirm project URL, query URL, and Work Items Read scope.
- Close any application holding the CSV before running.
- Review both JSONL logs and the CSV row count.
- Spot-check representative work item comments against Azure DevOps.

Offline checks make no live calls and cannot prove comments visible to one PAT are complete for another identity.

## Troubleshooting

- CSV locked: close Excel or other viewers and rerun.
- Missing comments: verify the PAT identity can see the work item and discussion.
- Project/query mismatch: use a query URL from the same organization and project as `ProjectUrl`.
- `401`/`403`: re-enter a PAT for the query's organization, then verify expiry, Work Items Read scope, and project/query permission.
- Re-running always creates a new CSV. Archive or delete old CSVs manually when they are no longer needed.

## Limitations

No revision/comment history beyond current comments API output, no attachments, no relation export beyond using relationship-query endpoint IDs as the record set, no import/restore path, and no remote dry run.

## Security

Use a short-lived read-only PAT. Protect the CSV and logs because descriptions and comments can contain sensitive project content. Do not commit exports or PATs.

## Related workflows

Use before migrations when discussion content needs offline review. Other copy/migration tools in this repository do not migrate comments; see the [root README](../README.md) for workflow boundaries.
