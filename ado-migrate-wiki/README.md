# Azure DevOps Wiki Tools

Three PowerShell scripts either copy one wiki directly or move current Markdown page content through a validated local export manifest.

## Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-extract-wiki.ps1` | Exports one/all visible wikis to UTF-8 Markdown plus a SHA-256 manifest. | Does not export attachments, Git history, permissions, revisions, or `.order` files. |
| `ado-load-wiki.ps1` | Validates one manifest-backed export, creates/reuses a project wiki, and creates/updates pages. | Does not load attachments or accept edited files whose hashes disagree. |
| `ado-migrate-wiki.ps1` | Directly copies pages and referenced relative `.attachments/...` files. | Does not copy unreferenced binaries, history, permissions, or exact navigation order. |

The synthetic `/` root is excluded. Target-only pages are retained; none of these scripts deletes pages.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source project/wiki (Code/Wiki) Read; target project metadata and Code/Wiki Read & write.
- Permission to create a project wiki if the target has none.
- Sufficient local disk/access controls for exports.

## Authentication and minimum PAT scopes

Extract uses `SourcePat` → `ADO_SOURCE_PAT` → `Source Azure DevOps PAT (input hidden)`. Load uses the target equivalents. Direct migration resolves both independently. Missing organizations use the exact shared source/target organization prompts; project prompts are `Source project name`, `Source project name or ID`, or `Target project name or ID` as used by each entry script. `-NonInteractive` rejects missing input. PATs are not cached or stored in manifests/logs.

Use source Project/team metadata and Code/Wiki Read, and target Project/team metadata plus Code/Wiki Read & write. Creating a project wiki can require additional project repository administration permission beyond PAT scope.

## Safety and rerun behavior

Missing pages are created. Existing pages with byte-identical content are skipped. Non-identical matching pages are updated with the current ETag; a concurrent edit causes a conflict rather than an unconditional overwrite. Target-only pages remain. Direct migration skips an already-identical attachment and otherwise writes the referenced attachment; strict missing-attachment validation can fail before page writes.

These scripts have no `-WhatIf`. `-NoExecute` only loads functions and records a preview outcome for offline testing; it does not inspect or preview a remote migration. Repeatability does not mean rollback or preservation of target edits: non-identical matching pages are intentionally replaced.

## Quick start

```powershell
./ado-extract-wiki.ps1 `
  -Organization 'source-org' -Project 'Source Project' `
  -WikiName 'Source Project.wiki' -OutputPath './wiki-export'

./ado-load-wiki.ps1 `
  -SourcePath './wiki-export/Source Project.wiki' `
  -Organization 'target-org' -Project 'Target Project'

./ado-migrate-wiki.ps1 `
  -SourceOrganization 'source-org' -SourceProject 'Source Project' `
  -SourceWikiName 'Source Project.wiki' `
  -TargetOrganization 'target-org' -TargetProject 'Target Project' `
  -TargetWikiName 'Target Project.wiki'
```

## Parameters and precedence

| Script | Parameters |
| --- | --- |
| Extract | `Organization`, `Project`, `WikiName`, `OutputPath`, `NoExecute`, `SourcePat`, `LogDirectory`, `NonInteractive`. |
| Load | `SourcePath`, `Organization`, `Project`, `NoExecute`, `TargetPat`, `ApiBaseUri` (default `https://dev.azure.com`, test seam), common logging switches. |
| Direct | `SourceOrganization`, `SourceProject`, `SourceWikiName`, `TargetOrganization`, `TargetProject`, `TargetWikiName`, `ApiBaseUri`, `AllowMissingAttachments`, `StrictAttachmentValidation`, `NoExecute`, source/target PATs, common logging switches. |

Explicit parameters precede prompts; PAT precedence is SecureString → environment → prompt. Extract defaults to all visible wikis and a timestamped `WikiExport_<project>_<timestamp>` directory. Multiple source wikis require an explicit name for direct migration. Load accepts a wiki folder or a parent containing exactly one manifest. `StrictAttachmentValidation` overrides the default/explicit allowance of missing attachments.

## Input formats

Each extracted wiki folder contains Markdown files and `wiki-export-manifest.json`. The manifest records source organization/project/wiki identity/type, declared page count, and per-page wiki path, relative filename, content length, SHA-256, order value, and Git item path. Local names are made Windows-safe; the manifest remains authoritative.

Load rejects missing/multiple manifests, duplicate wiki paths, count mismatch, path traversal/out-of-root resolution, missing files, and SHA-256/content-length mismatch before target API writes. A source path pasted with matching surrounding quotes is normalized. Direct migration reads live page trees/content and `.attachments/...` references; absolute/source-specific Markdown links are copied as written.

## Outputs and logs

Extract writes one subdirectory per selected wiki with Markdown and manifest files, using UTF-8 without BOM. Load/direct write no local content export.

Every run creates JSONL files named `<script-base>-success log-<run-id>.jsonl` and `<script-base>-error log-<run-id>.jsonl` in `LogDirectory` or local `logs`, UTF-8 without BOM. Records contain `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; registered secrets and authorization/query-token values are redacted.

There is no `WikiMigration_yyyyMMdd_HHmmss.log` contract in the current implementation; rely on the shared JSONL paths printed at completion.

## Detailed workflow and behavior

Extract discovers wiki/page trees recursively, requests each page body separately, maps paths to collision-safe local files, computes SHA-256, and writes the manifest only with the collected records. Case-insensitive local path collisions terminate the run rather than overwrite content.

Load fully validates local data before connecting, resolves/creates a project wiki, processes parents before children, skips identical content, sends ETag-protected updates for differences, then freshly reads each written page and compares content/hash.

Direct migration resolves source/target projects/wikis, recursively reads pages, optionally validates all referenced attachments before target page writes, copies or skips attachments, creates/updates pages parent-first, and freshly compares target page content. By default a missing referenced attachment is warned/skipped; `StrictAttachmentValidation` makes it fatal before page writes. Attachment and page verification is scoped to processed content, not repository history/order.

## Verification checklist

- Run both repository offline commands.
- Inspect export manifest counts and hashes before transfer.
- Test load/direct migration in a nonproduction project.
- Review both JSONL logs, missing-attachment warnings, and every updated page path.
- Compare representative rendered Markdown, links, images, hierarchy, and target-only content manually.
- Verify repository/wiki permissions and navigation ordering separately.

Offline tests exercise manifest/path/hash, API-base seam, identical skip, attachment, failure, and representative read-back behavior without live Azure DevOps calls.

## Troubleshooting

- Multiple source wikis: pass `SourceWikiName`/`WikiName`.
- Multiple manifests: point `SourcePath` at one wiki subfolder.
- SHA-256 mismatch: restore/regenerate the export; manual Markdown edits are intentionally rejected.
- ETag conflict: inspect the concurrent target change and decide whether overwriting on rerun is intended.
- Missing attachment: fix the source reference or run without strict validation if skipping is acceptable.
- `401`/`403`: verify PAT organization/scope plus wiki/repository permissions.
- Read-back mismatch: inspect normalization/service behavior for the reported path; success is not recorded for that item.

## Limitations

No workflow migrates Git history, authors/timestamps, revisions, `.order`, permissions, comments, deleted pages, or target-only cleanup. Offline extract/load omits all attachments; direct mode includes only referenced relative `.attachments/...` paths. Absolute links remain source-specific. No live validation is claimed.

## Security

Use short-lived least-privilege PATs. Treat Markdown, manifests, attachments, logs, and page paths as sensitive. Keep exports access-controlled, do not embed PATs, and securely remove temporary exports when organizational policy requires it.

## Related workflows

Run after target process/structure and [dashboard migration](../ado-dashboard-migration/readme.md) so copied links can be reviewed against final destinations. See the [root workflow](../README.md) for ordering.
