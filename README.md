# ADO Utils

Standalone PowerShell scripts for common Azure DevOps setup and migration tasks: process/work item type migration, area path and iteration hierarchy loading, dashboard/query portability, wiki migration, and process field auditing.

Each folder is self-contained — there's no shared build, no package manager, and no cross-folder dependency (aside from `ado-dashboard-migration/_common.ps1`, which is dot-sourced only by scripts in that same folder). Clone the repo, `cd` into the folder you need, and run the script.

## Why this repo exists

Azure DevOps setup and migration work is repetitive and easy to get wrong by hand:

- Migrating a custom work item type (fields, picklists, states, rules, form layout) between processes.
- Loading area path or iteration hierarchies into a new project from CSV/Excel.
- Carrying dashboards and their underlying queries from one project to another.
- Migrating wiki content between projects, with or without a local backup step.
- Auditing which fields a process actually defines, for documentation or governance.

These scripts favor:

- **Idempotent operations** — safe to re-run; existing items are detected and reused/patched, not duplicated.
- **Preview-first where it matters** — the iteration importer defaults to preview and requires `-Apply` to write.
- **Verification after writes** — area/iteration migrations re-read the target and fail loudly if anything's still missing; wiki migration reads pages back and compares content.
- **No exotic dependencies** — plain PowerShell and the Azure DevOps REST API. No Azure CLI, no external modules, no Python.

## Repository layout

```text
.
|-- ado-dashboard-migration/     # Steps 1-4: export/migrate dashboards + their queries
|-- ado-field-extraction/        # Audit all fields defined by a process, export to CSV
|-- ado-import-area-paths/       # Load/migrate Area Path hierarchy
|-- ado-import-iterations/       # Load/migrate Iteration Path hierarchy (with dates)
|-- ado-migrate-wiki/            # Direct wiki migration, or extract-to-Markdown + load
`-- ado-migrate-workitemtype/    # Migrate one custom work item type between processes
```

Each folder has its own `README.md` with full parameter tables, examples, and troubleshooting — this file is the index.

## At a glance

| Goal | Folder | Start with |
|---|---|---|
| Migrate a custom work item type between processes | [ado-migrate-workitemtype](ado-migrate-workitemtype/README.md) | `ado-migrate-workitemtype.ps1` |
| Load an Area Path hierarchy from CSV, or copy it between projects | [ado-import-area-paths](ado-import-area-paths/README.md) | `ado-import-area-paths.ps1` / `ado-migrate-area-paths.ps1` |
| Load an Iteration (sprint) hierarchy from Excel, or copy it between projects | [ado-import-iterations](ado-import-iterations/README.md) | `ado-import-iterations.ps1` / `ado-migrate-iterations.ps1` |
| Move dashboards and their queries between projects | [ado-dashboard-migration](ado-dashboard-migration/readme.md) | `01-export-dashboards.ps1` → `02-migrate-queries.ps1` → `03-import-dashboards.ps1` |
| Migrate wiki content between projects | [ado-migrate-wiki](ado-migrate-wiki/README.md) | `ado-migrate-wiki.ps1` (direct) or `ado-extract-wiki.ps1` + `ado-load-wiki.ps1` (via Markdown) |
| List every field a process defines, exported to CSV | [ado-field-extraction](ado-field-extraction/README.md) | `ado-organization-ID-listing.ps1` then `ado-process-fields.ps1` |

## Prerequisites

- PowerShell 7+ (Windows PowerShell 5.1 also works for most scripts — see each folder's README for specifics).
- Azure DevOps Personal Access Token(s) with the scopes each script needs (documented per folder). Scripts prompt securely for a PAT when one isn't supplied, and none of them write a PAT to disk or logs.
- `ado-import-iterations.ps1` reads `.xlsx` workbooks directly via .NET's built-in ZIP/XML support — no Excel installation or extra module required.

No Node.js, no `npm install`, no Azure CLI is required by anything in this repo.

## Authentication notes

All scripts use PAT-over-Basic auth against `https://dev.azure.com`. Most accept the organization as either a bare name (`contoso`) or a full URL (`https://dev.azure.com/contoso`, `https://contoso.visualstudio.com`) and normalize it automatically.

Minimum PAT scopes generally needed, by task:

| Task | Typical scopes |
|---|---|
| Read-only export/audit (field extraction, dashboard export, wiki extract) | Work Items (Read), Project and Team (Read), Dashboards (Read) as applicable |
| Area/Iteration import or migration | Work Items (Read & Write) |
| Dashboard/query import | Work Items (Read & Write), Team Dashboards (Manage) |
| Wiki migration (target side) | Read/write on the target project and wiki |
| Work item type migration (target side) | Work Items (Read & Write), Process (Read & Write); org-level field creation needs Project Collection Administrator or equivalent |

Use least-privilege, short-lived PATs, and revoke migration-specific PATs once you've validated the result.

## Safety and repeatability

- Most write operations are **create-missing**, not destructive replace — re-running a script after a partial failure fills in what's still missing rather than duplicating or overwriting unrelated content.
- Area/Iteration scripts verify against a fresh read of the target after writing and throw if anything requested is still absent.
- Wiki migration reads every written page back and fails the run if the content doesn't match what was sent.
- Even with idempotent design, run against a non-production project first when the target is unfamiliar or the operation is new to you.

## Typical migration playbook

For standing up a new project from an existing one:

1. Migrate any custom work item types the new project needs (`ado-migrate-workitemtype`).
2. Load the Area Path and Iteration Path hierarchies (`ado-import-area-paths`, `ado-import-iterations`).
3. Migrate dashboards and their queries (`ado-dashboard-migration`, steps 1–4).
4. Migrate wiki content (`ado-migrate-wiki`).
5. Review each step's generated report/log before moving to the next.

## Outputs and artifacts

Scripts that export data write it into the current directory or a folder you specify (never into this repo's tracked source unless you point them there): timestamped wiki migration logs, dashboard export folders (`dashboards/`, `queries.json`, `inventory.md`, etc.), and CSV field exports. Treat these as potentially sensitive project data — they can contain query text, project structure, and page content.

## Contributing

If you add a new script:

- Include a `.SYNOPSIS`/`.DESCRIPTION` comment-based help block and at least one `.EXAMPLE`.
- Document required PAT scopes and expected output.
- Prefer idempotent, create-missing behavior over destructive replacement; verify writes where practical.
- Add or update the relevant folder's `README.md`, and add a row to the **At a glance** table above if it's a new top-level workflow.

## Disclaimer

These scripts make live changes to Azure DevOps projects and processes. Review, test, and validate against non-production projects before running against production data.
