# Azure DevOps Project Setup Launcher

`ado-project-setup` provides a PC-friendly launcher for standing up a new Azure DevOps target project from a source project. The UI follows the approved `launcher-mock.html` design: connect, choose steps, run, and done.

## Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-project-setup-ui.ps1` | Local WPF interface launched directly or through `ado-migrate://open`. | Does not store PATs or host the bookmark page. |
| `ado-project-setup-runner.ps1` | Runs selected setup steps in the prescribed order and writes PC-facing logs. | Does not create the target project, migrate permissions, or provide rollback. |
| `install-ado-migrate-protocol.ps1` | Registers the Windows `ado-migrate://` protocol to open the local UI. | Does not deploy the final HTML/script hosting location. |

The final home for the HTML and scripts must be determined and locked before Production. Prototype locations are development-only.

## Workflow

1. Open the bookmarkable HTML page.
2. Click the launch link, which opens `ado-migrate://open`.
3. Enter source project URL, source PAT, target project URL, and target PAT once.
4. Optionally enter a process name if you want to migrate the process template (Step 0), and choose a process migration mode:
   - **Full automation** -- creates the process and the target project via the API, then continues straight into the full migration in the same run. Needs the target project URL to name what to create. Only use this when the customer has granted API access to create projects in their target organization.
   - **Process now, project later** (default) -- creates the process via API, then stops for a person to create or switch the target project by hand (there is no API for either). Rerun Step 0 once that's done.
   - **Export process only** -- makes no changes in the target organization at all. Writes the process definition to a JSON file for hand-off to the customer's own Azure DevOps admin. Nothing else in this run can proceed without a target project, so the run ends here; start a new run once the customer's project exists.
5. Select one or more steps. Selected steps run in this order:
   0. Migrate Process Template (optional - WITs, fields, picklists, states, rules, and layout). What happens next depends on the mode chosen above: full automation keeps going, "process now, project later" shows an amber "action needed" result, and "export only" shows a blue "process exported" result -- neither of the latter two is a failure.
   1. Set target Team Configuration default area with Include Sub Areas.
   2. Copy Iteration Paths.
   3. Copy Area Paths.
   4. Copy all Work Items.
   5. Copy Shared Query folders, subfolders, and queries.
   6. Copy Dashboards.
   7. Copy Wiki pages, subpages, and referenced images.
6. Review the final success/failure screen and open per-step logs as needed. After an "exported" result, use "Start New Run" to clear the form and begin fresh once the target project exists.

## Authentication and scopes

PATs are accepted in the UI as password fields. The UI passes them to the child runner process through process environment variables for the run and clears those variables immediately after launch. The values are not written to disk or command history.

Minimum scopes depend on selected steps:

- Source: Work Items Read, Process Read (for Step 0), Team Dashboards Read, Code/Wiki Read, Project/team metadata Read.
- Target: Work Items Read & write, Process Read & write (for Step 0), Team Dashboards Manage, Code/Wiki Read & write, Project/team metadata Read, and permission to update Team Settings.

Note: Step 0 (Process migration) requires Process Read & write scopes and Project Collection Administrator permission (or equivalent process permissions) in the target organization to create organization-level fields -- this applies to the "Full automation" and "Process now, project later" modes. "Export process only" makes no target-organization calls for Step 0 and needs no target write scopes for it (other selected steps, if any, are skipped in that same run since no target project exists yet).

PATs are never written to the HTML page, config, command line, logs, or state files.

The source PAT genuinely needs only read scopes. Step 4 discovers work items with
WIQL through `ado-copy-all-workitems`, so nothing is created in the source
project.

## Logs and outputs

The default run root is:

```text
%USERPROFILE%\Documents\AdoMigrationLogs\<target-org>_<target-project>\<yyyyMMdd-HHmmss>\
```

Each selected activity writes a PC-facing text log named:

```text
<target-org>_<target-project> <activity>.log
```

The runner also writes:

- `progress.jsonl` for UI status updates.
- `summary.json` for the final run summary.
- `technical-jsonl/` containing canonical ado-utils JSONL logs from wrapped scripts.
- Step-specific export artifacts such as the dashboard export.

Work item resume state is deliberately **not** per-run. It lives at:

```text
%USERPROFILE%\Documents\AdoMigrationLogs\<target-org>_<target-project>\state\workitems-state.json
```

That file maps each source work item to the target item created from it. Rerunning
the work item step reads it and skips what already exists. Deleting it makes the
next run copy every work item again, creating duplicates - so keep it with the
target project, and delete it only when starting that target over from scratch.

Do not commit generated run folders, logs, state files, or exports.

## Protocol installation

From an elevated PowerShell session for the supported browser path:

```powershell
./ado-project-setup/install-ado-migrate-protocol.ps1 `
  -LauncherScriptPath 'C:\Path\To\ado-project-setup-ui.ps1' `
  -Scope LocalMachine
```

The registered command uses `-WindowStyle Hidden` and passes the clicked URL as the first argument. The launcher parses `ado-migrate://open` by reading the URI host as the action verb.

Use `-Scope CurrentUser` only for development; browser behavior may not honor HKCU-only protocol registration.

## Bookmark HTML

The production HTML file can be hosted wherever IT approves before release. It should only contain a launch link such as:

```html
<a href="ado-migrate://open">Open ADO Migration Launcher</a>
```

The HTML must not collect PATs or attempt to run migrations directly.

## Safety and rerun behavior

The launcher is additive. Wrapped scripts preserve their existing behavior: they create missing objects, reuse state where supported, skip or patch according to their README, and do not perform implicit deletes. A failed run can be rerun for selected failed steps after reviewing logs and correcting the cause.

The target project must already exist and use the intended process template, unless Step 0's "Full automation" mode is used to create it. The launcher does not migrate permissions, organization extensions, work-item history, every identity mapping, or rollback state.

### Process mismatch is the most common source of partial results

The seven steps copy *content*, not the *process* that defines it. If the target
uses a different process template from the source, everything that depends on a
custom type or field is reported as skipped rather than copied:

- Work items whose type does not exist in the target are skipped, and the missing
  types are named at the end of step 4.
- Shared queries referencing a custom field are skipped in step 5.
- Dashboard widgets bound to those queries import but stay empty.

Migrating the target process first with
[ado-migrate-workitemtype](../ado-migrate-workitemtype/README.md) removes this
entire class of skip. That step is deliberately **not** part of the seven-step
sequence: it changes the target's process definition, which is a heavier and less
reversible operation than copying content, and many target projects intentionally
use a different process.

Step 0 in this launcher does the same job directly (see [ado-migrate-process](../ado-migrate-process/README.md)),
in one of three modes chosen on the Connect screen. Because Azure DevOps has no
API to switch an existing project onto a different process (only to create a
brand-new one already on it), "Process now, project later" mode stops after
creating/verifying the process and shows an "action needed" result instead of
success or failure -- create or switch the project manually, then rerun Step 0
to finish. "Full automation" mode creates the project itself instead of
stopping. "Export process only" mode makes no target-org changes at all and
ends the run with a "process exported" result once the file is written.

## Verification

Run offline checks from the repo root:

```powershell
pwsh -NoProfile -File ./tests/run-offline-checks.ps1
```

Manual smoke test:

1. Register `ado-migrate://`.
2. Click the bookmark page launch link in Edge or Chrome.
3. Confirm the local UI opens without a console flash.
4. Run one low-risk step against a test project.
5. Confirm the final screen links to the generated activity log.
