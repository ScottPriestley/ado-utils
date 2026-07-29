# Azure DevOps Dashboard Migration

Four PowerShell scripts that move team dashboards — and the Shared Queries they depend on — from one Azure DevOps project to another, including across organizations.

The normal flow is **1 → 2 → 3**. Step 4 is a **conditional repair** — run it only when step 2 skips queries because the target is missing Area or Iteration paths, then re-run step 2 before step 3.

| Step | Script | When to run |
| --- | --- | --- |
| 1 | `01-export-dashboards.ps1` | First (read-only on source). Can run early — even before target setup — to review `inventory.md`. |
| 2 | `02-migrate-queries.ps1` | After [process WIT migration](../ado-migrate-workitemtype/README.md) and [area/iteration hierarchy](../ado-import-area-paths/README.md) are in place on the target. |
| 3 | `03-import-dashboards.ps1` | After step 2 produces a usable `querymap.json`. |
| 4 | `04-create-classification-nodes.ps1` | **Optional repair only.** When step 2 skips queries for missing paths and you did not already load the full hierarchy via `ado-migrate-area-paths` / `ado-migrate-iterations`. Re-run step 2 after step 4, then run step 3. |

`_common.ps1` holds shared helpers (auth header prompt/cache, retrying `Invoke-Ado`, GUID extraction, UTF-8 file I/O, org-name normalization) and is dot-sourced by each numbered script — it is not run directly.

## Where this fits in a full project migration

When standing up a target project from a source, run the [root migration playbook](../README.md#typical-migration-playbook) phases in order:

1. **Process** — migrate custom work item types (`ado-migrate-workitemtype`).
2. **Structure** — load the full area and iteration hierarchies (`ado-migrate-area-paths`, `ado-migrate-iterations`, or the CSV/Excel import scripts).
3. **Dashboards** — this folder (steps 1 → 2 → 3; step 4 only if needed).
4. **Wiki** — migrate page content last (`ado-migrate-wiki`).

Step 2 here fails or skips queries when phase 1 or 2 was incomplete. Running step 4 instead of phase 2 creates only the paths referenced in exported WIQL — not the full project tree — and does not set iteration sprint dates.

## Prerequisites

- PowerShell 7+ (or Windows PowerShell 5.1).
- Source PAT with **Work Items (Read)** and **Team Dashboards (Read)**.
- Target PAT with **Work Items (Read & Write)** and **Team Dashboards Manage**.
- **Target project ready for step 2:** custom work item types and area/iteration hierarchies migrated before recreating queries (see [Where this fits](#where-this-fits-in-a-full-project-migration)).
- Marketplace extension widgets used on the source dashboards must be installed in the target org before step 3 (step 1's inventory lists these).

## Authentication

Each script reads its PAT from an environment variable and prompts (securely, then caches it for the rest of the session) if it isn't already set:

```powershell
$env:ADO_SOURCE_PAT = '<source PAT>'   # used by step 1
$env:ADO_TARGET_PAT = '<target PAT>'   # used by steps 2, 3, 4
```

## Recommended sequence

```text
[Prerequisites on target: WIT migration + full area/iteration hierarchy]

01-export-dashboards          (read-only; can run earlier)
        ↓
02-migrate-queries
        ↓
   ┌────┴──── queries skipped for missing paths?
   │ no                          yes
   ↓                               ↓
03-import-dashboards     04-create-classification-nodes
                                   ↓
                         02-migrate-queries (re-run)
                                   ↓
                         03-import-dashboards
```

## Quick start

**Prerequisites on the target** (before step 2): custom work item types migrated and area/iteration hierarchies loaded. See the [root playbook](../README.md#typical-migration-playbook).

```powershell
# 1) Export from the source project (read-only)
.\01-export-dashboards.ps1 -Org 'source-org' -Project 'Source Project' -OutDir '.\export'

# Review .\export\inventory.md before continuing — it flags marketplace widgets,
# Test Plan/Suite charts, and any query GUIDs that could not be resolved.

# 2) Recreate the referenced queries in the target project
.\02-migrate-queries.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir '.\export'

# If step 2 skipped queries for missing Area/Iteration paths (see summary output
# and queries-skipped.txt), run step 4 and re-run step 2 before continuing:
#   .\04-create-classification-nodes.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir '.\export'
#   .\02-migrate-queries.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir '.\export'
# Prefer ado-migrate-area-paths / ado-migrate-iterations when copying a full project
# hierarchy — step 4 is a narrow WIQL-based repair, not a full tree migration.

# 3) Create the dashboards on the target team
.\03-import-dashboards.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -TargetTeam 'Target Team' -ExportDir '.\export'
```

### Repair path (step 4)

Use only when step 2 reports path-related skips and you have not already loaded the full hierarchy:

```powershell
.\04-create-classification-nodes.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir '.\export'
.\02-migrate-queries.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir '.\export'
.\03-import-dashboards.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -TargetTeam 'Target Team' -ExportDir '.\export'
```

## Step 1 — Export dashboards

```powershell
.\01-export-dashboards.ps1 -Org <org> -Project <project> [-OutDir '.\export']
```

- Walks every team in the source project, exports each dashboard's raw JSON to `<OutDir>/dashboards/`, and collects every GUID referenced in widget settings.
- Resolves each GUID against the source project's queries. If a widget's stored query GUID has drifted (the query was rebuilt, or dashboards were copied from another project), it recovers the query by matching the widget's embedded query name against the live Shared Queries tree and records the dead GUID as an alias.
- Writes:
  - `queries.json` — every referenced query, with folder path and WIQL.
  - `mapping.json` — a template for step 3: source org/project/team IDs, plus placeholder fields (`targetOrg`, `targetProjectName`, `teamMap[].targetTeamName`, `extraGuidMap`) to fill in if you want explicit team-name or GUID overrides. Left blank, step 3 falls back to `-TargetTeam` for every dashboard.
  - `inventory.md` — **read this before running step 2.** Lists dashboard/widget counts, marketplace-extension widgets to install in the target org, recovered (name-matched) queries, ambiguous name matches needing manual resolution, Test Plan/Suite chart widgets (migrated separately, not as queries), and any GUIDs that could not be resolved at all.

## Step 2 — Migrate queries

```powershell
.\02-migrate-queries.ps1 -TargetOrg <org> -TargetProject <project> [-ExportDir 'export'] [-QueryFolderName ''] [-SourceProjectName '']
```

- Reads `queries.json` (and `mapping.json` for the source project name, unless `-SourceProjectName` is passed explicitly).
- Recreates each query under **Shared Queries** in the target project, preserving the source folder structure by default. Pass `-QueryFolderName` to nest everything under one extra wrapper folder instead.
- Rewrites literal occurrences of the source project name in WIQL to the target project name. Queries that filter on `[System.AreaPath]` or `[System.IterationPath]` are flagged in the summary — they return 0 results in the target until those paths exist there. Load the full hierarchy with [ado-migrate-area-paths](../ado-import-area-paths/README.md) / [ado-migrate-iterations](../ado-import-iterations/README.md) before step 2 when possible; use step 4 only as a repair for path-related skips.
- **Idempotent.** A query that already exists at the target path has its existing ID reused rather than erroring; queries whose WIQL references a field/type/state the target process doesn't have are skipped with a reason (also written to `queries-skipped.txt`); anything else that fails is reported separately since a re-run may resolve it (often transient throttling).
- Writes `querymap.json` (source query GUID → target query GUID, including drifted aliases from step 1) for step 3 to consume.

## Step 3 — Import dashboards

```powershell
.\03-import-dashboards.ps1 -TargetOrg <org> -TargetProject <project> -TargetTeam <team> [-ExportDir '.\export'] [-NameSuffix '']
```

- Requires `mapping.json`, `querymap.json`, and the `dashboards/` folder from steps 1–2.
- Builds a substitution table (source org URL, source project ID/name, every query GUID, every mapped team GUID, plus any `extraGuidMap` entries from `mapping.json`) and rewrites every widget's `settings` text before creating the dashboard.
- Each dashboard is created under the team named in `mapping.json`'s `teamMap` for its source team, falling back to `-TargetTeam`.
- **A dashboard with the same name already on the target team is skipped** (delete it in the UI first to re-import, or pass `-NameSuffix` to import alongside it instead).
- After substitution, any GUID still present in a widget's settings that isn't a known target ID is flagged as an unmapped reference (Test Plan/Suite chart widgets are called out separately, since their IDs are plan/suite/transform IDs, not queries). Extension-contributed widgets are flagged as a reminder to confirm the extension is installed in the target org. All flags are written to `import-flags.txt`.

## Step 4 — Create classification nodes (conditional repair)

```powershell
.\04-create-classification-nodes.ps1 -TargetOrg <org> -TargetProject <project> [-ExportDir '.\export'] [-SourceProjectName ''] [-WhatIfOnly]
```

Run this **before re-running step 2** — never after step 3 — when queries were skipped because the target project is missing an Area or Iteration path they filter on.

**Not a substitute for full hierarchy migration.** Step 4 only creates paths found as literals in exported query WIQL. It does not copy the source project's complete area/iteration tree and does not set iteration sprint dates. When copying project structure from a source project, use `ado-migrate-area-paths.ps1` and `ado-migrate-iterations.ps1` in phase 2 of the [root playbook](../README.md#typical-migration-playbook) instead.

- Extracts every `[System.AreaPath]` / `[System.IterationPath]` literal out of `queries.json`'s WIQL, strips the source project root, and creates the equivalent nodes under the target project — parent paths first.
- Paths whose root doesn't match the source or target project name (cross-project references, e.g. a shared sandbox project) are reported, not created.
- Idempotent — existing nodes are left as-is. Use `-WhatIfOnly` to preview without creating anything.
- Only creates the classification nodes; it does not add work items, set iteration dates, or touch anything else.

## Output artifacts

Everything is written under `-OutDir` (step 1) / `-ExportDir` (steps 2–4), default `./export`:

```text
export/
|-- dashboards/*.json       # raw dashboard payloads (step 1)
|-- queries.json             # referenced queries (step 1)
|-- mapping.json             # org/project/team map, edit as needed (step 1, consumed by 3)
|-- inventory.md             # export review report (step 1)
|-- querymap.json            # source -> target query GUID map (step 2, consumed by 3)
|-- queries-skipped.txt      # queries skipped for process mismatch (step 2)
`-- import-flags.txt         # widgets needing manual follow-up (step 3)
```

Treat these as potentially sensitive project data (query WIQL, dashboard names, and team/project GUIDs).

## Notes

- All four scripts accept the organization as a bare name (`contoso`) or a full URL (`https://dev.azure.com/contoso` or `https://contoso.visualstudio.com`).
- `Invoke-Ado` in `_common.ps1` retries transient failures (429 throttling, 5xx, and Azure DevOps circuit-breaker errors) with exponential backoff before giving up.
- Re-running any step is safe: creates are idempotent, and existing target items are detected and reused rather than duplicated.
