# ADO Dashboard Migration — Repeatable Process

**Purpose:** Migrate Azure DevOps dashboards (and the queries they depend on) from one organization/project to another via REST API.
**First use case:** `dev.azure.com/360sg / AEC Model Combo Project` → `dev.azure.com/HSOUSCloud / Internal Hub`
**Owner:** Scott Priestley
**Status:** Process designed; scripts ready for pilot run on one dashboard.

---

## 1. Background

- There is no built-in cross-organization dashboard copy. The native **Copy Dashboard** feature (ADO 2022.1+) only works within the same org.
- The Dashboards REST API fully supports read *and* create of dashboards and widgets, so migration is a data-plumbing problem, not a platform limitation. 
- Risks: a dashboard is a thin shell. Each widget carries a `settings` JSON blob full of environment-specific identifiers — query GUIDs, project GUID, team GUIDs, build definition IDs, repo IDs, org URLs. Copy those verbatim and every widget renders broken. The real work is **dependency migration + identifier remapping**.

## 2. Architecture of the process

```
SOURCE ORG                                    TARGET ORG
┌──────────────┐   01-export    ┌─────────┐   02-migrate-queries   ┌──────────────┐
│ Dashboards   │ ─────────────► │ export/ │ ─────────────────────► │ Shared       │
│ + widgets    │                │ JSON +  │        builds          │ Queries      │
│ + queries    │                │inventory│       querymap.json    │ (recreated)  │
└──────────────┘                └─────────┘                        └──────────────┘
                                     │          03-import               │
                                     └───── remap GUIDs, rewrite ───────┤
                                            settings, POST dashboards   ▼
                                                                   ┌──────────────┐
                                                                   │ Dashboards   │
                                                                   │ + widgets    │
                                                                   └──────────────┘
```

Three scripts, run in order. Each is idempotent enough to re-run after fixing issues.

| Step | Script                             | What it does                                                                                                                                                                                                                                                |
| ---- | ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | `scripts/01-export-dashboards.ps1` | Reads every team's dashboards from the source, saves raw JSON, extracts every GUID found in widget settings, resolves which are work item queries, exports those queries (name, folder path, WIQL). Produces `inventory.md` — the go/no-go review artifact. |
| 2    | `scripts/02-migrate-queries.ps1`   | Recreates the referenced queries in the target's Shared Queries (under one migration folder), rewrites WIQL project references, and writes `querymap.json` (source query GUID → target query GUID).                                                         |
| 3    | `scripts/03-import-dashboards.ps1` | Rewrites each widget's settings using `querymap.json` + `mapping.json` (project GUID, team IDs, org URL, anything else), then creates the dashboards in the target team via POST. Reports any widget that still contains unmapped source GUIDs.             |

## 3. Prerequisites

| Item          | Detail                                                                                                                                                                                                                        |
| ------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Source access | Account in the `360sg` org with read access to the project. PAT scopes: **Work Items (Read)**, **Team Dashboards (Read)**, Project & Team (Read). A read-only PAT is sufficient.                                              |
| Target access | Account in `HSOUSCloud` with **Team Administrator** (or dashboard edit) on the target team in Internal Hub. PAT scopes: **Work Items (Read & Write)**, **Team Dashboards (Manage)**.                                          |
| PAT handling  | PATs are read from environment variables (`ADO_SOURCE_PAT`, `ADO_TARGET_PAT`) at runtime. Never stored in files, never passed on the command line, never committed.                                                           |
| Extensions    | Any widget whose `contributionId` does not start with `ms.` comes from a Marketplace extension. That extension must be installed in the target org **before** import, or those widgets fail. The inventory report lists them. |
| PowerShell    | PowerShell 7+. No modules required (plain `Invoke-RestMethod`).                                                                                                                                                               |

## 4. Runbook

```powershell
# 0. Set PATs for this session only
$env:ADO_SOURCE_PAT = "<source read PAT>"     # you type these yourself; don't script them
$env:ADO_TARGET_PAT = "<target manage PAT>"

# 1. Export + inventory
./scripts/01-export-dashboards.ps1 -Org "360sg" -Project "AEC Model Combo Project" -OutDir ./export

#    >>> STOP. Read export/inventory.md. Decide:
#    - Which dashboards are in scope (edit dashboards list or just delete unwanted JSON files)
#    - Which extensions need installing in HSOUSCloud
#    - Whether any widgets reference builds/repos/pipelines that won't exist in the target

# 2. Recreate queries in target
./scripts/02-migrate-queries.ps1 -TargetOrg "HSOUSCloud" -TargetProject "Internal Hub" `
    -ExportDir ./export -QueryFolderName "Migrated - AEC Model Combo"

#    >>> Review export/querymap.json and any WIQL warnings (area/iteration paths that
#        don't exist in the target will make queries return zero results, not fail).

# 3. Fill in export/mapping.json (created as a template by step 1), then import
./scripts/03-import-dashboards.ps1 -TargetOrg "HSOUSCloud" -TargetProject "Internal Hub" `
    -TargetTeam "Internal Hub Team" -ExportDir ./export

# 4. Validate (see checklist below)
```

**Pilot first.** On the first run, delete all but one representative dashboard's JSON from `export/dashboards/` after step 1, run steps 2–3 for that one, validate, then re-run for the rest.

## 5. What maps automatically vs. what needs a human

| Reference inside widget settings                                            | Handling                                                                                                                                                                               |
| --------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Work item query GUIDs (query tile, chart, query results widgets)            | **Automatic** — queries are recreated and remapped via `querymap.json`.                                                                                                                |
| Project GUID / project name / org URL                                       | **Automatic** — from `mapping.json`.                                                                                                                                                   |
| Team GUIDs (burndown, velocity, cycle/lead time, sprint widgets)            | **Semi-automatic** — you declare source-team → target-team pairs in `mapping.json`; script remaps.                                                                                     |
| Build definition IDs, release IDs, repo IDs (build/deployment/code widgets) | **Manual** — pipelines and repos generally aren't being migrated. The import flags these widgets; recreate or delete them by hand in the target.                                       |
| Markdown widgets pointing at repo file paths                                | **Manual** — flagged; fix the path or convert to inline markdown.                                                                                                                      |
| Extension widgets (non-`ms.` contributionId)                                | **Manual gate** — install extension first; settings usually copy clean after that.                                                                                                     |
| Analytics history (burndown history, velocity history)                      | **Not migratable** — these widgets render from the target org's own Analytics data. The widget config migrates; the historical data does not and cannot. Set expectations accordingly. |

## 6. Validation checklist (per dashboard)

- [ ] Widget count matches source (import script reports both).
- [ ] Open source and target side by side; layout/positions match.
- [ ] Every query-based widget renders numbers (a rendering widget with a count of 0 may mean the WIQL's area/iteration path doesn't exist in target — check the query).
- [ ] No "Widget failed to load" / "Configure widget" tiles. Each one traces to an unmapped reference — check the import script's flag report.
- [ ] Queries landed under `Shared Queries/Migrated - AEC Model Combo/` and are readable by the team.

## 7. Risks and limitations

- **Process/schema mismatch.** If the two projects use different process templates (e.g., source is Agile, target is CMMI or a custom process), WIQL referencing missing work item types, states, or fields will error or return nothing. The query migration script flags non-portable field references but can't fix semantic differences — that's an analyst decision.
- **Widget settings are an undocumented contract.** Microsoft doesn't document the internal settings schema per widget; it can change. The remap is string-level GUID substitution, which is exactly what the third-party tools do, but a new widget version could move a reference somewhere unexpected. Mitigation: the import flags any residual source GUIDs.
- **Permissions don't migrate.** Target dashboard visibility follows the target team's membership.
- **eTag concurrency.** The API versions widget lists with eTags. The scripts create dashboards with widgets in a single POST to avoid eTag juggling; if you later script *updates* to existing dashboards, you must fetch and pass eTags.
- **This process covers dashboards + queries only.** Work items, pipelines, repos, wikis are out of scope (that's Azure DevOps Migration Tools territory).
