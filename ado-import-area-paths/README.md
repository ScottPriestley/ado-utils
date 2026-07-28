# Azure DevOps Area Path Import/Migration

Two standalone PowerShell scripts for getting an Area Path hierarchy into an Azure DevOps project — either from a CSV file, or copied directly from another project.

| Script | Purpose | Best used when |
| --- | --- | --- |
| `ado-import-area-paths.ps1` | Imports Area Paths from a CSV file into one project | You're building a project's hierarchy from a spreadsheet/template |
| `ado-migrate-area-paths.ps1` | Copies the Area Path tree directly from a source project to a target project | Both source and target projects are available during the migration |

Both scripts are idempotent: only missing nodes are created, existing nodes are left untouched, and a final read-back verifies every requested path exists before the script reports success.

## Prerequisites

- PowerShell 7+ (or Windows PowerShell 5.1).
- A PAT with **Work Items (Read & Write)** on the relevant project(s). PATs are requested as secure input and are not written to disk.

## Import from CSV — `ado-import-area-paths.ps1`

```powershell
.\ado-import-area-paths.ps1 `
    -Organization 'https://dev.azure.com/contoso' `
    -Project 'My Project' `
    -CsvFile 'C:\Temp\AreaPaths.csv'
```

### CSV format

Required columns: `Name`, `AreaPath`, `ParentPath`, `Level`. `AreaPath` is relative to the project's Area root, and the CSV must include exactly one `Level 0` root row whose `Name` and `AreaPath` match the project's Area root (normally the project name):

```csv
Name,AreaPath,ParentPath,Level
My Project,My Project,,0
Finance,Finance,My Project,1
Ledger,Finance\Ledger,Finance,2
```

### Parameters

| Parameter | Description |
| --- | --- |
| `Organization` | Organization URL, e.g. `https://dev.azure.com/contoso`. Required. |
| `Project` | Project name or ID. Required. |
| `CsvFile` | Path to the Area Path CSV. Required. |
| `Pat` | PAT as a `SecureString`. Prompts securely when omitted. |

Supports `-WhatIf` / `-Confirm` (`SupportsShouldProcess`) to preview which nodes would be created.

### Behavior

- Validates the CSV structure (required columns, exactly one root row, no duplicate or malformed area paths, parent/name consistency) before making any API calls.
- Reads the project's live Area Path tree, computes any parent nodes implied but not explicitly listed in the CSV, and creates only what's missing, parent-first.
- Re-reads the tree after writing and throws if any requested path is still missing.

## Migrate between projects — `ado-migrate-area-paths.ps1`

```powershell
.\ado-migrate-area-paths.ps1
```

Run with no parameters — it prompts interactively for the source organization, source project, source PAT, target organization, target project, and target PAT (organization can be entered as a bare name like `contoso` or a full URL).

### Behavior

- Reads the full Area Path tree from both the source and target projects.
- Creates every Area Path present in the source but missing in the target, parent-first. Existing target nodes (including target-only paths not present in the source) are left unchanged.
- Re-reads the target tree after writing and throws if any source path is still missing.

Supports `-WhatIf` / `-Confirm` to preview without writing.

## Notes

- Neither script deletes Area Paths — both are additive only.
- Re-running either script after a partial failure is safe: existing nodes are detected and skipped.
