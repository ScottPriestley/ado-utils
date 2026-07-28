# Azure DevOps Dashboard Migration

Four PowerShell scripts that move team dashboards — and the Shared Queries they depend on — from one Azure DevOps project to another, including across organizations. Run in order; each step's output feeds the next.

| Step | Script | Purpose |
| --- | --- | --- |
| 1 | `01-export-dashboards.ps1` | Export every dashboard and widget from the source project, resolve which GUIDs in widget settings are work item queries, and produce a human-readable inventory. |
| 2 | `02-migrate-queries.ps1` | Recreate the referenced queries in the target project's Shared Queries and record a source-GUID → target-GUID map. |
| 3 | `03-import-dashboards.ps1` | Rewrite widget settings (query GUIDs, project/team GUIDs, org URLs) and create the dashboards on the target team. |
| 4 | `04-create-classification-nodes.ps1` | Optional. Create the Area/Iteration nodes that migrated queries reference, then re-run step 2 to pick up queries that were skipped for a missing path. |

`_common.ps1` holds shared helpers (auth header prompt/cache, retrying `Invoke-Ado`, GUID extraction, UTF-8 file I/O, org-name normalization) and is dot-sourced by each numbered script — it is not run directly.

## Prerequisites

- PowerShell 7+ (or Windows PowerShell 5.1).
- Source PAT with **Work Items (Read)** and **Team Dashboards (Read)**.
- Target PAT with **Work Items (Read & Write)** and **Team Dashboards Manage**.
- Marketplace extension widgets used on the source dashboards must be installed in the target org before import (step 1's inventory lists these).

## Authentication

Each script reads its PAT from an environment variable and prompts (securely, then caches it for the rest of the session) if it isn't already set:

```powershell
$env:ADO_SOURCE_PAT = '<source PAT>'   # used by step 1
$env:ADO_TARGET_PAT = '<target PAT>'   # used by steps 2, 3, 4
```

## Quick start

```powershell
# 1) Export from the source project
.\01-export-dashboards.ps1 -Org 'source-org' -Project 'Source Project' -OutDir '.\export'

# Review .\export\inventory.md before continuing — it flags marketplace widgets,
# Test Plan/Suite charts, and any query GUIDs that could not be resolved.

# 2) Recreate the referenced queries in the target project
.\02-migrate-queries.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir '.\export'

# 3) Create the dashboards on the target team
.\03-import-dashboards.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -TargetTeam 'Target Team' -ExportDir '.\export'
```

If step 2 skips queries because an Area/Iteration path referenced in their WIQL doesn't exist in the target project, run step 4 and then re-run step 2:

```powershell
.\04-create-classification-nodes.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir '.\export'
.\02-migrate-queries.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir '.\export'
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
- Rewrites literal occurrences of the source project name in WIQL to the target project name. Queries that filter on `[System.AreaPath]` or `[System.IterationPath]` are flagged in the summary — they'll return 0 results in the target until those paths exist there (see step 4).
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

## Step 4 — Create classification nodes (optional)

```powershell
.\04-create-classification-nodes.ps1 -TargetOrg <org> -TargetProject <project> [-ExportDir '.\export'] [-SourceProjectName ''] [-WhatIfOnly]
```

Run this **before re-running step 2** when queries were skipped because the target project is missing an Area or Iteration path they filter on.

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
