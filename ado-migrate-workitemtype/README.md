# Migrate a Work Item Type

`ado-migrate-workitemtype.ps1` migrates one Azure DevOps inherited-process work item type (WIT) — including its custom fields, picklists, states, rules, and form layout placement — from a source process to a target process, within the same organization or across two organizations.

## What it migrates

1. The work item type itself (creates a custom WIT, or derives a system WIT so it can be customized).
2. Picklists backing any custom picklist fields (reused by name if a picklist with that name already exists in the target organization).
3. Org-level custom field definitions (created only if missing in the target org).
4. Field membership on the WIT — required / read-only / default value / allowed groups. Existing fields are patched to match the source.
5. Custom states, plus hiding of inherited states that are hidden in the source.
6. Custom rules, best-effort. A rule referencing something that does not exist in the target (identity, field, state) is logged as a warning and skipped.
7. Form layout: pages, groups, and controls for the migrated fields, so they actually appear on the work item form.

### Not migrated

- Backlog-level / behavior assignments (Boards > Process > Backlog levels).
- Extension (contribution) controls on the form.
- General system-process content.

The script is idempotent — items that already exist in the target are detected and skipped or patched, so it's safe to re-run after fixing a failure.

## Prerequisites

- PowerShell 7+ (or Windows PowerShell 5.1).
- A source PAT with **Work Items (Read)** and **Process (Read)**.
- A target PAT with **Work Items (Read & Write)** and **Process (Read & Write)**. Creating org-level fields in the target requires Project Collection Administrator, or an equivalent "Create process" / field-create permission.
- The target process must be an **inherited** process (not a system process) so it can be customized.

## Usage

Run with no arguments to be prompted for all seven inputs:

```powershell
.\ado-migrate-workitemtype.ps1
```

Or pass the non-secret values and be prompted only for the PATs:

```powershell
.\ado-migrate-workitemtype.ps1 -WorkItemTypeName 'Business Process' `
    -SourceOrganization 'hsouscloud' -SourceProcess 'HSO-Navigate-CMMI' `
    -TargetOrganization 'hsouscloud' -TargetProcess 'HSO-Navigate-Agile-2026-07'
```

When source and target organizations are the same, the script offers to reuse the source PAT for the target instead of prompting a second time.

## Parameters

| Parameter | Description |
| --- | --- |
| `WorkItemTypeName` | Name of the work item type as shown in the source process (e.g. `Business Process`). Prompts when omitted. |
| `SourceOrganization` | Source organization name or URL (`contoso` or `https://dev.azure.com/contoso`). Prompts when omitted. |
| `SourceProcess` | Source inherited process name. Prompts when omitted. |
| `SourcePat` | Source PAT (Work Items + Process read). Prompts securely when omitted. |
| `TargetOrganization` | Target organization name or URL. Prompts when omitted. |
| `TargetProcess` | Target inherited process name. Must not be a system process. Prompts when omitted. |
| `TargetPat` | Target PAT (Work Items + Process read/write). Prompts securely when omitted; offers to reuse the source PAT for a same-org migration. |

## Output

The script prints progress per stage (`[OK]`, `[SKIP]`, `[WARN]`) and ends with a summary count of picklists, org fields, WIT fields, states, rules, and form controls created or updated, plus a warning count. Review `[WARN]` lines — they flag rules or content that could not be reconciled automatically and may need manual follow-up in the target process.

## Safety

Run against a non-production process first when possible. The script only creates or patches; it does not delete states, fields, or rules from the target. Target-only states not present in the source are flagged with a warning rather than removed.
