# Azure DevOps Query Work Item Copy

`ado-copy-query-workitems.ps1` copies one saved Azure DevOps query, the work items returned by that query, supported fields, and supported query relationships into a target project. The workflow is additive and stateful; it is a focused copy tool, not a complete project clone.

## Using the tool

**What it does:** Takes one saved Azure DevOps query, copies the query itself into the target project, runs it, and copies the work items it returns — along with their supported fields and relationships — into the target project as new (or updated) work items.

**When to use it:** You want a specific, deliberately-scoped set of work items moved to a target project — for example, "everything in this release" or "all open bugs matching this filter" — rather than the whole project. If you want to copy an entire project's work items instead of a query's results, use `ado-copy-all-workitems` instead (see that tool's README).

**What it will NOT do:** It does not copy history, comments, attachments, identities (who's assigned, who created what), permissions, or every possible field or relationship type — some relationship types and external links are intentionally out of scope. It's not a full-fidelity clone and there's no rollback.

**Before you start, have ready:**
- The URL of the saved query in the source project (you can copy this straight from the browser address bar when viewing the query in Azure DevOps).
- The target project URL.
- A PAT for the source org with **Work Items (Read)** access.
- A PAT for the target org with **Work Items (Read & write)** access.
- The target project's process, work item types, fields, and Area/Iteration paths should already be set up for anything the copied items will need.

**How to run it:**

1. Open PowerShell in the repo folder (or in this tool's subfolder).
2. Run the script, pointing it at the source query and target project:

```powershell
./ado-copy-query-workitems/ado-copy-query-workitems.ps1 `
  -SourceQueryUrl 'https://dev.azure.com/source/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -TargetProjectUrl 'https://dev.azure.com/target/Project' `
  -LogDirectory './run-logs'
```

3. You'll be prompted for your source and target PATs if you didn't pass them in.
4. If it fails partway or you need to run it again, just rerun the same command — it keeps track of what it already copied and won't create duplicates. Keep the state file it produces alongside that run; don't reuse a state file from a different query.

**What to expect afterward:**
- A summary printed at the end of the run.
- A small state file tracking which source items map to which target items (this is what makes reruns safe).
- A log folder with a success log and an error log.
- If some items or relationships couldn't be copied, a separate failures file listing exactly what didn't make it over, so you can review and decide what to do about it. This isn't unusual on a first run — it typically points to a target field, path, or work item type that needs to be set up first.

There's no preview/dry-run mode for this tool — running it does the copy.

## Technical reference

### Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-copy-query-workitems.ps1` | Validates source query and target project URLs, copies the saved query into a target folder, runs the source query, creates or updates mapped target work items, and recreates supported relationships. | Does not migrate history, attachments, identities, every field type, external relations, permissions, or target project configuration. |

Classification paths are rewritten to the target project root unless `-PreserveClassificationPaths` is supplied.

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source project access to the saved query and returned work items.
- Target project access to create queries and work items.
- Source Work Items Read scope; target Work Items Read & write scope.
- Target process, work item types, fields, and classification paths prepared where the copied items depend on them.

### Authentication and minimum PAT scopes

`SourcePat` resolves from SecureString parameter -> `ADO_SOURCE_PAT` -> hidden prompt `Source Azure DevOps PAT (input hidden)`. `TargetPat` uses `ADO_TARGET_PAT` and `Target Azure DevOps PAT (input hidden)`. `-NonInteractive` fails for missing credentials instead of prompting. PATs are registered for log redaction and are never written to state or environment variables.

Minimum scopes are Work Items Read for source and Work Items Read & write for target. Azure DevOps project permissions can still block a scoped PAT.

### Safety and rerun behavior

The script does not delete anything. It saves source-to-target work item IDs in `StatePath` after successful item creation and reuses those IDs on rerun. A recorded target work item can be patched with the current supported source fields. Query folders are created as needed, identical queries are reused, and differing target query content may be patched by this workflow.

Individual item or relation failures are collected in a failure summary and cause a terminating partial-failure result. Keep the state file with the run; do not mix it with another source query.

There is no `-WhatIf` or remote dry run.

### Quick start

From the repository root:

```powershell
./ado-copy-query-workitems/ado-copy-query-workitems.ps1 `
  -SourceQueryUrl 'https://dev.azure.com/source/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -TargetProjectUrl 'https://dev.azure.com/target/Project' `
  -SourcePat $sourcePat `
  -TargetPat $targetPat `
  -LogDirectory './run-logs' `
  -NonInteractive
```

From this folder:

```powershell
./ado-copy-query-workitems.ps1 `
  -SourceQueryUrl 'https://dev.azure.com/source/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -TargetProjectUrl 'https://dev.azure.com/target/Project' `
  -SourcePat $sourcePat -TargetPat $targetPat
```

### Parameters and precedence

| Parameter | Description |
| --- | --- |
| `SourceQueryUrl` | Saved query URL. Prompts as `Source Query URL` when omitted. |
| `TargetProjectUrl` | Target project URL. Prompts as `Target Project URL` when omitted. |
| `QueryFolder` | Target root folder for the copied query; default `Shared Queries`. |
| `SourcePat` / `TargetPat` | Role-specific `SecureString` PATs. |
| `StatePath` | Source-to-target ID state file; default `ado-copy-query-workitems.state.json` beside the script. |
| `LogPath` | Optional legacy text log path. |
| `PreserveClassificationPaths` | Keeps source Area/Iteration paths instead of rewriting them to the target project root. |
| `LogDirectory` | Shared JSONL log directory; defaults to `logs` beside the script. |
| `NonInteractive` | Rejects every missing interactive input. |

PAT precedence is SecureString parameter -> environment variable -> hidden prompt. Non-secret inputs use parameter -> prompt.

### Input formats

`SourceQueryUrl` must look like `https://dev.azure.com/{org}/{project}/_queries/query/{guid}/`. `TargetProjectUrl` must identify `https://dev.azure.com/{org}/{project}`. Both project names may be URL-encoded. Query results can be flat, tree, or relationship shaped; unsupported relationship recreation is skipped or summarized according to the script's failure handling.

### Outputs and logs

The state file records source work item IDs to target IDs. On partial failures, a `*.failures.json` summary is written next to the state/log output. The script also prints a final JSON summary.

Every run creates UTF-8-without-BOM JSONL files named `ado-copy-query-workitems-success log-<run-id>.jsonl` and `ado-copy-query-workitems-error log-<run-id>.jsonl` in `LogDirectory` or local `logs`. Each record contains `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; secrets are redacted.

### Detailed workflow and behavior

The script validates URLs, resolves source and target project identity, loads state, reads source query metadata/WIQL, creates any missing target query folders, and creates or updates the target query. It executes the source query, reads returned work items in batches, copies supported fields into target work items, records mappings immediately, and then attempts supported relation recreation between mapped items.

Field copying favors fields present in the target process and skips unsupported/system fields. Classification values are rewritten to the target root unless preservation is explicitly requested.

### Verification checklist

- Run `pwsh -NoProfile -File ./tests/run-offline-checks.ps1` from the repository root.
- Confirm source query URL, target project URL, PAT scopes, and target process prerequisites.
- Preserve the state file before reruns.
- Review both JSONL logs, the console summary, and any `*.failures.json`.
- Inspect representative target work items, fields, links, and copied query WIQL.

Offline checks do not contact Azure DevOps and do not prove a live migration's semantic completeness.

### Troubleshooting

- `401`/`403`: verify PAT organization, expiry, Work Items scope, and project permissions.
- Missing field/type/path: prepare the target process or classification paths, then rerun with the same state.
- Partial relation failures: inspect the failure JSON; some source relation types or external links are intentionally out of scope.
- Differing target query: review the target query path and WIQL before rerunning.

### Limitations

No history, comments, attachments, identities, permissions, external links, complete field parity, rollback, or universal dry run are provided. Existing mapped target work items may be patched, so reruns require review.

### Security

Use short-lived least-privilege PATs. Protect state, logs, summaries, and copied query data because they can contain work item text, paths, IDs, and WIQL. Never put PAT text in command history or source control.

### Related workflows

Run after target [work item type migration](../ado-migrate-workitemtype/README.md), [Area Paths](../ado-import-area-paths/README.md), and [Iteration Paths](../ado-import-iterations/README.md) are ready. For dashboard query dependencies, see [dashboard migration](../ado-dashboard-migration/README.md). Shared repository conventions are in the [root README](../README.md).
