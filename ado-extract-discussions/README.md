# Azure DevOps Discussion Export

`ado-extract-discussions.ps1` exports Azure DevOps work item IDs, titles, descriptions, and paged comments for one project to CSV. It is read-only against Azure DevOps and appends completed rows so interrupted exports can resume.

## Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-extract-discussions.ps1` | Reads project work item IDs, pages each work item's comments, and appends one CSV row per completed work item. | Does not export revisions, attachments, relations, history, identity mappings, or restore/import data. |

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source project read access.
- Work Items Read PAT scope.
- Disk access to write `AdoWorkItemDiscussions.csv` beside the script.

## Authentication and minimum PAT scopes

`Pat` resolves from SecureString parameter -> `ADO_PAT` -> hidden prompt `Azure DevOps PAT (input hidden)`. `-NonInteractive` rejects missing values instead of prompting. PATs are registered for redaction and not written to the CSV or logs.

Minimum scope is Work Items Read. Project permission can still block comments or work items.

## Safety and rerun behavior

The script performs GET-only Azure DevOps calls and never deletes or writes remote data. It writes `AdoWorkItemDiscussions.csv` beside the script, reads existing completed `ID` values on rerun, and skips those IDs. That resume behavior assumes an existing row is complete; it does not compare remote comments again.

There is no `-WhatIf` because the only writes are local CSV/log files. CSV file-sharing conflicts are retried and then surfaced as errors.

## Quick start

```powershell
$pat = Read-Host 'Azure DevOps PAT (input hidden)' -AsSecureString
./ado-extract-discussions/ado-extract-discussions.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Project' `
  -Pat $pat `
  -LogDirectory './run-logs' `
  -NonInteractive
```

From this folder:

```powershell
./ado-extract-discussions.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Project' `
  -Pat $pat
```

## Parameters and precedence

| Parameter | Description |
| --- | --- |
| `ProjectUrl` | Azure DevOps project URL. Prompts as `Enter the Azure DevOps Project URL (e.g. https://dev.azure.com/contoso/ProjectName)` when omitted. |
| `Pat` | Default role `SecureString` PAT. |
| `LogDirectory` | Shared JSONL directory; defaults to `logs` beside the script. |
| `NonInteractive` | Rejects missing inputs instead of prompting. |

PAT precedence is SecureString parameter -> `ADO_PAT` -> hidden prompt. `ProjectUrl` uses parameter -> prompt.

## Input formats

`ProjectUrl` must identify `https://dev.azure.com/{org}/{project}`. The script queries project work item IDs directly; there is no input query, workbook, or manifest.

## Outputs and logs

`AdoWorkItemDiscussions.csv` is written beside the script and includes one completed row per work item. Existing IDs in that CSV are skipped on rerun.

Every run creates `ado-extract-discussions-success log-<run-id>.jsonl` and `ado-extract-discussions-error log-<run-id>.jsonl` in `LogDirectory` or local `logs`, UTF-8 without BOM. Records include `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; secrets are redacted.

## Detailed workflow and behavior

The script parses the project URL, resolves the PAT, gathers work item IDs below the WIQL result limit, batches work item reads for titles/descriptions, pages comments for each work item, and appends the CSV row only after that work item is complete. It logs progress and final outcome through the shared logger.

## Verification checklist

- Run `pwsh -NoProfile -File ./tests/run-offline-checks.ps1`.
- Confirm project URL and Work Items Read scope.
- Close any application holding the CSV before running.
- Review both JSONL logs and the CSV row count.
- Spot-check representative work item comments against Azure DevOps.

Offline checks make no live calls and cannot prove comments visible to one PAT are complete for another identity.

## Troubleshooting

- CSV locked: close Excel or other viewers and rerun.
- Missing comments: verify the PAT identity can see the work item and discussion.
- `401`/`403`: verify PAT organization, expiry, scope, and project permission.
- Resume skipped an ID that changed remotely: remove or archive the CSV and rerun a fresh export.

## Limitations

No revision/comment history beyond current comments API output, no attachments, no relation export, no import/restore path, and no remote dry run. Resume logic is row-based, not content-diff based.

## Security

Use a short-lived read-only PAT. Protect the CSV and logs because descriptions and comments can contain sensitive project content. Do not commit exports or PATs.

## Related workflows

Use before migrations when discussion content needs offline review. Other copy/migration tools in this repository do not migrate comments; see the [root README](../README.md) for workflow boundaries.
