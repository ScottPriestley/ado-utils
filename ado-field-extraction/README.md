# Azure DevOps Process Field Extraction

Two read-only PowerShell scripts list organization processes and export the fields attached to every work item type in one process.

## Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-organization-ID-listing.ps1` | Prints process name, `typeId`, and description. | Does not write a process inventory file or modify Azure DevOps. |
| `ado-process-fields.ps1` | Enumerates process WITs and exports their attached field metadata. | Does not export rules, states, layouts, picklist values, permissions, or fields not attached to a WIT. |

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Azure DevOps access to view the organization's processes.
- Source PAT with Process Read and Work Items Read.

## Authentication and minimum PAT scopes

Both scripts use `Pat` (`SecureString`) → `ADO_SOURCE_PAT` → hidden prompt. `Organization` is used when supplied; otherwise the exact prompt is `Source Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)`. The exact PAT prompt is `Source Azure DevOps PAT (input hidden)`. `ado-process-fields.ps1` also prompts `Enter the source Azure DevOps process ID` when omitted. `-NonInteractive` rejects any missing value instead of prompting. Credentials are not cached.

## Safety and rerun behavior

Azure DevOps calls are GET-only. Rerunning the list is harmless. Field export replaces the file selected by `OutputPath`; choose a new path if the prior CSV must be preserved. No live consistency snapshot is guaranteed if the process changes during enumeration.

## Quick start

```powershell
./ado-organization-ID-listing.ps1 -Organization 'contoso'
./ado-process-fields.ps1 `
  -Organization 'contoso' `
  -ProcessId '00000000-0000-0000-0000-000000000000' `
  -OutputPath './Contoso_Process_Fields.csv'
```

For unattended execution, supply `-Pat $securePat -NonInteractive` or set `ADO_SOURCE_PAT` for the process.

## Parameters and precedence

| Script | Parameters |
| --- | --- |
| Organization listing | `Organization`, `Pat`, `LogDirectory`, `NonInteractive`. |
| Field export | `Organization`, `Pat`, `ProcessId`, `OutputPath` (default `ADO_Process_Fields.csv` beside the script), `LogDirectory`, `NonInteractive`. |

Organization accepts `contoso`, `https://dev.azure.com/contoso`, or `https://contoso.visualstudio.com`. Explicit parameters precede prompts; PAT precedence is SecureString → environment → prompt.

## Input formats

`ProcessId` is the `typeId` printed by the listing script. `OutputPath` is a filesystem CSV path; its parent must exist. No input workbook or hidden template is required.

## Outputs and logs

The listing writes a formatted console table. Field export writes CSV columns `WorkItemType`, `FieldName`, `ReferenceName`, `Type`, `Required`, `ReadOnly`, and `Inherited`, sorted by `ReferenceName`, and also prints a table.

Each run creates UTF-8-without-BOM JSONL files named `<script-base>-success log-<run-id>.jsonl` and `<script-base>-error log-<run-id>.jsonl` under `LogDirectory` or the folder's `logs` directory. Records use `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; PAT/authorization values are redacted.

## Detailed workflow and behavior

The listing normalizes the organization, calls the processes endpoint, and formats the response. The exporter reads all work item types for the selected process, requests each WIT's fields, flattens one row per WIT/field association, sorts, prints, and exports. The same field can appear in multiple WIT rows by design.

## Verification checklist

- Run the offline checks in PowerShell 7 and Windows PowerShell 5.1.
- Confirm the chosen process ID/name in the listing output.
- Compare the exported WIT count and representative fields with the Azure DevOps process UI.
- Open the CSV with UTF-8-aware software and confirm headers/row counts.

Offline checks verify local contracts only and do not make live calls or prove the exported process is complete at a later time.

## Troubleshooting

- Empty/unknown process: rerun the listing and pass its exact `typeId`.
- `401`/`403`: verify organization, PAT expiry/scopes, and process-view permission.
- Output error: ensure the parent directory exists and the CSV is not locked.
- Missing field: confirm it is attached to at least one WIT in the selected process.

## Limitations

The CSV is a WIT-field attachment inventory, not a full process backup. It omits rule/layout/state/picklist/security detail and does not provide transactional point-in-time consistency. No live validation is claimed by offline tests.

## Security

Use a short-lived read-only PAT. Protect the CSV and logs because process names, custom field names, and reference names can reveal internal design. Never place PAT text in scripts or source control.

## Related workflows

Use this inventory to plan [work item type migration](../ado-migrate-workitemtype/README.md), then prepare [Area Paths](../ado-import-area-paths/README.md), [Iteration Paths](../ado-import-iterations/README.md), and [dashboard queries](../ado-dashboard-migration/readme.md).
