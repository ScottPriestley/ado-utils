# Azure DevOps Wiki Tools

Three standalone PowerShell scripts for copying Azure DevOps wiki page content directly between projects or moving it through local Markdown files.

| Script | Purpose | Best used when |
| --- | --- | --- |
| `ado-migrate-wiki.ps1` | Copies one wiki directly from a source project to a target project | Both Azure DevOps environments are available during the migration |
| `ado-extract-wiki.ps1` | Exports one or all visible source wikis to local Markdown files | You need a backup, reviewable files, or an offline handoff |
| `ado-load-wiki.ps1` | Loads one manifest-backed Markdown export into a target project wiki | Content was previously created by `ado-extract-wiki.ps1` |

Each script is self-contained. The direct migration script does not call the Extract or Load scripts, and the Extract and Load scripts can be used independently on different machines.

## Features

- Discovers nested Azure DevOps wiki page trees recursively.
- Retrieves every page body through a separate content request.
- Excludes the synthetic, non-writable `/` wiki root.
- Preserves wiki page paths and parent-child hierarchy.
- Creates parent pages before child pages.
- Creates missing target pages and updates matching target paths.
- Uses the current target ETag when updating an existing page.
- Migrates files and images referenced through `.attachments/...` links during direct wiki migration.
- Reads target pages back after writing and fails on content differences.
- Supports project names, wiki names, and page paths containing spaces.
- Requires no Azure CLI extensions or third-party PowerShell modules.

The Extract and Load workflow adds:

- UTF-8 Markdown files without a byte order mark.
- Windows-safe local filenames.
- A JSON manifest that preserves the original wiki paths and metadata.
- SHA-256 validation before loading any exported Markdown file.
- Protection against duplicate paths, path traversal, missing files, and manifest count mismatches.

> [!WARNING]
> Existing target pages at matching paths are replaced with source content. Target-only pages are retained; none of these scripts delete pages. Back up important target content or test against a nonproduction project first.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7 or later.
- Network access to `https://dev.azure.com` for operations that contact Azure DevOps.
- Read access to each source project and wiki.
- Read and write access to each target project and wiki.
- Permission to create a project wiki when the target project does not already have one.

The scripts prompt for personal access tokens (PATs) as secure console input. PAT values are converted to Basic authorization headers in memory and are not written to output files or logs.

Use PATs with the minimum access needed:

| Operation | PAT access |
| --- | --- |
| Extract | Read the source project and wiki |
| Load | Read the target project; read and write the target wiki |
| Direct migration | Source read access plus target read and write access |

The source and target PAT can be the same for a direct migration when one identity has suitable access to both projects.

## Quick Start

Run scripts from PowerShell in the repository directory. Omitted connection parameters are requested interactively, and PATs are always prompted securely.

### Direct migration

```powershell
.\ado-migrate-wiki.ps1
```

### Extract to Markdown

```powershell
.\ado-extract-wiki.ps1 `
    -Organization "source-org" `
    -Project "Source Project" `
    -WikiName "Source Project.wiki" `
    -OutputPath ".\wiki-export"
```

### Load the extracted Markdown

Pass the folder containing `wiki-export-manifest.json`:

```powershell
.\ado-load-wiki.ps1 `
    -SourcePath ".\wiki-export\Source Project.wiki" `
    -Organization "target-org" `
    -Project "Target Project"
```

## Direct Migration

`ado-migrate-wiki.ps1` reads one source wiki and writes it directly to a target project wiki. It supports projects in the same organization or different organizations.
It also copies files and images referenced from source Markdown with `.attachments/...` links before writing pages, so those relative wiki image/file links can resolve in the target wiki.
If a source page contains a stale `.attachments/...` reference that no longer exists in the source wiki repository or its history, the script logs a warning, skips that missing attachment, and continues creating or updating pages. Use `-StrictAttachmentValidation` when you want missing attachments to fail the run before any target page writes.

```powershell
.\ado-migrate-wiki.ps1 `
    -SourceOrganization "source-org" `
    -SourceProject "Source Project" `
    -SourceWikiName "Source Project.wiki" `
    -TargetOrganization "target-org" `
    -TargetProject "Target Project" `
    -TargetWikiName "Target Project.wiki"
```

The script prompts for any omitted organization or project value and separately prompts for the source and target PATs. If the source project exposes multiple wikis, specify `-SourceWikiName`; the script stops rather than merging them implicitly.

When `-TargetWikiName` is omitted, the first existing project wiki is used. If no project wiki exists, one is created using the target project name. When `-TargetWikiName` is supplied but no matching wiki exists, a project wiki is created with that name.

### Migration parameters

| Parameter | Description |
| --- | --- |
| `SourceOrganization` | Source Azure DevOps organization name. Prompts when omitted. |
| `SourceProject` | Source project name or ID. Prompts when omitted. |
| `SourceWikiName` | Optional source wiki name or ID. Required when more than one source wiki is visible. |
| `TargetOrganization` | Target Azure DevOps organization name. Prompts when omitted. |
| `TargetProject` | Target project name or ID. Prompts when omitted. |
| `TargetWikiName` | Optional target wiki name or ID. Selects an existing match or names a new project wiki. |
| `StrictAttachmentValidation` | Fails the direct migration before target writes if a referenced source attachment cannot be resolved. By default, unresolved attachments are skipped with warnings so page reloads can continue. |
| `AllowMissingAttachments` | Explicitly allows missing attachments to be skipped. Rarely needed — this is already the default unless `-StrictAttachmentValidation` is set. |
| `NoExecute` | Loads the script functions without starting the interactive migration. Intended for testing. |

### Migration output

Every run creates a timestamped log in the current working directory:

```text
WikiMigration_yyyyMMdd_HHmmss.log
```

The log records page retrieval, create or update operations, validation, counts, and errors. A successful run ends only after every target page returns content identical to its source page.

## Extract to Markdown

`ado-extract-wiki.ps1` exports all visible wikis by default. Use `-WikiName` to export a single wiki by name or ID.

```powershell
.\ado-extract-wiki.ps1 -Organization "source-org" -Project "Source Project"
```

If `-OutputPath` is omitted, the script creates a timestamped folder in the current working directory:

```text
WikiExport_<project>_yyyyMMdd_HHmmss
```

Each wiki receives its own subfolder. Page hierarchy is represented by folders, while the page itself is represented by a Markdown file:

```text
WikiExport_Source Project_20260723_120000/
|-- Source Project.wiki/
|   |-- Home.md
|   |-- Delivery.md
|   |-- Delivery/
|   |   `-- Release-Checklist.md
|   `-- wiki-export-manifest.json
```

The manifest records the source organization, project, wiki identity and type, page count, original wiki path, relative Markdown filename, content length, SHA-256 hash, order value, and Git item path.

Characters that Windows does not permit in filenames are replaced with `_`. Reserved Windows names such as `CON` and `NUL` are prefixed with `_`. The manifest remains the source of truth for mapping those local names back to their original Azure DevOps paths.

The extractor stops instead of overwriting data when two pages map to the same case-insensitive local path or when two wiki names map to the same local folder.

### Extract parameters

| Parameter | Description |
| --- | --- |
| `Organization` | Source Azure DevOps organization name. Prompts when omitted. |
| `Project` | Source project name or ID. Prompts when omitted. |
| `WikiName` | Optional wiki name or ID. All visible wikis are exported when omitted. |
| `OutputPath` | Optional output root. Defaults to a timestamped folder in the current directory. |
| `NoExecute` | Loads the script functions without starting extraction. Intended for testing. |

## Load from Markdown

`ado-load-wiki.ps1` accepts one wiki export produced by `ado-extract-wiki.ps1`. Before connecting to Azure DevOps, it validates the manifest, every referenced file, every SHA-256 hash, the declared page count, and all resolved file paths.

`-SourcePath` can point directly to the wiki folder containing `wiki-export-manifest.json`, or to a parent folder containing exactly one manifest. If more than one manifest is found, select one wiki folder explicitly.

Paths pasted with surrounding single or double quotes are accepted:

```powershell
.\ado-load-wiki.ps1 -SourcePath '"C:\Exports\Source Project.wiki"'
```

The loader uses the target project's existing project wiki when available. If no suitable project wiki exists, it creates one named after the target project. Pages are uploaded parent-first, existing pages are updated with ETags, and all content is read back and compared by SHA-256.

### Load parameters

| Parameter | Description |
| --- | --- |
| `SourcePath` | Extracted wiki folder or a parent containing exactly one manifest. Prompts when omitted. |
| `Organization` | Target Azure DevOps organization name. Prompts when omitted. |
| `Project` | Target project name or ID. Prompts when omitted. |
| `NoExecute` | Loads the script functions without starting the load. Intended for testing. |

## Update and Recovery Behavior

- A missing target page is created.
- An existing target page at the same path is updated with source content.
- Existing updates include the target page's current ETag in `If-Match`.
- Azure DevOps rejects the update if another process changes the page between the read and write requests.
- Parent pages are processed before nested child pages.
- Target pages that do not occur in the source are left unchanged.
- A failed API request, source validation error, or target content mismatch fails the run.
- Runs are safe to repeat after correcting the cause of a failure: existing paths are updated and missing paths are created.

For the Extract and Load workflow, do not edit a Markdown file without also deliberately updating its manifest hash. A hash mismatch is treated as possible corruption and stops the load before any target changes are made. To migrate intentionally edited files, regenerate the export or update the manifest through a controlled process.

## Troubleshooting

### `401 Unauthorized`

Confirm that the PAT belongs to the organization being accessed, has not expired, and has the required access.

### `403 Forbidden`

Confirm the user's Azure DevOps access level, project membership, PAT access, and wiki or repository permissions. Creating a missing project wiki can require more permission than editing an existing one.

### Multiple source wikis were found

Use `-SourceWikiName` with `ado-migrate-wiki.ps1`, or `-WikiName` with `ado-extract-wiki.ps1`.

### Multiple wiki exports were found

Point `ado-load-wiki.ps1 -SourcePath` to one wiki subfolder containing a single `wiki-export-manifest.json`.

### SHA-256 validation failed

The Markdown file no longer matches the export manifest. Restore the original file or regenerate the export. This check runs before Azure DevOps target writes begin.

### ETag or page update failed

The page may have changed during the migration, or the target identity may not have edit permission. Confirm the target page state and rerun after resolving the conflict.

### Target validation failed

The write completed but Azure DevOps did not return identical page content. Review the reported path, correct the permission or API issue, and rerun the operation.

## Limitations

These tools migrate current Markdown page content and hierarchy through the Azure DevOps REST API. They do not preserve or migrate:

- Wiki Git commit history, authors, timestamps, or page revisions.
- `.order` files or exact navigation ordering.
- Attachments or other binary files that are not referenced with relative `.attachments/...` links during direct migration.
- Attachments or other binary files in the offline Extract and Load workflow.
- Wiki permissions and security settings.
- Comments, deleted pages, or other project configuration.

Markdown links are copied as written. Absolute links to source organizations, projects, wikis, or attachments can continue to point to the source and should be reviewed after migration.

For migrations that must preserve Git history, `.order` files, or attachments, use a Git-based Azure DevOps wiki repository migration instead.

## Security

- Use short-lived PATs with the minimum required access.
- Do not place PATs in scripts, command-line parameters, source control, or shell history.
- Revoke temporary migration PATs after validating the result.
- Treat exported Markdown and manifests as potentially sensitive project data.
- Store exports in an access-controlled location and remove them when they are no longer required.
