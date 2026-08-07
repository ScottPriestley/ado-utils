# Azure DevOps Process Migration

`ado-migrate-process.ps1` migrates an entire Azure DevOps inherited process from one organization to another, including all work item types, fields, picklists, states, rules, and layout configurations.

## Scripts, capabilities, and exclusions

The script creates the target process (if needed), then migrates work item types (both custom and inherited), organization-level fields, picklists, WIT field settings, custom states, state visibility rules, custom rules, and form layout controls.

It does not migrate backlog behavior assignments, extension-contribution controls, process permissions, projects, work items, process description beyond basic metadata, or deletions. Rules whose dependencies cannot be reconciled are warned and skipped.

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

## Parameters and precedence

| Parameter | Description |
| --- | --- |
| `SourceOrganization` / `TargetOrganization` | Bare organization name or supported Azure DevOps URL. |
| `SourceProcess` | Exact source process display name. |
| `TargetProcess` | Exact target process display name (will be created if missing). |
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
