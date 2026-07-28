# Azure DevOps Iteration Path Import/Migration

Two standalone PowerShell scripts for getting an Iteration Path (sprint) hierarchy into an Azure DevOps project — either from an Excel workbook, or copied directly from another project.

| Script | Purpose | Best used when |
| --- | --- | --- |
| `ado-import-iterations.ps1` | Previews or imports Iteration Paths (with start/finish dates) from an Excel workbook into one project | You're building a project's sprint calendar from a spreadsheet/template |
| `ado-migrate-iterations.ps1` | Copies the Iteration Path tree, including dates, directly from a source project to a target project | Both source and target projects are available during the migration |

Both scripts are idempotent: only missing nodes are created, and existing nodes are left untouched by default.

## Prerequisites

- PowerShell 7+ (or Windows PowerShell 5.1).
- A PAT with **Work Items (Read & Write)** on the relevant project(s). PATs are requested as secure input and are not written to disk.
- `ado-import-iterations.ps1` reads `.xlsx` files directly via .NET's built-in ZIP/XML support — no Excel installation, COM automation, or third-party module required.

## Import from Excel — `ado-import-iterations.ps1`

Default is **preview only**; add `-Apply` to actually create iterations.

```powershell
# Preview
.\ado-import-iterations.ps1 `
    -Organization 'https://dev.azure.com/contoso' `
    -Project 'New Project' `
    -ExcelFile '.\ADO_Iteration_Load_Template.xlsx'

# Apply
.\ado-import-iterations.ps1 `
    -Organization 'https://dev.azure.com/contoso' `
    -Project 'New Project' `
    -ExcelFile '.\ADO_Iteration_Load_Template.xlsx' `
    -Apply
```

### Workbook format

The workbook must contain a worksheet named **Iterations** with a header row `Parent Path | Iteration Name | Start Date | Finish Date` (columns A–D). Rows below that header are read until the sheet ends; dates must be in `yyyy-MM-dd` format. `Parent Path` may be blank for top-level iterations, or a backslash-delimited path (e.g. `Release 1`) for nested ones.

### Parameters

| Parameter | Description |
| --- | --- |
| `Organization` | Organization URL, e.g. `https://dev.azure.com/contoso`. Required. |
| `Project` | Project name or ID. Required. |
| `ExcelFile` | Path to the `.xlsx` workbook. Required. |
| `Apply` | Actually create the missing iterations. Without it, the script only lists what would be created. |
| `UpdateExisting` | Reserved for updating already-existing leaf iterations; requires `-Apply`. Currently existing iterations are always skipped and reported, not overwritten. |
| `Pat` | PAT as a `SecureString`. Prompts securely when omitted. |

Supports `-WhatIf` / `-Confirm`.

### Behavior

- Validates every row (non-blank name, no path separators inside a name, valid `yyyy-MM-dd` dates, start ≤ finish, no duplicate paths) before contacting Azure DevOps.
- Reads the project's live Iteration Path tree, computes any implied parent nodes, and creates only what's missing, parent-first, carrying over start/finish dates from the workbook.
- Existing iterations at a matching path are left as-is and reported as skipped.

## Migrate between projects — `ado-migrate-iterations.ps1`

```powershell
.\ado-migrate-iterations.ps1
```

Run with no parameters — it prompts interactively for the source organization, source project, source PAT, target organization, target project, and target PAT (organization can be entered as a bare name like `contoso` or a full URL).

### Behavior

- Reads the full Iteration Path tree, including each node's `startDate`/`finishDate` attributes, from both the source and target projects.
- Creates every Iteration Path present in the source but missing in the target, parent-first, carrying over the source's start/finish dates where set. Existing target nodes are left unchanged.
- Re-reads the target tree after writing and throws if any source path is still missing.

Supports `-WhatIf` / `-Confirm` to preview without writing.

## Notes

- Neither script deletes Iteration Paths — both are additive only.
- Re-running either script after a partial failure is safe: existing nodes are detected and skipped.
