# Azure DevOps Wiki Migration

`ado-migrate-wiki.ps1` copies the Markdown pages from one Azure DevOps wiki into a wiki in another Azure DevOps project. The source and target can be in the same organization or in different organizations.

The script uses the Azure DevOps REST API. It can add pages to an existing target wiki or create a project wiki when the requested target wiki does not exist.

## Migration behavior

The script:

- Connects to the source and target Azure DevOps organizations using personal access tokens (PATs).
- Finds a source wiki and recursively exports its complete page tree and Markdown content.
- Finds or creates the target project wiki.
- Creates parent pages before their child pages.
- Creates pages that do not exist in the target wiki.
- Updates pages that already exist at the same path, using the current ETag to prevent an unsafe concurrent update.
- Reads the migrated pages back from Azure DevOps and compares their paths and content with the source.
- Fails the run if a page cannot be imported or the target content does not match the source.
- Generates a detailed log, export report, and migration summary.

> [!WARNING]
> The source content replaces content at matching target paths, including the root page `/`. Pages in the target wiki whose paths do not occur in the source are retained. Test the migration in a nonproduction project or back up important target content before running it.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7 or later.
- Network access to `https://dev.azure.com`.
- At least Basic access in both Azure DevOps organizations.
- Permission to read the source project and wiki.
- Permission to read and update the target project and wiki.
- Permission to create the target project wiki if one does not already exist.

No PowerShell modules or Azure CLI extensions are required.

## Personal access tokens

The script prompts separately for a source PAT and a target PAT. The tokens can be the same when both projects are in the same organization and the token has access to both projects.

Recommended PAT scopes:

| Token      | Required access                              |
| ---------- | -------------------------------------------- |
| Source PAT | Project and Team: Read; Wiki: Read           |
| Target PAT | Project and Team: Read; Wiki: Read and Write |

The identity associated with the target PAT must also have suitable project and wiki permissions. Creating a project wiki can require elevated repository or project administration permissions, depending on the target project's security configuration.

PAT values are entered as secure console input. They are converted to an authorization header in memory and are not written to the generated reports or log.

## Usage

Open PowerShell in the directory containing the script and run:

```powershell
.\Migrate-AzureDevOpsWiki.ps1
```

The script prompts for:

1. Source organization name
2. Source project name
3. Source PAT
4. Target organization name
5. Target project name
6. Target PAT

Enter organization names only, such as `contoso`, rather than the full `https://dev.azure.com/contoso` URL.

### Select a source wiki

Most projects have one project wiki. If the source project exposes more than one wiki, the script stops rather than merging them and potentially overwriting pages with identical paths.

Select a wiki by name or ID:

```powershell
.\Migrate-AzureDevOpsWiki.ps1 -SourceWikiName "SourceProject.wiki"
```

### Select the target wiki

By default, the script targets the project wiki named after the target project. Use `-TargetWikiName` to select another wiki:

```powershell
.\ado-migrate-wiki.ps1 `
    -SourceWikiName "SourceProject.wiki" `
    -TargetWikiName "TargetProject.wiki"
```

The script adds content to the selected wiki. It does not delete target-only pages.

## Parameters

| Parameter        | Type   | Description                                                                                              |
| ---------------- | ------ | -------------------------------------------------------------------------------------------------------- |
| `SourceWikiName` | String | Optional source wiki name or ID. Required when the source project has multiple wikis.                    |
| `TargetWikiName` | String | Optional target wiki name. Defaults to the target project name and therefore its standard project wiki.  |
| `NoExecute`      | Switch | Loads the functions without starting an interactive migration. Intended for testing and troubleshooting. |

## Output files

Each run creates timestamped files in the current working directory:

| File                                       | Purpose                                                 |
| ------------------------------------------ | ------------------------------------------------------- |
| `WikiMigration_yyyyMMdd_HHmmss.log`        | Detailed execution log and errors                       |
| `WikiMigration_yyyyMMdd_HHmmss.md`         | Exported page inventory and Markdown content            |
| `WikiMigration_Summary_yyyyMMdd_HHmmss.md` | Target details, import counts, status, and output paths |

A successful exit means that every exported source page was written and its target content passed read-back validation. Review the summary and log before treating the migration as complete.

## Conflict and failure handling

- An existing page at the same path is updated with source content.
- The update uses the target page's current ETag. Azure DevOps rejects the update if another process changes the page between the read and write operations.
- A missing page is created.
- A failed page causes the overall migration to fail.
- A missing or ambiguous source wiki causes the migration to fail before import.
- A target read-back mismatch causes the migration to fail.
- The script exits with code `1` after an unhandled migration error.

The script is safe to rerun after correcting a failure. Existing migrated paths are updated and missing paths are created.

## Current limitations

This is a page-content migration, not a Git repository history migration. It does not preserve or migrate:

- Wiki Git commit history, authors, or timestamps
- Page revision history
- Page display order metadata such as `.order` files
- Wiki attachments or other binary files
- Wiki permissions and security settings
- Comments or other project configuration
- Deleted pages

Markdown links are copied as written. Links that contain source organization, project, wiki, or attachment URLs may still point to the source and should be reviewed after migration.

Only one source wiki is migrated per run. Run the script separately for additional source wikis and choose target paths or wikis carefully to avoid collisions.

For migrations that must preserve Git history, `.order` files, or attachments, use a Git-based wiki repository migration instead of this REST page migration.

## Troubleshooting

### `401 Unauthorized`

Verify that the PAT belongs to the organization being accessed, has not expired, and includes the required scopes.

### `403 Forbidden`

Verify the PAT scopes, the user's Azure DevOps access level, project membership, and wiki or repository permissions. Creating a missing project wiki can require more permission than updating an existing wiki.

### Multiple source wikis were found

Rerun the script with `-SourceWikiName` and supply the exact wiki name or ID shown in the error.

### Page update failed

A target page might have changed during migration, or the target identity might not have edit permission. Review the timestamped log for the page path and Azure DevOps response.

### Validation failed

The script successfully sent one or more writes but did not read back identical content. Review the failed paths in the log, correct the underlying permission or API problem, and rerun the migration.

## Security notes

- Use PATs with the minimum required scopes and short expiration periods.
- Do not place PATs directly in the script or command history.
- Revoke temporary migration PATs after the migration is accepted.
- Treat the detailed export report as potentially sensitive because it contains the full wiki page content.
