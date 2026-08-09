<div align="center">

# Azure DevOps Discussion Export

**Exports a saved query's work items and their full comment threads to a timestamped CSV, without changing anything in Azure DevOps.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows-0078D4?style=flat-square)
![Azure DevOps](https://img.shields.io/badge/Azure%20DevOps-0078D4?style=flat-square&logo=azuredevops&logoColor=white)
![Read-only](https://img.shields.io/badge/Azure%20DevOps-Read--only-4a5568?style=flat-square)

</div>

`ado-extract-discussions.ps1` executes one saved Azure DevOps query, exports the query-selected work item fields, and includes paged discussion comments for each record. It is read-only against Azure DevOps and creates a new CSV for each run.

## Table of Contents

- [Using the tool](#using-the-tool)
- [Technical reference](#technical-reference)
  - [Scripts, capabilities, and exclusions](#scripts-capabilities-and-exclusions)
  - [Prerequisites](#prerequisites)
  - [Authentication and minimum PAT scopes](#authentication-and-minimum-pat-scopes)
  - [Safety and rerun behavior](#safety-and-rerun-behavior)
  - [Quick start](#quick-start)
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

**What it does:** Runs one saved query in Azure DevOps and, for every work item it returns, writes a row to a CSV containing the columns that query selects plus the full discussion/comments thread for that item. It only reads from Azure DevOps — it never changes, deletes, or writes anything back to your project.

**When you'd use it:** You need an offline copy of work item discussions — for example, before a migration where comments won't otherwise be carried over, or when you want to review or archive conversation history for a set of work items outside Azure DevOps.

```mermaid
graph LR
    A[Saved Query] --> B[ado-extract-discussions.ps1]
    B --> C["Work Items + Comments"]
    C --> D["CSV (timestamped)"]

    style A fill:#718096,color:#fff
    style B fill:#4a5568,color:#fff
    style C fill:#718096,color:#fff
    style D fill:#4a5568,color:#fff
```

> [!NOTE]
> This script always prompts for a fresh PAT rather than reusing one from your environment — have it ready to paste in or supply as a parameter.

**Before you start, have ready:**
- The Azure DevOps project URL (organization + project).
- A saved query URL in that same project — this defines exactly which work items get exported.
- A Personal Access Token (PAT) with at least Work Items Read access.

**How to run it, step by step:**
```powershell
$pat = Read-Host 'Azure DevOps PAT (input hidden)' -AsSecureString
./ado-extract-discussions/ado-extract-discussions.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Project' `
  -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -Pat $pat
```
If you omit `-ProjectUrl` or `-QueryUrl`, the script will prompt you for them interactively.

**What to expect as output:**
- A new CSV file named `AdoWorkItemDiscussions-<queryId>-<timestamp>.csv`, written next to the script, with one row per work item that finished exporting — including a "Discussions" column with that item's comments.
- A folder of log files recording what the script did.
- Every run creates a brand-new CSV; it never appends to or resumes a previous export. Old exports are left alone, so you'll want to clean up files you no longer need.

**What it will NOT do:**
- It will not modify or delete anything in Azure DevOps — it is strictly read-only.
- It will not export revision history, attachments, work item relations/links, or identity/user mapping data.
- It will not resume a partial or failed export — a rerun always starts a fresh CSV from scratch.
- It cannot restore or import data anywhere; it only produces a local CSV for review.

## Technical reference

### Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-extract-discussions.ps1` | Reads one saved query's WIQL, executes it, exports the selected query columns, pages each returned work item's comments, and writes one CSV row per completed work item. | Does not export revisions, attachments, relations, history, identity mappings, or restore/import data. |

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source project read access.
- A saved query URL for the source project.
- Work Items Read PAT scope.
- Disk access to write `AdoWorkItemDiscussions-<queryId>-<timestamp>.csv` beside the script.

### Authentication and minimum PAT scopes

`Pat` resolves from SecureString parameter -> hidden prompt `Azure DevOps PAT (input hidden)`. This script intentionally asks for a fresh PAT when `-Pat` is omitted instead of using `ADO_PAT`, so a stale environment token cannot silently drive the export. `-NonInteractive` rejects missing values instead of prompting. PATs are registered for redaction and not written to the CSV or logs.

Minimum scope is Work Items Read. Project permission can still block comments or work items.

### Safety and rerun behavior

The script performs read-only Azure DevOps calls and never deletes or writes remote data. It writes a fresh `AdoWorkItemDiscussions-<queryId>-<timestamp>.csv` beside the script on every run. It does not append to or resume from previous exports.

There is no `-WhatIf` because the only writes are local CSV/log files. CSV file-sharing conflicts are retried and then surfaced as errors.

### Quick start

```powershell
$pat = Read-Host 'Azure DevOps PAT (input hidden)' -AsSecureString
./ado-extract-discussions/ado-extract-discussions.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Project' `
  -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -Pat $pat `
  -LogDirectory './run-logs' `
  -NonInteractive
```

<details>
<summary>Running from this folder directly</summary>

```powershell
./ado-extract-discussions.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Project' `
  -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -Pat $pat
```

</details>

### Parameters and precedence

| Parameter | Description |
| --- | --- |
| `ProjectUrl` | Azure DevOps project URL. Prompts as `Project URL` when omitted. Must match the query URL's organization and project. |
| `QueryUrl` | Saved query URL. Prompts as `Query URL` when omitted. |
| `Pat` | Default role `SecureString` PAT. |
| `LogDirectory` | Shared JSONL directory; defaults to `logs` beside the script. |
| `NonInteractive` | Rejects missing inputs instead of prompting. |

PAT precedence is SecureString parameter -> hidden prompt. `ProjectUrl` and `QueryUrl` use parameter -> prompt.

### Input formats

`ProjectUrl` must identify `https://dev.azure.com/{org}/{project}`. `QueryUrl` must identify `https://dev.azure.com/{org}/{project}/_queries/query/{queryId}/`, and the organization/project must match `ProjectUrl`.

Flat saved queries return their direct work item IDs. Tree and relationship queries return relation endpoints; the script de-duplicates source and target IDs before exporting records.

### Outputs and logs

`AdoWorkItemDiscussions-<queryId>-<timestamp>.csv` is written beside the script and includes one completed row per work item. Previous exports are left untouched.

<details>
<summary><strong>CSV schema and JSONL log format</strong> — output columns and shared logger record shape</summary>

Rows include `QueryId`, `QueryName`, the saved query's selected columns in query order, and `Discussions`. Custom fields such as `Process sequence ID` are included when the saved query selects them.

Every run creates `ado-extract-discussions-success log-<run-id>.jsonl` and `ado-extract-discussions-error log-<run-id>.jsonl` in `LogDirectory` or local `logs`, UTF-8 without BOM. Records include `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; secrets are redacted.

</details>

### Detailed workflow and behavior

<details>
<summary>Step-by-step script behavior</summary>

The script parses the project and query URLs, resolves the PAT, reads the saved query WIQL, executes the query, de-duplicates the returned work item IDs, reads the query-selected fields for each work item, pages comments for each work item, and appends the CSV row only after that work item is complete. It logs progress and final outcome through the shared logger.

</details>

### Verification checklist

<details>
<summary>Before and after a run</summary>

- Run `pwsh -NoProfile -File ./tests/run-offline-checks.ps1`.
- Confirm project URL, query URL, and Work Items Read scope.
- Close any application holding the CSV before running.
- Review both JSONL logs and the CSV row count.
- Spot-check representative work item comments against Azure DevOps.

Offline checks make no live calls and cannot prove comments visible to one PAT are complete for another identity.

</details>

### Troubleshooting

<details>
<summary>Common errors and what they mean</summary>

- CSV locked: close Excel or other viewers and rerun.
- Missing comments: verify the PAT identity can see the work item and discussion.
- Project/query mismatch: use a query URL from the same organization and project as `ProjectUrl`.
- `401`/`403`: re-enter a PAT for the query's organization, then verify expiry, Work Items Read scope, and project/query permission.
- Re-running always creates a new CSV. Archive or delete old CSVs manually when they are no longer needed.

</details>

### Limitations

No revision/comment history beyond current comments API output, no attachments, no relation export beyond using relationship-query endpoint IDs as the record set, no import/restore path, and no remote dry run.

### Security

Use a short-lived read-only PAT. Protect the CSV and logs because descriptions and comments can contain sensitive project content. Do not commit exports or PATs.

### Related workflows

Use before migrations when discussion content needs offline review. Other copy/migration tools in this repository do not migrate comments; see the [root README](../README.md) for workflow boundaries.
