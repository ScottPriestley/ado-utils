<div align="center">

# Azure DevOps Work Item Extract

**Exports every work item in a project — fit-gap fields, related work links, and the full discussion thread — to one Excel-ready CSV, without changing anything in Azure DevOps.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)
![Azure DevOps](https://img.shields.io/badge/Azure%20DevOps-0078D4?style=flat-square&logo=azuredevops&logoColor=white)
![Read-only](https://img.shields.io/badge/Azure%20DevOps-Read--only-4a5568?style=flat-square)

</div>

`ado-extract-workitems.ps1` is self-contained (no shared module). You give it a project URL and a PAT; it writes `ADO Extract <Organization>-<Project>-<YYYY-MM-DD>.csv`.

## Quick start

```powershell
$pat = Read-Host 'Azure DevOps PAT (input hidden)' -AsSecureString

# 1. Check how each column maps to a field in your project (no export)
./ado-extract-workitems/ado-extract-workitems.ps1 -ProjectUrl 'https://dev.azure.com/contoso/Fit Gap' -Pat $pat -ResolveFieldsOnly

# 2. Export
./ado-extract-workitems/ado-extract-workitems.ps1 -ProjectUrl 'https://dev.azure.com/contoso/Fit Gap' -Pat $pat
# -> .\ADO Extract contoso-Fit Gap-2026-11-05.csv
```

If you leave out `-ProjectUrl` or `-Pat`, the script asks for them (the PAT prompt hides what you type). PAT scope needed: **Work Items (Read)**.

Accepted URL forms (anything after the project, such as `/_workitems/...`, is ignored):
`https://dev.azure.com/{org}/{project}`, `https://{org}.visualstudio.com/{project}`, `https://{server}/{collection}/{project}` (Azure DevOps Server; add `-ApiVersion 7.0` for 2022.0).

## Columns

Columns come out in this order. Each one is matched to a field in your project when the script runs:

1. A `-FieldMap` override, if you gave one
2. A known system field (table below)
3. A field with exactly the same display name (case-insensitive)
4. A field whose name matches once spaces, punctuation and case are ignored, and "T-Shirt" is treated the same as "Teeshirt" (`Cross-Functional Impact` → `Cross Functional Impact`). If two or more fields match this way, the script does not pick one.

| Column | Source |
| --- | --- |
| ID, Work Item Type, State, Title, Description, Created Date, Created By, Assigned To | `System.*` field of the same name |
| Area / Iteration | `System.AreaPath` / `System.IterationPath` |
| Updated Date / Updated By | `System.ChangedDate` / `System.ChangedBy` |
| Acceptance Criteria, Due Date, Priority | `Microsoft.VSTS.Common.AcceptanceCriteria`, `Microsoft.VSTS.Scheduling.DueDate`, `Microsoft.VSTS.Common.Priority` |
| Gap Description … Responsible (all other fit-gap columns) | Custom field matched by display name |
| Development | A field named "Development" if your project has one. If not, the item's Development links (branch / commit / pull request / build). |
| Related Work links | Work-item links (Parent, Child, Related, …) shown as `Parent: #123 Epic: Title [State]`, followed by hyperlinks. Linked items in other projects are looked up too. Attachments are left out. |
| All Discussion entries | Every comment, oldest first, as `[yyyy-MM-dd HH:mm] Author: text`, with a blank line between comments. Deleted comments are left out. |

Any column that matches no field is written **empty**, and the script lists it in a warning. It also prints the custom fields it did not use, so you can map the missing column yourself:

```powershell
./ado-extract-workitems.ps1 -ProjectUrl $url -Pat $pat -FieldMap @{
    'Identified When' = 'Custom.WhenIdentified'   # reference name or display name
    'Area'            = 'Custom.BusinessArea'     # override a system default
}
```

To add, remove or reorder columns, edit `$script:ColumnSpec` at the top of the script.

## Value formatting

- **Rich text** (Description, custom HTML fields, comments) is turned into plain text. Paragraphs and line breaks stay, list items get `•` bullets, table cells are joined with `|`, and links appear as `text (url)`. Use `-KeepHtml` to keep the raw HTML instead.
- **Dates** are written as `yyyy-MM-dd HH:mm` in the time zone of the machine running the script. Use `-Utc` for UTC.
- **People fields** show the person's display name.
- **Formula guard:** Excel would run text that starts with `= + - @` as a formula, so the script puts an apostrophe in front of it. Negative numbers are left alone. `-NoFormulaGuard` turns this off.
- The file is UTF-8 with a BOM, so Excel shows accented and other non-ASCII characters correctly. Cells can span several lines.
- Excel cuts off any cell longer than **32,767 characters**. The CSV keeps the full text, and the script warns you which cells are affected (long discussions are the usual cause).

## Parameters

| Parameter | Description |
| --- | --- |
| `ProjectUrl` | Project URL (organization + project). Prompted if omitted. |
| `Pat` | SecureString PAT. Prompted (hidden) if omitted. Not written to disk or logs. |
| `OutputDirectory` | Where the CSV goes. Default: current directory. |
| `FieldMap` | Hashtable mapping a column name to a field reference name or display name. |
| `WorkItemType` | Export only these types, e.g. `-WorkItemType 'Requirement','Issue'`. |
| `ResolveFieldsOnly` | Print the column mapping and exit without exporting. |
| `KeepHtml` / `Utc` / `NoFormulaGuard` | See [Value formatting](#value-formatting). |
| `Force` | Overwrite a CSV of the same name. Without it, a second run on the same day writes `... (2).csv`. |
| `NonInteractive` | Stop with an error instead of prompting for missing input. |
| `ApiVersion` | `7.1` (default) or `7.0`. |
| `BatchSize` / `WiqlPageSize` | Tuning knobs (defaults 200 / 19999; these are the API maximums). |

The script also returns an object with `Path`, `WorkItems`, `UnresolvedColumns` and `DiscussionErrors`, which is handy in automation.

## How it works

1. `GET _apis/projects/{project}` checks the URL, PAT and access, and gets the exact project name used in the file name.
2. `GET {project}/_apis/wit/fields` gets the project's fields, which drive the column mapping.
3. WIQL `SELECT [System.Id] … WHERE [System.TeamProject] = @project AND [System.Id] > n` collects work item IDs page by page, which gets around the 20,000-row WIQL limit.
4. `POST workitemsbatch` with `$expand=Relations` reads every field plus links, up to 200 items per call. Linked items outside the export get one extra lookup for title, type and state.
5. `GET workItems/{id}/comments` (paged, `$expand=renderedText`) runs for each item, but only when `System.CommentCount` is above 0.
6. Rows are written to `<name>.csv.partial`, which is renamed when done, so a failed run never leaves a half-written CSV under the final name.

Throttling (429, using the `Retry-After` header), 408, 5xx and network errors are retried up to 6 times. A bad PAT gives a clear 401 error (the script sends `X-TFS-FedAuthRedirect: Suppress`, so Azure DevOps returns 401 instead of a sign-in page). If one item's comments can't be read, the run keeps going: that row's discussion cell gets `[ERROR reading discussion: …]` and the final summary counts these.

## Validation

`tests/Test-AdoExtractWorkItems.ps1` runs 95 checks with no live Azure DevOps calls. It needs PowerShell 7 and `python3`.

```powershell
pwsh -NoProfile -File ./ado-extract-workitems/tests/Test-AdoExtractWorkItems.ps1
```

- Unit checks: URL parsing (cloud, visualstudio.com, Server, rejected inputs), HTML-to-text, formula guard, dates, name normalization, ambiguous matches, and `-FieldMap` validation.
- End-to-end runs against `tests/mock_ado_server.py`, a mock of the endpoints above. The mock follows the documented API rules: WIQL `$top` paging, batch limits (`$expand` and `fields` can't be combined), comment continuation tokens, a 401 for a bad PAT, and a 404 for an unknown project. It also injects a 429 and a 503 to test retries. The checks cover the exact 47-column header and order, the file name, the BOM, and the value of every column type. They also cover cross-project link lookup, paged and chronological comments with deleted ones left out, skipping comment calls when an item has none, Unicode text, quotes, commas and newlines inside cells, rerun naming, `-Force`, `-WorkItemType`, `-ResolveFieldsOnly`, `-KeepHtml`, and the bad-PAT, unknown-project and `-NonInteractive` errors.
- PSScriptAnalyzer reports no findings, including its Windows PowerShell 5.1 syntax, command and type compatibility rules.

**Not verified here:** runs against a live Azure DevOps organization and on Windows PowerShell 5.1 itself. Before relying on the output, run it once with `-ResolveFieldsOnly` against your project, then spot-check a few rows against the web UI.

## Limitations

- Fields are matched by display name. A column whose field has a different name in your process (for example "Wave #") needs a `-FieldMap` entry. `-ResolveFieldsOnly` shows which columns these are.
- Development links show PR, commit and branch IDs, not repository names, because looking those up would need an extra Code (Read) scope.
- It exports the current field values and current comments only. Revision history and attachments are not included.
- Comments are read one request per commented item, so very large projects take a while. Throttling is handled automatically.

## Security

Use a short-lived, read-only PAT. The CSV can hold sensitive project content, so protect it and don't commit exports.
