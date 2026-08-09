# Azure DevOps Process Migration

`ado-migrate-process.ps1` migrates an entire Azure DevOps inherited process from one organization to another, including all work item types, fields, picklists, states, rules, and layout configurations.

## Scripts, capabilities, and exclusions

The script creates the target process (if needed), then migrates work item types (both custom and inherited), organization-level fields, picklists, WIT field settings, custom states, state visibility rules, custom rules, and form layout controls.

It does not migrate backlog behavior assignments, extension-contribution controls, process permissions, projects, work items, process description beyond basic metadata, or deletions. Rules whose dependencies cannot be reconciled are warned and skipped.

### Three process-migration modes (`-ProcessMode`)

Azure DevOps has no REST API to switch an **existing** project's process --
only its web UI can do that (Organization Settings > Process > select the
process > Projects tab). It *does*, however, support creating a **brand-new**
project already on a given process via the API. Real engagements vary in how
much API access the customer grants, so `-ProcessMode` selects one of three
behaviors:

- **`AssistedManual`** (default): creates/verifies the process via API, then
  checks `-TargetProject`. If the project doesn't exist yet, or exists but is
  on a different process, the script prints the exact manual step needed and
  stops -- it exits with code `3` rather than throwing, since this is an
  expected pause, not a failure. Do the manual step, then run the script again
  with the same parameters; it detects the project is now correct and
  proceeds with the full migration. Without `-TargetProject`, this check is
  skipped entirely and the full migration always runs.
- **`FullAuto`**: creates the process via API, then also creates a brand-new
  project (`-TargetProject`, required in this mode) already on that process
  via the API -- private visibility, Git version control, not configurable --
  and continues straight into the full WIT/field/state/rule/layout migration
  in the same run, no manual step needed. Only use this when the customer has
  granted API access to create projects in their target organization. If the
  project already exists (e.g. a rerun after a prior partial `FullAuto` run),
  it falls back to the same check-and-continue behavior as `AssistedManual`.
- **`ExportOnly`**: makes **zero API calls to the target organization at
  all**. Reads the source process definition and writes it to a local JSON
  file (`process-export-<name>-<timestamp>.json` under `-LogDirectory`) for
  hand-off to the customer's own Azure DevOps admin, who recreates the
  process (and the project) themselves. Exits with code `4` -- there is
  nothing to rerun in this same session; a fresh run happens later once the
  customer's project exists. `-TargetOrganization`/`-TargetPat` are still
  requested (the parameter set doesn't change per mode) but are not used for
  anything in this mode.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source: Process Read and Work Items Read.
- Target: Process Read & write and Work Items Read & write.
- Target organization must allow process creation; creating organization-level fields requires Project Collection Administrator permission or equivalent process permissions.

## Authentication and minimum PAT scopes

`SourcePat` resolves from SecureString → `ADO_SOURCE_PAT` → `Source Azure DevOps PAT (input hidden)`. Target uses its equivalent chain and prompt. Organization prompts are the exact shared source/target organization strings. Other exact prompts are `SOURCE process name` and `TARGET process name (will be created if it does not exist)`. `-NonInteractive` fails rather than prompting. PATs are not cached or written to disk.

## Safety and rerun behavior

The script issues GET/POST/PATCH/PUT operations and no DELETE. It reuses many name/reference matches, patches field settings, and warns about failures rather than stopping. Reruns are intended to converge on supported metadata, but not every object is deeply compared and rule/layout reconciliation is best-effort; review warnings and target content after every run.

There is no `-WhatIf`, preview, rollback, or transaction. Use a nonproduction target organization first.

## Quick start

```powershell
./ado-migrate-process.ps1 `
  -SourceOrganization 'source-org' -SourceProcess 'My Custom Process' `
  -TargetOrganization 'target-org' -TargetProcess 'My Custom Process Copy'
```

Unattended:

```powershell
./ado-migrate-process.ps1 `
  -SourceOrganization 'source-org' -SourceProcess 'My Custom Process' -SourcePat $sourcePat `
  -TargetOrganization 'target-org' -TargetProcess 'My Custom Process Copy' -TargetPat $targetPat `
  -LogDirectory './run-logs' -NonInteractive
```

Export-only, no target organization access needed:

```powershell
./ado-migrate-process.ps1 `
  -SourceOrganization 'source-org' -SourceProcess 'My Custom Process' -SourcePat $sourcePat `
  -ProcessMode ExportOnly -LogDirectory './run-logs' -NonInteractive
```

## Parameters and precedence

| Parameter | Description |
| --- | --- |
| `SourceOrganization` / `TargetOrganization` | Bare organization name or supported Azure DevOps URL. |
| `SourceProcess` | Exact source process display name. |
| `TargetProcess` | Exact target process display name (will be created if missing). |
| `TargetProject` | Optional for `AssistedManual`/`ExportOnly`; required for `FullAuto` (the project to check/create). |
| `ProcessMode` | `FullAuto`, `AssistedManual` (default), or `ExportOnly` -- see above. |
| `SourcePat` / `TargetPat` | Role-specific `SecureString` PATs. |
| `LogDirectory` | Shared JSONL directory; defaults to `logs` beside the script. |
| `NonInteractive` | Rejects all missing interactive input. |

Explicit non-secret parameters precede prompts. PAT precedence is SecureString → environment → prompt. No same-organization PAT-reuse question exists in the current code; supply the same SecureString explicitly to both parameters if migrating within one organization.

## Input formats

Names are plain PowerShell strings and are matched against live organization/process metadata. Organization accepts `contoso`, `https://dev.azure.com/contoso`, or legacy organization URL form. The script has no input CSV/JSON workbook; source process APIs are authoritative.

## Outputs and logs

Console output reports `[OK]`, `[SKIP]`, `[WARN]`, and summary totals for WITs, picklists, fields, states, rules, and layout controls. No migration package or rollback file is produced.

Each run creates UTF-8-without-BOM JSONL files named `<script-base>-success log-<run-id>.jsonl` and `<script-base>-error log-<run-id>.jsonl` under `LogDirectory` or local `logs` (the script base is `ado-migrate-process`). Records contain `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; PAT/authorization values are redacted.

## Detailed workflow and behavior

The script resolves source/target organizations and source process, then creates or reuses the target process. It enumerates and creates picklists, then organization-level fields. For each work item type in the source process, it creates or updates the WIT in the target, attaches or patches fields, creates custom states, hides inherited states that were hidden in source, creates rules where dependencies exist, and adds missing layout controls.

Warnings are expected for unsupported extension controls, target-only content, or rule dependencies that cannot be translated. A final success means the implemented calls completed; it is not a full semantic comparison of process behavior.

## Verification checklist

- Run both offline repository verification commands.
- Confirm source and target organization/process names before execution.
- Review every warning and summary count.
- In the target organization, open the process and inspect:
  - All work item types are present
  - Custom fields and picklists exist
  - Field settings (required/read-only/default) match source
  - States are correctly created and hidden states match source
  - Rules are present (check for skipped rules in logs)
  - Form layouts show all custom fields
- Create representative test work items and exercise state/rule behavior manually.
- Verify backlog behavior assignments separately.

Offline checks make no live calls and cannot prove process permissions, UI rendering, or rule semantics.

## Troubleshooting

- Target organization doesn't allow process creation: verify your permissions or ask an administrator to create an empty inherited process first.
- Field/picklist creation forbidden: verify target PAT scope and collection-level process permissions.
- Rule skipped: create/map the referenced identity, field, state, or group and rerun, then inspect duplicates.
- Layout warning: extension controls are unsupported; configure them manually.
- WIT creation failed: the target process may already have a conflicting WIT; check manually.
- `401`/`403`: verify PAT organization/expiry/scope and the user's process administration permission.

## Limitations

This is a selective best-effort process migration, not a full clone. It lacks rollback/dry run, does not migrate behaviors or extension controls, and does not prove semantic equivalence. The target process is created from a default parent (Agile preferred) if it doesn't exist, which may differ from the source process's parent. Concurrent changes and target customizations can require manual resolution. No live validation is claimed.

## Security

PATs are handled as SecureString parameters and are not written to disk or console. All log output redacts authorization headers and PAT values. Environment variables (`ADO_SOURCE_PAT`, `ADO_TARGET_PAT`) are marked sensitive when discovered. Follow your organization's credential management policies.
