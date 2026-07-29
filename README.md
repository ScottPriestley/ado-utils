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
| Move dashboards and their queries between projects | [ado-dashboard-migration](ado-dashboard-migration/README.md) | `01-export-dashboards.ps1` → `02-migrate-queries.ps1` → `03-import-dashboards.ps1` (see [playbook](#typical-migration-playbook) for prerequisites) |
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

For standing up a new project from an existing one, run phases in order. Each phase has hard dependencies on the ones before it — skipping ahead causes query migration failures or dashboards that show empty results.

### Phase 0 — Read-only discovery (optional)

Run these in parallel when useful; neither writes to the target.

- **Field audit** — [ado-field-extraction](ado-field-extraction/README.md): list process fields for documentation or to confirm what the target process still needs.
- **Dashboard export** — [ado-dashboard-migration](ado-dashboard-migration/README.md) step 1: export source dashboards and review `inventory.md` before any target writes.

### Phase 1 — Process foundation (required before dashboard queries)

- Migrate each custom work item type the target process needs — [ado-migrate-workitemtype](ado-migrate-workitemtype/README.md).

Step 2 of dashboard migration skips queries whose WIQL references fields, types, or states the target process does not define. Run WIT migration first so those queries can be recreated.

### Phase 2 — Project structure (required before dashboard queries)

Load the full Area Path and Iteration Path hierarchies **before** migrating dashboard queries:

| Source | Area paths | Iteration paths (with sprint dates) |
|---|---|---|
| Another ADO project | `ado-migrate-area-paths.ps1` | `ado-migrate-iterations.ps1` |
| CSV / Excel template | `ado-import-area-paths.ps1` | `ado-import-iterations.ps1` |

Prefer the **migrate** scripts when copying from an existing project — they carry the complete tree and preserve iteration start/finish dates. Dashboard step 4 (`04-create-classification-nodes.ps1`) only creates paths referenced in exported query WIQL and does not set iteration dates; use it as a repair step, not a substitute for this phase.

### Phase 3 — Dashboards and queries

Run [ado-dashboard-migration](ado-dashboard-migration/README.md) in this order:

```text
01-export   (skip if already done in phase 0)
    ↓
02-migrate-queries
    ↓
04-create-classification-nodes   ← only if step 2 skipped queries for missing paths
    ↓
02-migrate-queries               ← re-run only if step 4 ran
    ↓
03-import-dashboards
```

Review `inventory.md`, `queries-skipped.txt`, and `import-flags.txt` before treating the migration as complete.

### Phase 4 — Wiki content (last)

- [ado-migrate-wiki](ado-migrate-wiki/README.md): direct migration, or extract-to-Markdown + load for an offline handoff.

Wiki migration has no hard API dependency on the earlier phases, but running it last keeps the review workflow clear — structure and reporting first, page content last.

### Dependencies at a glance

| Before you run… | Target must already have… |
|---|---|
| Dashboard step 2 (migrate queries) | Custom fields/types/states (phase 1); area and iteration paths referenced in WIQL (phase 2) |
| Dashboard step 3 (import dashboards) | Step 2 complete with a usable `querymap.json` |
| Dashboard step 4 (classification nodes) | Only needed when step 2 skipped path-related queries; run **before** re-running step 2, not after step 3 |

Review each phase's generated report or log before moving to the next.

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
