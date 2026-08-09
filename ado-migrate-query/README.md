<div align="center">

# Azure DevOps Saved Query Migration

**Copies a configured set of saved queries from one Azure DevOps project to another, rewriting project references — a query-definition migration helper, not a work item copy tool.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows-0078D4?style=flat-square)
![Azure DevOps](https://img.shields.io/badge/Azure%20DevOps-0078D4?style=flat-square&logo=azuredevops&logoColor=white)

</div>

`ado-migrate-query.ps1` copies a configured set of saved Azure DevOps queries from one project to another, rewrites project references, and records source-to-target query IDs.

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

**What it does:** Reads a set of saved queries (their WIQL definitions) from a source Azure DevOps project and recreates them in a target project — rewriting the project name inside the query text and adjusting a few specific query constructs that don't carry over as-is. It records which source query became which target query so reruns can pick up where they left off.

**When you'd use it:** Setting up a new/target Azure DevOps project and you want the same saved queries (Shared Queries) to exist there, without recreating them by hand.

```mermaid
graph LR
    A[Source Project Queries] --> B[ado-migrate-query.ps1]
    B --> C["Rewritten WIQL"]
    C --> D[Target Project Queries]

    style A fill:#718096,color:#fff
    style B fill:#4a5568,color:#fff
    style C fill:#718096,color:#fff
    style D fill:#4a5568,color:#fff
```

> [!WARNING]
> The script's checked-in default query IDs (and org/project values) are specific to one environment (`spriestley/TestBed`) and are very unlikely to be right for yours. Review and override them with `-QueryIds` and explicit org/project parameters before any live run.

**Before you start, have ready:**
- Source and target organization names and project names.
- The list of source query GUIDs you want migrated (or use the script's defaults only after reviewing them — they're specific to one environment and unlikely to be right for yours).
- A PAT for the source project with Work Items Read access.
- A PAT for the target project with Work Items Read & write access.
- The target project should already have the fields, work item types, states, Area Paths, and Iteration Paths that the query WIQL references — this tool does not create any of that.

**How to run it, step by step:**
```powershell
./ado-migrate-query/ado-migrate-query.ps1 `
  -SourceOrg 'source' -SourceProject 'Source Project' `
  -TargetOrg 'target' -TargetProject 'Target Project' `
  -QueryIds @('00000000-0000-0000-0000-000000000000') `
  -SourcePat $sourcePat `
  -TargetPat $targetPat `
  -OutputDirectory './ado-query-migration-output'
```

**What to expect as output:**
- The migrated queries appear as Shared Queries in the target project.
- A folder of state and log files (JSON and log files) recording what was created, what was skipped, and why — useful for confirming the run did what you expected and for safely rerunning later.
- Nothing in the source project is changed; the source queries are only read.

**What it will NOT do:**
- It will not touch or overwrite a target query that already exists with different WIQL — it leaves those alone and logs them for you to review by hand.
- It will not delete anything in either project.
- It will not migrate query permissions, favorites, or dashboard widgets.
- It will not copy the actual work items that a query returns — only the query definition itself.
- It will not create target fields, work item types, or Area/Iteration Paths — those must already exist in the target project.

## Technical reference

### Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-migrate-query.ps1` | Reads configured source query IDs, rewrites source-project literals and selected unsupported Boolean predicates, creates missing target folders/queries, and records target IDs. | Does not overwrite differing target WIQL, migrate query permissions/favorites, copy work items, or prepare target fields/types/classification paths. |

> [!NOTE]
> The checked-in default org/project/query values are environment-specific examples and must be reviewed before live use.

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source Work Items Read.
- Target Work Items Read & write.
- Target process fields, states, work item types, Area Paths, and Iteration Paths already prepared for the query WIQL.

### Authentication and minimum PAT scopes

`SourcePat` resolves from SecureString parameter -> `ADO_SOURCE_PAT` -> hidden prompt `Source Azure DevOps PAT (input hidden)`. Target uses `ADO_TARGET_PAT` and `Target Azure DevOps PAT (input hidden)`. `-NonInteractive` rejects missing credentials. PATs are redacted and are not stored in output files.

Minimum scopes are Work Items Read for source and Work Items Read & write for target.

### Safety and rerun behavior

The script creates folders and queries but does not delete. It writes `migration-state.json` in `OutputDirectory` and verifies a state hit by reading the recorded target ID. Existing identical target queries are recorded and skipped. Existing differing WIQL is intentionally not overwritten.

There is no `-WhatIf` or remote dry run. Reruns are stateful but still require review of skipped/differing queries.

### Quick start

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

<details>
<summary>Running from this folder directly</summary>

```powershell
./ado-migrate-query.ps1 `
  -SourceOrg 'source' -SourceProject 'Source Project' `
  -TargetOrg 'target' -TargetProject 'Target Project' `
  -SourcePat $sourcePat -TargetPat $targetPat
```

</details>

### Parameters and precedence

<details>
<summary><strong>Full parameter reference</strong> — every parameter this script accepts</summary>

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

</details>

### Input formats

`QueryIds` is a PowerShell string array of GUIDs. Organization inputs may be `contoso`, `https://dev.azure.com/contoso`, or the supported legacy organization URL form. The script reads source query definitions from Azure DevOps and stores snapshots in JSON.

### Outputs and logs

`OutputDirectory` contains:

```text
migration-state.json
source-queries.json
field-schema.json
success.log
error.log
```

<details>
<summary><strong>Log file details</strong> — legacy text logs plus shared JSONL schema</summary>

The legacy `success.log` and `error.log` are human-readable per-query logs. The shared logger also creates `ado-migrate-query-success log-<run-id>.jsonl` and `ado-migrate-query-error log-<run-id>.jsonl` under `LogDirectory` or local `logs`, UTF-8 without BOM. JSONL records include `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`.

</details>

### Detailed workflow and behavior

<details>
<summary>Step-by-step script behavior</summary>

The script resolves endpoints and PATs, creates `OutputDirectory`, loads migration state, reads target fields/schema, and processes each source query ID. It can use checked-in fallback WIQL for three known default IDs when source query lookup needs that branch. It rewrites source project names and selected unsupported custom Boolean predicates, creates missing folders, creates missing queries, reads newly created target queries back, and records the target ID.

If a target query already exists with identical WIQL, it is recorded and skipped. Differing target WIQL is refused and logged instead of overwritten.

</details>

### Verification checklist

<details>
<summary>Before and after a live run</summary>

- Run `pwsh -NoProfile -File ./tests/run-offline-checks.ps1`.
- Review `QueryIds`, org/project defaults, and target root folder before any live run.
- Confirm target fields/types/paths used by WIQL exist.
- Review `source-queries.json`, `field-schema.json`, legacy logs, JSONL logs, and `migration-state.json`.
- Open representative target queries and compare WIQL/results manually.

Offline checks make no live calls and do not prove query results are semantically equivalent.

</details>

### Troubleshooting

<details>
<summary>Common errors and what they mean</summary>

- Differing target WIQL: inspect and decide manually; the script will not overwrite it.
- Missing field/type/path: prepare target process/classification paths and rerun.
- State references missing target ID: remove only the affected state entry after review, then rerun.
- `401`/`403`: verify source/target PAT scope, organization, and project permissions.

</details>

### Limitations

No query permissions, favorites, work item data, dashboard widgets, rollback, delete, or dry run. WIQL rewrites are targeted, not a complete language migration.

### Security

Use least-privilege PATs. Protect output JSON and logs because they include WIQL, field names, project names, and query IDs. Never commit PATs or environment-specific state.

### Related workflows

Run after [work item type migration](../ado-migrate-workitemtype/README.md), [Area Paths](../ado-import-area-paths/README.md), and [Iteration Paths](../ado-import-iterations/README.md). For dashboard query migration, use [dashboard migration](../ado-dashboard-migration/README.md). Shared conventions are in the [root README](../README.md).
