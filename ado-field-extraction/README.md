<div align="center">

# Azure DevOps Process Field Extraction

**Read-only PowerShell scripts that list an organization's processes and export the fields attached to every work item type in one process.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows-0078D4?style=flat-square)
![Azure DevOps](https://img.shields.io/badge/Azure%20DevOps-0078D4?style=flat-square&logo=azuredevops&logoColor=white)
![Read-only](https://img.shields.io/badge/Mode-Read--only-4a5568?style=flat-square)

</div>

## Table of Contents

- [Using the tool](#using-the-tool)
- [Technical reference](#technical-reference)
  - [Scripts, capabilities, and exclusions](#scripts-capabilities-and-exclusions)
  - [Prerequisites](#prerequisites)
  - [Authentication and minimum PAT scopes](#authentication-and-minimum-pat-scopes)
  - [Safety and rerun behavior](#safety-and-rerun-behavior)
  - [Parameters and precedence](#parameters-and-precedence)
  - [Input formats](#input-formats)
  - [Outputs and logs](#outputs-and-logs)
  - [Detailed workflow and behavior](#detailed-workflow-and-behavior)
  - [Verification checklist](#verification-checklist)
  - [Troubleshooting](#troubleshooting)
  - [Limitations](#limitations)
  - [Security](#security)
  - [Related workflows](#related-workflows)

---

## Using the tool

**What it does:** Looks at an Azure DevOps organization and tells you, first, what processes (like Agile, Scrum, or a custom inherited process) exist and their IDs, and second, for a chosen process, exactly which fields are attached to each of its work item types.

**When you'd use it:** Before migrating or redesigning a project, you need to know exactly what fields each work item type actually has — this gives you that inventory as a spreadsheet you can review, share, or use as a checklist while setting up a target project.

```mermaid
graph LR
    A[Azure DevOps Process] --> B[ado-process-fields.ps1]
    B --> C[CSV Field Inventory]

    style A fill:#4a5568,color:#fff
    style B fill:#718096,color:#fff
    style C fill:#4a5568,color:#fff
```

**What to have ready before starting:**

- The organization name or URL you want to inspect.
- A PAT with permission to view processes and read work items in that organization.
- Nothing else — no input files are needed for this tool.

**How to run it (two steps):**

```powershell
# Step 1: list the processes in the organization and note the process ID (typeId) you care about.
./ado-organization-ID-listing.ps1 -Organization 'contoso'

# Step 2: export the fields for that process's work item types to a CSV.
./ado-process-fields.ps1 `
  -Organization 'contoso' `
  -ProcessId '00000000-0000-0000-0000-000000000000' `
  -OutputPath './Contoso_Process_Fields.csv'
```

**What to expect as output:** The first script prints a table of process names and IDs to the console — nothing is saved. The second script prints a similar table and also writes a CSV file listing every work item type together with each field attached to it (name, reference name, type, whether it's required, read-only, or inherited). Both scripts also write their own run logs.

> [!NOTE]
> **What it will NOT do:**
> - It will not change anything in Azure DevOps — both scripts only read data.
> - It will not export field rules, states, form layouts, picklist values, or permissions — just the field-to-work-item-type attachment list.
> - It will not include fields that exist in the organization but aren't attached to any work item type in the chosen process.
> - It will not give you a point-in-time guaranteed-consistent snapshot if someone edits the process while the export is running.

## Technical reference

### Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-organization-ID-listing.ps1` | Prints process name, `typeId`, and description. | Does not write a process inventory file or modify Azure DevOps. |
| `ado-process-fields.ps1` | Enumerates process WITs and exports their attached field metadata. | Does not export rules, states, layouts, picklist values, permissions, or fields not attached to a WIT. |

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Azure DevOps access to view the organization's processes.
- Source PAT with Process Read and Work Items Read.

### Authentication and minimum PAT scopes

Both scripts use `Pat` (`SecureString`) → `ADO_SOURCE_PAT` → hidden prompt. `Organization` is used when supplied; otherwise the exact prompt is `Source Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)`. The exact PAT prompt is `Source Azure DevOps PAT (input hidden)`. `ado-process-fields.ps1` also prompts `Enter the source Azure DevOps process ID` when omitted. `-NonInteractive` rejects any missing value instead of prompting. Credentials are not cached.

### Safety and rerun behavior

Azure DevOps calls are GET-only. Rerunning the list is harmless. Field export replaces the file selected by `OutputPath`; choose a new path if the prior CSV must be preserved. No live consistency snapshot is guaranteed if the process changes during enumeration.

### Parameters and precedence

<details>
<summary><strong>Parameters and precedence</strong> — flags for both scripts</summary>

| Script | Parameters |
| --- | --- |
| Organization listing | `Organization`, `Pat`, `LogDirectory`, `NonInteractive`. |
| Field export | `Organization`, `Pat`, `ProcessId`, `OutputPath` (default `ADO_Process_Fields.csv` beside the script), `LogDirectory`, `NonInteractive`. |

Organization accepts `contoso`, `https://dev.azure.com/contoso`, or `https://contoso.visualstudio.com`. Explicit parameters precede prompts; PAT precedence is SecureString → environment → prompt.

For unattended execution, supply `-Pat $securePat -NonInteractive` or set `ADO_SOURCE_PAT` for the process.

</details>

### Input formats

`ProcessId` is the `typeId` printed by the listing script. `OutputPath` is a filesystem CSV path; its parent must exist. No input workbook or hidden template is required.

### Outputs and logs

The listing writes a formatted console table. Field export writes CSV columns `WorkItemType`, `FieldName`, `ReferenceName`, `Type`, `Required`, `ReadOnly`, and `Inherited`, sorted by `ReferenceName`, and also prints a table.

Each run creates UTF-8-without-BOM JSONL files named `<script-base>-success log-<run-id>.jsonl` and `<script-base>-error log-<run-id>.jsonl` under `LogDirectory` or the folder's `logs` directory. Records use `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; PAT/authorization values are redacted.

### Detailed workflow and behavior

The listing normalizes the organization, calls the processes endpoint, and formats the response. The exporter reads all work item types for the selected process, requests each WIT's fields, flattens one row per WIT/field association, sorts, prints, and exports. The same field can appear in multiple WIT rows by design.

### Verification checklist

<details>
<summary>Before and after a run</summary>

- Run the offline checks in PowerShell 7 and Windows PowerShell 5.1.
- Confirm the chosen process ID/name in the listing output.
- Compare the exported WIT count and representative fields with the Azure DevOps process UI.
- Open the CSV with UTF-8-aware software and confirm headers/row counts.

Offline checks verify local contracts only and do not make live calls or prove the exported process is complete at a later time.

</details>

### Troubleshooting

<details>
<summary>Common errors and what they mean</summary>

- Empty/unknown process: rerun the listing and pass its exact `typeId`.
- `401`/`403`: verify organization, PAT expiry/scopes, and process-view permission.
- Output error: ensure the parent directory exists and the CSV is not locked.
- Missing field: confirm it is attached to at least one WIT in the selected process.

</details>

### Limitations

The CSV is a WIT-field attachment inventory, not a full process backup. It omits rule/layout/state/picklist/security detail and does not provide transactional point-in-time consistency. No live validation is claimed by offline tests.

### Security

> [!WARNING]
> Use a short-lived read-only PAT. Protect the CSV and logs because process names, custom field names, and reference names can reveal internal design. Never place PAT text in scripts or source control.

### Related workflows

Use this inventory to plan [work item type migration](../ado-migrate-workitemtype/README.md), then prepare [Area Paths](../ado-import-area-paths/README.md), [Iteration Paths](../ado-import-iterations/README.md), and [dashboard queries](../ado-dashboard-migration/README.md).
