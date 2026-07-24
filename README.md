# ADO Utils

Practical Azure DevOps automation for process migration, iteration/area path setup, dashboard query portability, wiki migration, and work item reporting.

This repository is built for real delivery work: quickly moving structure and configuration between projects while staying safe, repeatable, and auditable.

## Why This Repo Exists

Azure DevOps setup and migration work is often repetitive and risky:

- Complex hierarchy imports (iterations, area paths)
- Process and work item type migration across templates
- Query portability when starting new projects
- Wiki content migration with verification
- Field usage validation across multiple projects

These scripts automate those tasks with a bias toward:

- Idempotent operations
- Preview-first patterns before writes
- Strong validation and useful logs
- Minimal external dependencies where possible

## At a Glance

| Goal | Start with |
|---|---|
| Export and replicate an inherited process | `export_process.mjs`, then `migrate_process.mjs` |
| Migrate one custom work item type | `ADO Utils/ado-migrate-workitemtype.ps1` |
| Load iteration hierarchy from Excel | `build_iteration_template.mjs` + `Import-AzureDevOpsIterations-Excel.ps1` |
| Load area hierarchy from CSV | `ADO Utils/ado-import-area-paths.ps1` |
| Move dashboard queries between projects | `ADO Utils/ado-export-dashboard-queries.ps1` + `ADO Utils/ado-import-dashboard-queries.ps1` |
| Migrate wiki content safely | `ADO Utils/ado-migrate-wiki.ps1` or `ado-extract-wiki.ps1` + `ado-load-wiki.ps1` |
| Validate cross-project field usage | `ado_validate_complete.mjs` and `review_ado_changes.mjs` |

## What You Can Do

### Process and WIT migration

- Export a full inherited process definition to JSON.
- Rebuild a CMMI-based process onto an Agile inherited process.
- Migrate a specific work item type including fields, picklists, states, rules, and layout.

### Hierarchy loading

- Import Area Paths from CSV (creates only missing nodes).
- Import Iterations from Excel template, with preview and optional apply/update behavior.
- Generate a styled iteration template workbook and previews.

### Query portability and migration

- Export dashboard query packs from one project.
- Import dashboard queries into a target project with WIQL transformations for portability.

### Wiki migration

- Direct wiki-to-wiki migration.
- Extract wiki content to Markdown with manifest/hash verification.
- Load manifest-backed Markdown exports into a target wiki.

### Validation and reporting

- Validate field usage across multiple projects against workbook references.
- Reconcile and update workbook output artifacts.
- Export overdue task reports to CSV.

## Repository Layout

```text
.
|-- ADO Utils/
|   |-- ado-migrate-wiki.ps1
|   |-- ado-extract-wiki.ps1
|   |-- ado-load-wiki.ps1
|   |-- ado-import-area-paths.ps1
|   |-- ado-import-iterations.ps1
|   |-- ado-export-dashboard-queries.ps1
|   |-- ado-import-dashboard-queries.ps1
|   `-- ado-migrate-workitemtype.ps1
|-- outputs/
|-- *.mjs
|-- *.ps1
`-- CSV/XLSX working files
```

## Prerequisites

### Core

- PowerShell 7+ (Windows PowerShell 5.1 also works for many scripts)
- Node.js 20+ (for `.mjs` scripts)
- Azure DevOps PAT(s) with appropriate permissions

### Optional

- Azure CLI (`az`) for scripts that obtain bearer tokens
- Microsoft Excel desktop for `Import-AzureDevOpsIterations-Excel.ps1`

### Node dependencies

Several `.mjs` scripts use `@oai/artifact-tool` for workbook import/export and inspection.

```powershell
npm install @oai/artifact-tool
```

If this repository is consumed as a standalone clone, add your own `package.json` as needed.

## Quick Start

### 1) Clone and open

```powershell
git clone https://github.com/ScottPriestley/ado-utils.git
cd ado-utils
```

### 2) Set PAT environment variables (example)

```powershell
$env:ADO_PAT_JULY = "<pat>"
$env:ADO_PAT_HUB = "<pat>"
$env:ADO_PAT_AEC = "<pat>"
$env:ADO_TOKEN = "<bearer-token-if-needed>"
```

Note: many PowerShell scripts prompt securely for PAT input if not provided.

### 3) Run a common workflow

### Validate workbook field usage across three projects

```powershell
node ado_validate_complete.mjs
```

### Build iteration template workbook

```powershell
node build_iteration_template.mjs
```

### Preview iteration import from Excel

```powershell
./Import-AzureDevOpsIterations-Excel.ps1 `
  -Organization "https://dev.azure.com/your-org" `
  -Project "Your Project" `
  -ExcelFile ".\outputs\ado_iteration_loader\ADO_Iteration_Load_Template.xlsx"
```

### Apply iteration import

```powershell
./Import-AzureDevOpsIterations-Excel.ps1 `
  -Organization "https://dev.azure.com/your-org" `
  -Project "Your Project" `
  -ExcelFile ".\outputs\ado_iteration_loader\ADO_Iteration_Load_Template.xlsx" `
  -Apply
```

## Script Index

### Root `.mjs` scripts

| Script | Purpose |
|---|---|
| `export_process.mjs` | Export full inherited process metadata (WITs, fields, states, rules, layout, behaviors, picklists). |
| `migrate_process.mjs` | Rebuild source process customizations onto a new Agile-based inherited process. |
| `ado_validate.mjs` / `ado_validate_complete.mjs` | Validate field reference usage across multiple ADO projects and write `ado_validation.json`. |
| `review_ado_changes.mjs` | Print detected validation changes from `ado_validation.json`. |
| `update_where_used.mjs` | Update/revalidate workbook values and render output previews. |
| `build_iteration_template.mjs` | Generate a styled iteration import workbook and preview image. |
| `inspect_workbook.mjs` / `inspect_workbook_values.mjs` | Inspect workbook structure and raw values for troubleshooting. |
| `ado_list_aec_projects.mjs` | List projects from a target ADO org using PAT auth. |

### Root `.ps1` scripts

| Script | Purpose |
|---|---|
| `Import-AzureDevOpsIterations-Excel.ps1` | Excel-COM wrapper for iteration loader; includes in-memory date validation patch. |
| `Import-AzureDevOpsIterations.ps1` | Import/preview iteration hierarchy from XLSX using ZIP/XML (no Python or COM). |
| `Run-AzureDevOpsIterations.ps1` | Wrapper to run the patched iteration loader in a predictable way. |
| `ado-overdue.ps1` | Query overdue ADO tasks and export CSV report. |

### `ADO Utils` folder

| Script | Purpose |
|---|---|
| `ado-import-area-paths.ps1` | Idempotent Area Path import from CSV with final verification. |
| `ado-import-iterations.ps1` | Iteration import with preview/apply behavior. |
| `ado-export-dashboard-queries.ps1` | Export dashboard query folder tree, WIQL, metadata, and package zip. |
| `ado-import-dashboard-queries.ps1` | Import query packages with portability transforms and optional placeholders. |
| `ado-migrate-workitemtype.ps1` | Migrate a single WIT between inherited processes (fields/states/rules/layout). |
| `ado-migrate-wiki.ps1` | Direct wiki migration between projects/orgs. |
| `ado-extract-wiki.ps1` | Extract wiki pages to manifest-backed Markdown files. |
| `ado-load-wiki.ps1` | Load extracted Markdown package into target project wiki. |

For full wiki migration guidance, see `ADO Utils/ado-migrate-wiki README.md`.

## Authentication Notes

Different scripts use different auth styles:

- PAT over Basic auth (most PowerShell and some Node scripts)
- Bearer tokens from Azure CLI (`az account get-access-token`) for process migration flows

Minimum PAT scopes depend on operation, usually including:

- Work Items: Read / Write
- Process: Read & Write (for process/WIT customization)
- Project/Wiki read-write where wiki scripts are used

Use least-privilege, short-lived PATs when possible.

## Outputs and Artifacts

Common generated outputs:

- `ado_validation.json`
- `outputs/migration_log.jsonl`
- `outputs/ado_iteration_loader/*`
- `outputs/where_used_revalidated/*`
- timestamped logs from migration/import scripts

Treat exported artifacts as potentially sensitive project data.

## Safety and Repeatability

Many scripts are designed for safe reruns:

- Create-missing behavior instead of destructive replacement
- Preview-first defaults for hierarchy imports
- Verification passes after write operations
- Conflict and validation logging

Even with idempotent design, run first against non-production projects where possible.

## Typical Migration Playbook

1. Export current process and baseline artifacts.
2. Build/validate target process migration.
3. Import area/iteration hierarchy with preview first.
4. Port dashboard queries with transformations.
5. Migrate wiki content and verify.
6. Run validation scripts and review deltas.

## Contributing

Contributions are welcome, especially:

- Additional idempotent migration utilities
- Better diagnostics/logging
- Safer dry-run capabilities
- Documentation improvements and scenario examples

If you add a new script, include:

- A concise synopsis/help block
- Example usage
- Required permissions/scopes
- Output expectations

## Disclaimer

These scripts can make live changes in Azure DevOps projects and processes. Review, test, and validate in non-production environments before running against production data.
