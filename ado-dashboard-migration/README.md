# Azure DevOps Dashboard Migration

Four ordered PowerShell scripts that move team dashboards from one Azure DevOps organization/project to another: export from source, recreate the Shared Queries the dashboards depend on, import the dashboards into the target, and (only if needed) patch in missing Area/Iteration nodes that the exported queries reference.

## Using the tool

**What it does:** Copies team dashboards — the widgets, their settings, and the Shared Queries they point to — from a source project to a target project. It does this in four steps, run in order, because dashboards depend on queries, and queries depend on Area/Iteration paths existing in the target.

**When you'd use it:** You're standing up a new Azure DevOps project (a reorg, a tenant move, a template rollout) and want the team's existing dashboards to show up in the new project instead of being rebuilt widget-by-widget by hand.

**The four steps, in plain language:**

1. **Export** — connects to the source project (read-only) and pulls down every team's dashboards, the widgets on them, and the Shared Queries those widgets use. Nothing in the source is changed.
2. **Migrate queries** — recreates the Shared Query folders and queries in the target project, and keeps a record of which target query now corresponds to which source query.
3. **Import dashboards** — creates the dashboards in the target project, rewriting the IDs and URLs inside each widget so they point at the target's queries, teams, and project instead of the source's.
4. **Create classification nodes** (only run this if step 2 tells you queries were skipped because an Area or Iteration path is missing in the target) — creates just the specific missing Area/Iteration nodes that the exported queries mention, then you re-run step 2.

**What to have ready before starting:**

- The source organization name/URL and project name, plus the target organization name/URL and project name.
- A Personal Access Token (PAT) for the source with read access to work items and team dashboards.
- A PAT for the target with read/write access to work items and manage access to team dashboards (step 4 also needs permission to create classification nodes).
- In the target project ahead of time: the same work item types/fields/states as the source, and the Area/Iteration hierarchy already built out (this tool does not create a full hierarchy — see step 4's narrow exception above).
- Any marketplace extensions the dashboards' widgets depend on, installed in the target organization before you run step 3.

**How to run it:**

```powershell
./01-export-dashboards.ps1 -Org 'source-org' -Project 'Source Project' -OutDir './export'
# Review ./export/inventory.md before continuing.
./02-migrate-queries.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir './export'
./03-import-dashboards.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -TargetTeam 'Target Team' -ExportDir './export'
```

If step 2 reports skipped queries because of a missing Area/Iteration path, run step 4 and then re-run step 2 before moving on to step 3:

```powershell
./04-create-classification-nodes.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir './export' -WhatIfOnly
./04-create-classification-nodes.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir './export'
./02-migrate-queries.ps1 -TargetOrg 'target-org' -TargetProject 'Target Project' -ExportDir './export'
```

**What to expect as output:** A local `export` folder containing everything the scripts pulled from the source and everything they need to drive the import — including an `inventory.md` summary you should read after step 1, and flag files listing anything skipped or left unresolved after steps 2 and 3. Each script also writes its own run log. The dashboards themselves land in the target project's UI once step 3 finishes.

**What it will NOT do:**

- It will not copy dashboard permissions, or install/configure marketplace extensions for you.
- It will not migrate Test Plans/Suites objects or the charts tied to them.
- It will not build out a full Area/Iteration hierarchy — only the exact nodes literally referenced in exported queries (step 4), and only as a fallback.
- It will not overwrite or delete an existing dashboard with the same name in the target team — it skips it (you can use a name suffix to create a second copy alongside it instead).
- It does not guarantee every widget will render correctly afterward — some extension-specific settings may need manual touch-up, and you should open the target dashboards and check them yourself.

## Technical reference

### Scripts, capabilities, and exclusions

| Step | Script | Capability | Exclusions |
| --- | --- | --- | --- |
| 1 | `01-export-dashboards.ps1` | Read-only export of team dashboards, widget references, query definitions, mapping template, and inventory. | Does not export extension packages or Test Plan/Suite objects. |
| 2 | `02-migrate-queries.ps1` | Recreates query folders/queries and writes source→target query GUID mappings. | Does not create missing WITs, fields, states, or a full classification tree. |
| 3 | `03-import-dashboards.ps1` | Rewrites known IDs/URLs in widget settings and creates dashboards on mapped teams. | Does not resolve every extension-specific or Test Plan/Suite identifier. |
| 4 | `04-create-classification-nodes.ps1` | Creates only missing Area/Iteration nodes literally referenced in exported WIQL. | Not a full hierarchy migration; does not set iteration dates. |

The normal path is 1 → 2 → 3. Run step 4 only after path-related step-2 skips, then rerun step 2 before step 3. `_common.ps1` is a dot-sourced helper, not an entry script.

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source: Work Items Read and Team Dashboards Read.
- Target: Work Items Read & write and Team Dashboards Manage.
- Target WITs/fields/states and full Area/Iteration hierarchy prepared before step 2 where applicable.
- Marketplace extensions installed in the target organization before step 3.

### Authentication and minimum PAT scopes

Step 1 uses `SourcePat` → `ADO_SOURCE_PAT` → hidden source-PAT prompt. Steps 2–4 use `TargetPat` → `ADO_TARGET_PAT` → hidden target-PAT prompt. `-NonInteractive` fails instead of prompting. The exact PAT prompts are `Source Azure DevOps PAT (input hidden)` and `Target Azure DevOps PAT (input hidden)`. Organization/project arguments are mandatory for these scripts, so no organization URL prompt is used. PATs are not cached or written to an environment variable.

Use source Work Items/Team Dashboards Read and target Work Items Read & write/Team Dashboards Manage; step 4 needs permission to create classification nodes.

### Safety and rerun behavior

Step 1 is read-only against Azure DevOps but replaces its named export artifacts in `OutDir`. Step 2 reuses queries found at the target path and records skips/failures. Step 3 skips a dashboard with the same target-team name; use `NameSuffix` to create alongside it. Step 4 reads before creating and reads back each created node. None of these scripts deletes anything.

`WhatIfOnly` is the step-4 preview switch. Steps 1–3 do not offer a remote dry run. Do not interpret a rerun as complete equivalence: existing dashboards are skipped without widget comparison, and extension-specific settings can need manual repair.

### Parameters and precedence

| Script | Parameters |
| --- | --- |
| Step 1 | `Org`, `Project`, `OutDir` (default `./export`), `SourcePat`, `LogDirectory`, `NonInteractive`. |
| Step 2 | `TargetOrg`, `TargetProject`, `ExportDir` (default `export`), `QueryFolderName`, `SourceProjectName`, `TargetPat`, common logging switches. Blank source project is read from `mapping.json`; explicit value wins. |
| Step 3 | `TargetOrg`, `TargetProject`, `TargetTeam`, `ExportDir` (default `./export`), `NameSuffix`, `TargetPat`, common logging switches. `teamMap` target names take precedence; `TargetTeam` is fallback. |
| Step 4 | `TargetOrg`, `TargetProject`, `ExportDir` (default `./export`), `SourceProjectName`, `WhatIfOnly`, `TargetPat`, common logging switches. Blank source project is read from `mapping.json`. |

All PATs follow SecureString → environment → prompt. `LogDirectory` defaults to `logs` beside the current entry script.

### Input formats

Step 1 accepts organization names/full Azure DevOps URLs and a project name/ID. It writes the exact JSON inputs consumed later. Step 2 requires `queries.json`; step 3 requires `mapping.json`, `querymap.json`, `dashboard-files.json` when present (otherwise `dashboards/*.json`), and dashboard JSON; step 4 requires `queries.json` and usually `mapping.json`.

`mapping.json` holds source project/team identity, optional `targetOrg`, `targetProjectName`, `teamMap[].targetTeamName`, and `extraGuidMap`. GUID maps must be valid GUID→GUID pairs. Treat the generated files as the schema source; do not invent IDs.

### Outputs and logs

The shared run contract writes UTF-8-without-BOM JSONL files named `<script-base>-success log-<run-id>.jsonl` and `<script-base>-error log-<run-id>.jsonl`, under `LogDirectory` or `logs` beside each script. Every record contains `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; sensitive authorization values are redacted.

Workflow artifacts under `OutDir`/`ExportDir`:

```text
export/
|-- dashboards/*.json
|-- dashboard-files.json
|-- queries.json
|-- mapping.json
|-- inventory.md
|-- querymap.json
|-- queries-skipped.txt
`-- import-flags.txt
```

`inventory.md` is generated by step 1; there is no separate iteration workbook generated or promised by this workflow.

### Detailed workflow and behavior

Step 1 walks source teams/dashboards, writes raw dashboard records, extracts widget GUIDs, resolves live Shared Queries, and can recover drifted query IDs by unambiguous embedded-name matching. `inventory.md` flags unresolved/ambiguous references, marketplace widgets, and Test Plan/Suite charts. Review it before writes.

Step 2 recreates parent folders, rewrites literal source-project occurrences in WIQL, reuses a query already at the path, skips known target-process/path incompatibilities with reasons, and writes `querymap.json` including recovered aliases. A zero-result query is not proof that its classification paths exist.

Step 3 validates mapping identity, builds substitutions for source URL/project/team/query GUIDs plus `extraGuidMap`, rewrites widget settings text, selects the mapped target team, and creates only absent dashboard names. Remaining unknown GUIDs and extension/test references are written to `import-flags.txt`.

Step 4 parses AreaPath/IterationPath literals from WIQL, rejects cross-project roots, checks nodes before writes, creates missing nodes parent-first unless `WhatIfOnly`, and freshly GETs each created node. Preview reports proposed nodes and records a preview outcome; it does not claim post-write verification.

### Verification checklist

- Run both offline commands from the repository root.
- Confirm `inventory.md` has no unexplained unresolved or ambiguous query references.
- Confirm `querymap.json` covers every query expected by imported widgets.
- Review `queries-skipped.txt` and `import-flags.txt` even when the scripts succeed.
- Open representative target queries and dashboards; confirm widget rendering and target teams manually.
- For step 4, compare only the literal paths it reports; it does not verify a complete source hierarchy or sprint dates.

Offline checks use local assertions/mocks and make no live Azure DevOps calls.

### Troubleshooting

- Missing process field/type/state: migrate the inherited-process content, then rerun step 2.
- Missing Area/Iteration literal: prefer the full [Area](../ado-import-area-paths/README.md) and [Iteration](../ado-import-iterations/README.md) workflows; otherwise use step 4 and rerun step 2.
- Mapping mismatch: correct `mapping.json` or pass matching target arguments.
- Empty/invalid `querymap.json`: rerun step 2 after resolving its skip/failure report.
- Existing dashboard: it is intentionally skipped; inspect it or use a suffix.
- Unknown widget GUID/extension: install/configure the extension or map the external Test Management object manually.

### Limitations

The workflow does not migrate dashboard permissions, extension installation/configuration, Test Plans/Suites, a complete classification tree, iteration dates, or guaranteed widget rendering. Query reuse and dashboard-name skip checks are not full content equivalence checks. No live validation is claimed by the repository's offline suite.

### Security

Use short-lived least-privilege PATs and protect the export directory: dashboard settings, WIQL, organization/project/team names, and GUIDs can be sensitive. Do not add PATs to `mapping.json`, shell history, logs, or source control.

### Related workflows

Prepare [work item types](../ado-migrate-workitemtype/README.md), then [Area Paths](../ado-import-area-paths/README.md) and [Iteration Paths](../ado-import-iterations/README.md), before dashboard step 2. The [root README](../README.md) describes the full ordering; wiki migration normally follows dashboards.
