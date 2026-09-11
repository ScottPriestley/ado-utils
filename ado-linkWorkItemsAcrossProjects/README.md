# ado-linkWorkItemsAcrossProjects.ps1

A dependency-free PowerShell 7 script that creates **links between Azure DevOps work items
in two projects of the same organization**, driven by an Excel crosswalk — with the
**link type read per row** from a `LinkType` column. Typical use case: work tracked in a
legacy project continues in a new project, and the relationships must be preserved as
links (e.g., each new work item shows its legacy items as **Predecessors** under
Related Work).

It uses only the Azure DevOps REST API — no `az` CLI, no Excel/COM, no ImportExcel module
(the .xlsx is parsed directly as Open XML), and it never creates or modifies work items or
fields: it only adds (or removes) relations.

## The crosswalk workbook

One worksheet, one row per link, three required columns (header texts are parameters):

| Column (default header) | Content |
|---|---|
| `Legacy ID` | Source work item ID (the item the link points at) |
| `Target ID` | Target work item ID (the item the link is added ON) |
| `LinkType`  | The role the source takes on the target's form — see below |

The header row is auto-detected, so title/note rows above the table are fine. Blank IDs,
non-numeric IDs, self-links, blank `LinkType` cells, and duplicates are skipped and
itemized in the report — the script never guesses a link type.

### LinkType values

Friendly end names (case-insensitive) or raw relation reference names:

| Friendly name | Reference name |
|---|---|
| `Predecessor` | `System.LinkTypes.Dependency-Reverse` |
| `Successor` | `System.LinkTypes.Dependency-Forward` |
| `Related` | `System.LinkTypes.Related` |
| `Parent` | `System.LinkTypes.Hierarchy-Reverse` |
| `Child` | `System.LinkTypes.Hierarchy-Forward` |
| `Duplicate` / `Duplicate Of` | `System.LinkTypes.Duplicate-Forward` / `-Reverse` |
| `Affects` / `Affected By` | `Microsoft.VSTS.Common.Affects-Forward` / `-Reverse` |
| `Tested By` / `Tests` | `Microsoft.VSTS.Common.TestedBy-Forward` / `-Reverse` |

Direction semantics: the link is added **on the target work item, pointing at the
source** — so `Predecessor` means the target shows the source as a predecessor,
`Parent` means the target shows the source as its parent, and so on. Rows can mix link
types freely.

In DryRun/Apply/Remove modes, `LinkType` values are validated against your organization's
actual list of work item relation types (custom link types included); ParseOnly validates
against the built-in table of standard system types above.

## Requirements

- PowerShell 7 (`pwsh`). Check: `pwsh -NoProfile -Command '$PSVersionTable.PSVersion'`
- An Azure DevOps PAT with **Work Items: Read & Write** scope. Pass it with `-Pat` or set
  the `AZDO_PAT` environment variable. The script deliberately contains **no embedded
  token**.

## Usage

Run the modes in this order — the first and last are read-only.

```powershell
# 1. LOCAL PARSE CHECK - no network calls at all
pwsh -NoProfile -File .\ado-linkWorkItemsAcrossProjects.ps1 `
    -OrgUrl 'https://dev.azure.com/your-org' `
    -WorkbookPath 'C:\migrations\crosswalk.xlsx' -Mode ParseOnly

# 2. DRY RUN - read-only GETs; validates pairs AND link types; writes a report; changes nothing
pwsh -NoProfile -File .\ado-linkWorkItemsAcrossProjects.ps1 `
    -OrgUrl 'https://dev.azure.com/your-org' `
    -WorkbookPath 'C:\migrations\crosswalk.xlsx' -Mode DryRun

# 3. APPLY - creates the links (one PATCH per target work item)
pwsh -NoProfile -File .\ado-linkWorkItemsAcrossProjects.ps1 `
    -OrgUrl 'https://dev.azure.com/your-org' `
    -WorkbookPath 'C:\migrations\crosswalk.xlsx' -Mode Apply

# 4. VERIFY - re-run the dry run; expect PLANNED = 0, every pair ALREADY_LINKED
pwsh -NoProfile -File .\ado-linkWorkItemsAcrossProjects.ps1 `
    -OrgUrl 'https://dev.azure.com/your-org' `
    -WorkbookPath 'C:\migrations\crosswalk.xlsx' -Mode DryRun
```

Optional parameters:

```powershell
-Limit 3                     # smoke test on the first 3 target work items only
-SheetName 'Crosswalk'       # worksheet name (default 'Related Links Master List')
-SourceIdHeader 'Old ID'     # header of the source ID column (default 'Legacy ID')
-TargetIdHeader 'New ID'     # header of the target ID column (default 'Target ID')
-LinkTypeHeader 'Relation'   # header of the link type column (default 'LinkType')
-LinkComment '...'           # comment stored on each created link
-ReportPath 'C:\temp\r.csv'  # explicit report location
```

Rollback, if ever needed (removes exactly the crosswalk-defined links, nothing else):

```powershell
pwsh -NoProfile -File .\ado-linkWorkItemsAcrossProjects.ps1 `
    -OrgUrl 'https://dev.azure.com/your-org' `
    -WorkbookPath 'C:\migrations\crosswalk.xlsx' -Mode Remove
```

## How it works

- Reads the crosswalk with a small Open XML parser (zip + sheet XML + shared strings) via
  a temp copy of the file, so the workbook can be open in Excel while the script runs.
- Validates the IDs and link types; skips blanks/non-numeric/self/duplicate/unknown rows
  (reported per row with the workbook row number).
- Pre-validates all unique source IDs in batches of 200 via `workitemsbatch` (handles both
  the bare-array and `{count, value}` response shapes; an empty response is treated as a
  validation failure, not as "all IDs missing").
- Groups pairs by target work item: one GET (`$expand=relations`) + one JSON Patch
  (`application/json-patch+json`, `add /relations/-` with the row's relation type) per
  target item, so thousands of links across a few hundred items take minutes, not hours.
- Detects already-existing links (relation type + numeric ID parsed from the relation
  URL) and skips them — the script is idempotent and safely resumable.
- If a batch PATCH fails, it retries the relations one at a time to isolate bad pairs
  (e.g., tree-type links that allow only one parent); 429/5xx responses are retried with
  exponential backoff; HTTP 401 stops the run immediately.

## Report

Every run writes `link_run_<mode>_<timestamp>.csv` with one row per pair:
`source_id, target_id, link_type, status, message`.

| Status | Meaning |
|---|---|
| `PLANNED` | DryRun: this link would be created by Apply |
| `LINKED` | Apply: link created |
| `ALREADY_LINKED` | Link of the same type to the same source already exists — skipped |
| `REMOVED` / `NOT_PRESENT` | Remove mode outcomes |
| `SKIPPED_BLANK` / `SKIPPED_NONNUMERIC` / `SKIPPED_SELF` / `SKIPPED_DUPLICATE` | Workbook rows excluded from scope |
| `SKIPPED_NO_LINKTYPE` / `SKIPPED_UNKNOWN_LINKTYPE` | LinkType cell blank / not a valid link type |
| `ERROR_SOURCE_NOT_FOUND` / `ERROR_TARGET_NOT_FOUND` / `ERROR` | Failed pairs with the API message in `message` |

Gate before Apply: `PLANNED + ALREADY_LINKED` should equal your total pair count, and the
skipped/error rows should be reviewed or accepted.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `AUTHENTICATION FAILED (HTTP 401)` | PAT invalid/expired — pass `-Pat` or set `AZDO_PAT`; re-run. Partial report is written. |
| `ERROR_TARGET_NOT_FOUND` | Target ID doesn't exist (or was deleted) in the target project. |
| `ERROR_SOURCE_NOT_FOUND` | Source ID doesn't exist / is deleted — Azure DevOps refuses links to removed items. |
| `Could not find a header row...` | Set `-SourceIdHeader` / `-TargetIdHeader` / `-LinkTypeHeader` to your workbook's exact header texts. |
| `SKIPPED_UNKNOWN_LINKTYPE` | Use a friendly name or reference name from the table above, or a custom link type that exists in your org. |
| `workitemsbatch returned an empty response` | Transient validation failure — the affected IDs are still attempted at link time. |
| `running scripts is disabled` | `pwsh -ExecutionPolicy Bypass -File .\ado-linkWorkItemsAcrossProjects.ps1 ...` |

## Security notes

- The script accepts the PAT only via `-Pat` or the `AZDO_PAT` environment variable and
  never prints or logs it. Never hard-code tokens in scripts you share.
- If a PAT has ever been pasted into chat, email, or a document, rotate/revoke it at
  `https://dev.azure.com/<your-org>/_usersSettings/tokens`.
