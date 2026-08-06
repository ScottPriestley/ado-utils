# Azure DevOps Work Item Type Migration

`ado-migrate-workitemtype.ps1` migrates one inherited-process work item type (WIT), selected supporting metadata, and form placement between processes in the same or different organizations.

## Scripts, capabilities, and exclusions

The script creates or derives the WIT, reuses/creates picklists and organization fields, attaches/patches WIT field settings, creates custom states, hides inherited states hidden at source, creates best-effort rules, and creates missing layout pages/groups/controls.

It does not migrate backlog behavior assignments, extension-contribution controls, general system-process content, process permissions, projects, work items, or deletions. Rules whose identities/fields/states cannot be reconciled are warned/skipped.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source: Process Read and Work Items Read.
- Target: Process Read & write and Work Items Read & write.
- Target must be an inherited process; modifying organization fields can require collection-administrator/equivalent process permissions.

## Authentication and minimum PAT scopes

`SourcePat` resolves from SecureString → `ADO_SOURCE_PAT` → `Source Azure DevOps PAT (input hidden)`. Target uses its equivalent chain and prompt. Organization prompts are the exact shared source/target organization strings. Other exact prompts are `Work Item Type name (as shown in the process, e.g. "Business Process")`, `SOURCE process name`, and `TARGET process name`. `-NonInteractive` fails rather than prompting. PATs are not cached or written to disk.

## Safety and rerun behavior

The script issues GET/POST/PATCH/PUT operations and no DELETE. It reuses many name/reference matches, patches field settings, and warns about target-only states rather than removing them. Reruns are intended to converge on supported metadata, but not every object is deeply compared and rule/layout reconciliation is best-effort; review warnings and target content after every run.

There is no `-WhatIf`, preview, rollback, or transaction. Use a nonproduction inherited process first.

## Quick start

```powershell
./ado-migrate-workitemtype.ps1 `
  -WorkItemTypeName 'Business Process' `
  -SourceOrganization 'source-org' -SourceProcess 'Source Inherited Process' `
  -TargetOrganization 'target-org' -TargetProcess 'Target Inherited Process'
```

Unattended:

```powershell
./ado-migrate-workitemtype.ps1 `
  -WorkItemTypeName 'Business Process' `
  -SourceOrganization 'source-org' -SourceProcess 'Source Inherited Process' -SourcePat $sourcePat `
  -TargetOrganization 'target-org' -TargetProcess 'Target Inherited Process' -TargetPat $targetPat `
  -LogDirectory './run-logs' -NonInteractive
```

## Parameters and precedence

| Parameter | Description |
| --- | --- |
| `WorkItemTypeName` | Source display name; prompts when blank. |
| `SourceOrganization` / `TargetOrganization` | Bare organization name or supported Azure DevOps URL. |
| `SourceProcess` / `TargetProcess` | Exact process display names. Target must be inherited. |
| `SourcePat` / `TargetPat` | Role-specific `SecureString` PATs. |
| `LogDirectory` | Shared JSONL directory; defaults to `logs` beside the script. |
| `NonInteractive` | Rejects all missing interactive input. |

Explicit non-secret parameters precede prompts. PAT precedence is SecureString → environment → prompt. No same-organization PAT-reuse question exists in the current code; supply the same SecureString explicitly to both parameters if appropriate.

## Input formats

Names are plain PowerShell strings and are matched against live organization/process/WIT metadata. Organization accepts `contoso`, `https://dev.azure.com/contoso`, or legacy organization URL form. The script has no input CSV/JSON workbook; source process APIs are authoritative.

## Outputs and logs

Console output reports `[OK]`, `[SKIP]`, `[WARN]`, and stage totals for picklists, fields, states, rules, and layout controls. No migration package or rollback file is produced.

Each run creates UTF-8-without-BOM JSONL files named `<script-base>-success log-<run-id>.jsonl` and `<script-base>-error log-<run-id>.jsonl` under `LogDirectory` or local `logs` (the script base is `ado-migrate-workitemtype`). Records contain `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; PAT/authorization values are redacted.

## Detailed workflow and behavior

The script resolves source/target processes and source WIT, verifies the target process is customizable, and creates/derives or reuses the target WIT. It enumerates source fields, recreates/reuses picklists and organization fields, then attaches or patches WIT field attributes. It reconciles custom/hidden states, translates and creates rules where dependencies exist, and creates missing layout containers/controls for migrated fields.

Warnings are expected for unsupported extension controls, target-only content, or rule dependencies that cannot be translated. A final success means the implemented calls completed; it is not a full semantic comparison of process behavior.

## Verification checklist

- Run both offline repository verification commands.
- Confirm source and target process/WIT names and target inheritance before execution.
- Review every warning and summary count.
- In the target UI, inspect fields/picklists, required/read-only/default settings, state visibility, rules, and every form page/group/control.
- Create representative test work items and exercise rule/state behavior manually.
- Verify backlog behavior assignments separately.

Offline checks make no live calls and cannot prove process permissions, UI rendering, or rule semantics.

## Troubleshooting

- Target system process: create/select an inherited process.
- Field/picklist creation forbidden: verify target PAT scope and collection-level process permissions.
- Rule skipped: create/map the referenced identity, field, state, or group and rerun, then inspect duplicates.
- Layout warning: extension controls are unsupported; configure them manually.
- `401`/`403`: verify PAT organization/expiry/scope and the user's process administration permission.

## Limitations

This is a selective best-effort WIT migration, not a process clone. It lacks rollback/dry run, does not migrate behaviors or extension controls, and does not prove semantic equivalence. Concurrent changes and target customizations can require manual resolution. No live validation is claimed.

## Security

Use short-lived least-privilege PATs. Process definitions can expose internal business rules, field names, identities, and groups; protect logs and console captures. Never put PATs in source control or plain-text parameters.

## Related workflows

Use [field extraction](../ado-field-extraction/README.md) for planning. Migrate WITs before [Area/Iteration structure](../ado-import-area-paths/README.md) and [dashboard queries](../ado-dashboard-migration/README.md); see the [root workflow](../README.md).
