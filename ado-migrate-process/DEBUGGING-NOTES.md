# Process Migration Fix - Target Project Process Check

## Root Cause Identified

The target project must already be on the migrated/target process **before**
this script runs, or WIT/state/field customizations apply to the wrong
(original) process. Two issues compounded this:

1. The script originally never checked or surfaced whether the target project
   was on the right process at all.
2. A later attempt to have the script **switch** the project's process
   automatically via `PATCH _apis/projects/{projectId}` (setting
   `capabilities.processTemplate.templateTypeId`) always failed with
   `HTTP 400: The project update is invalid.` -- confirmed against the
   [Projects - Update REST API docs](https://learn.microsoft.com/rest/api/azure/devops/core/projects/update),
   which state the endpoint supports only name, abbreviation, description, or
   restore. Changing an existing project's process is a **UI-only operation**
   (see [Change a project's process](https://learn.microsoft.com/azure/devops/organizations/settings/work/manage-process#change-a-projects-process));
   there is no supported public REST API for it.

## Current Behavior

### 1. `TargetProject` Parameter

```powershell
param(
    ...
    [string]$TargetProject,
    ...
)
```

### 2. Process Check (not switch)

After the target process is created/found, if `-TargetProject` is supplied the
script:
1. Fetches the target project (with `includeCapabilities=true`).
2. Compares its current `processTemplate.templateTypeId` to the migrated process.
3. If they already match, logs a skip.
4. If they don't match, **warns** that the project must be switched manually
   via **Project Settings > Boards > Process** and does not attempt an API call
   that's known to fail.

## How to Use

```powershell
.\ado-migrate-process\ado-migrate-process.ps1 `
    -SourceOrganization "https://dev.azure.com/360sg" `
    -SourceProcess "Accelerate - US" `
    -TargetOrganization "https://dev.azure.com/spriestley" `
    -TargetProcess "Accelerate - US" `
    -TargetProject "AEC Template"
```

If the project isn't on the target process yet, do this **once**, before
re-running the script:
1. Organization Settings > Process > select the target process (e.g. "Accelerate - US").
2. Open the **Projects** tab for that process.
3. Move "AEC Template" onto this process.
4. Re-run the migration script.

## Manual Verification

1. Go to Organization Settings > Process; confirm the custom process exists.
2. Go to Project Settings > Overview; confirm "Process" shows the custom
   process name (not "Agile" or another base process).

## Root cause found: "`$hideUri` cannot be retrieved because it has not been set"

This error recurred across multiple live launcher runs and was never
reproducible via static code review or a standalone run of this script --
`$hideUri` was correctly initialized (`$hideUri = $null`) immediately before
its only reads, so nothing in the code itself looked wrong.

The actual cause: **`Set-StrictMode` is inherited from the caller's scope.**
This script never called `Set-StrictMode` itself. Per Microsoft's docs,
calling a script creates a child scope of the caller, and "`Set-StrictMode`
affects only the current scope and its child scopes." `ado-project-setup-runner.ps1`
sets `Set-StrictMode -Version Latest` at its own script scope, and its
`Invoke-EntryScript` function invokes this script via `& $command @Arguments`
-- which runs it as a **child scope of the runner**, silently inheriting
StrictMode Latest. Run this script standalone (a fresh PowerShell prompt,
`./ado-migrate-process.ps1 ...`), there's no inherited StrictMode and nothing
fails. Run it through the launcher pipeline, StrictMode Latest is silently ON
and something about the `$hideUri` pattern (the exact mechanism was never
fully pinned down, despite the explicit `$null` initialization) tripped it.

This explains every earlier "3 earlier runs" data point in prior handoffs:
the bug was 100% environment-dependent on *how* the script was invoked, with
zero visible difference in the source.

**Fix applied**: `Set-StrictMode -Off` added explicitly near the top of
`ado-migrate-process.ps1` (right after `$ErrorActionPreference = 'Stop'`), so
this script's behavior is now the same regardless of what a caller has set.
The `$hideUri` intermediate variable was also removed (the URI is now built
inline in the `Invoke-Ado -Uri` argument) as defense-in-depth, in case
StrictMode is ever deliberately re-enabled for this script in the future.

**Takeaway for future debugging of "only fails via the launcher" reports in
this repo**: check whether the failing child script sets `Set-StrictMode`
itself. If it doesn't, its effective strictness silently depends on whether
it was invoked standalone or via `ado-project-setup-runner.ps1` (which does
set it). None of `ado-migrate-process.ps1`'s sibling entry scripts under other
`ado-*` folders were audited for the same gap as part of this fix -- worth a
sweep if a similarly unreproducible "only via launcher" bug turns up again in
one of them.

