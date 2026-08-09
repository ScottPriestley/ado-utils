# Azure DevOps Query Test Artifact Cleanup

`ado-delete-query-test-scripts.ps1` discovers Test Management artifacts returned by one saved query, writes a review manifest, and deletes reviewed Test Management artifacts only when apply safeguards are explicitly satisfied.

## Using the tool

**What it does:** Runs one saved query in Azure DevOps, works out which of the returned items are Test Management artifacts (Test Cases, Test Suites, Test Plans), and writes them to a CSV file so you can review them. It will not delete anything from Azure DevOps until you run it a second time with an explicit "apply" flag and type back an exact confirmation phrase the script shows you.

**When you'd use it:** Cleaning up test artifacts left behind after test-copy experiments, trial migrations, or any exercise that created disposable Test Cases/Suites/Plans you now want removed — driven by a single saved query that returns exactly those items.

**Before you start, have ready:**
- The Azure DevOps organization and project name.
- A saved query URL in that project that returns only the test artifacts you're considering for deletion.
- A Personal Access Token (PAT). For the review/discovery step, it only needs read access to work items and Test Management. If you intend to actually delete anything, you'll need a PAT with Test Management read & write as well.

**How to run it, step by step:**
1. **Review pass (no deletion possible):** Run the script with a query URL, a PAT, and a path for the manifest file. Do not pass `-Apply`.
   ```powershell
   ./ado-delete-query-test-scripts/ado-delete-query-test-scripts.ps1 `
     -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
     -Pat $pat `
     -ManifestPath './review.csv'
   ```
2. **Open the manifest CSV and check every row.** This is the list of exactly what would be deleted. If anything looks wrong, stop — do not proceed to apply.
3. **Apply pass:** Run the script again, this time with `-Apply`. The script will show you an exact confirmation phrase (it includes a count of items and a fingerprint of the manifest) and ask you to type it back before it deletes anything.
   ```powershell
   ./ado-delete-query-test-scripts.ps1 `
     -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
     -Pat $pat `
     -ManifestPath './review.csv' `
     -Apply
   ```

**The single most important thing to understand:** nothing is ever deleted on the first run. Discovery only ever writes a review file. Deletion only happens on a second, separate run where you pass `-Apply` **and** re-type an exact confirmation phrase that the script generates for that specific manifest. If the query results have changed since you reviewed the manifest, the apply run will refuse to proceed rather than delete something you didn't review.

**What to expect as output:**
- A review manifest CSV — the list of artifacts that would be deleted, for you to check.
- Log files recording what the script did (and, on an apply run, what it deleted or failed to delete).
- Only after a successful apply run: the reviewed Test Cases, Test Suites, and/or Test Plans are removed from Azure DevOps.

**What it will NOT do:**
- It will not delete anything without a prior manifest review and an explicit, typed confirmation.
- It will not delete ordinary work items outside Test Management — only Test Case/Suite/Plan artifacts it can map through the Test Management API.
- It will not guess at ambiguous matches (e.g., resolving a Test Plan or Suite by title alone) unless you explicitly turn that on.
- It has no undo, recycle bin, or rollback. Once an apply run succeeds, the deletion is final in Azure DevOps.

## Technical reference

### Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-delete-query-test-scripts.ps1` | Resolves a saved query, maps eligible Test Case/Test Suite/Test Plan results to Test Management API identifiers, writes a manifest, and applies reviewed deletes with confirmation. | Does not delete arbitrary Work Item Tracking records, bypass manifest review, resolve ambiguous results by default, or delete target data outside the reviewed result set. |

Relationship-query handling and title-based Test Plan/Test Suite resolution are opt-in.

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Query access and permissions to read returned work items and test artifacts.
- Work Items Read and Test Management Read for discovery.
- Test Management Read & write for apply mode.
- A reviewed manifest from the current query/result set before deletion.

### Authentication and minimum PAT scopes

`Pat` resolves from SecureString parameter -> `ADO_PAT` -> hidden prompt `Azure DevOps PAT (input hidden)`. `-PromptForPat` intentionally forces the hidden prompt and ignores `-Pat`/normal parameter precedence. `-NonInteractive` rejects missing input unless `-PromptForPat` is used in an interactive run. PATs are redacted and not cached.

Minimum scopes are Work Items Read and Test Management Read for discovery, with Test Management Read & write for deletion.

### Safety and rerun behavior

No deletion happens without `-Apply`. Apply mode requires a manifest, validates that the current query result set still matches the reviewed manifest expectations, requires the exact confirmation phrase, tracks prior successful deletes, and targets Test Management API objects only. Test Plan and Suite deletion can cascade inside Azure DevOps.

Discovery mode may refuse ambiguous relationship results unless `-AllowRelationshipResults` is set. Title-based mapping is disabled unless `-AllowTitleResolution` is supplied. There is no `-WhatIf`; discovery without `-Apply` is the preview/review step.

### Quick start

Manifest-only discovery:

```powershell
./ado-delete-query-test-scripts/ado-delete-query-test-scripts.ps1 `
  -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -Pat $pat `
  -ManifestPath './review.csv' `
  -LogDirectory './run-logs' `
  -NonInteractive
```

Apply after review:

```powershell
./ado-delete-query-test-scripts.ps1 `
  -QueryUrl 'https://dev.azure.com/contoso/Project/_queries/query/00000000-0000-0000-0000-000000000000/' `
  -Pat $pat `
  -ManifestPath './review.csv' `
  -Apply `
  -ConfirmationText 'DELETE TEST ARTIFACTS'
```

### Parameters and precedence

| Parameter | Description |
| --- | --- |
| `QueryUrl` | Saved query URL to inspect. Defaults to a checked-in `spriestley/TestBed` query URL in the script; always pass an explicit value for any other query. |
| `Pat` | Default role `SecureString` PAT. |
| `PromptForPat` | Forces hidden PAT prompt, bypassing `Pat` and environment fallback. |
| `DeleteWorkItemTypes` | Work item types eligible for deletion mapping. |
| `RequiredWorkItemType` | Optional strict type check for returned work items. |
| `ManifestPath` | Review manifest CSV path. |
| `LogPath` | Optional human-readable text log. |
| `ForceOverwriteManifest` | Allows replacing an existing manifest during discovery. |
| `AllowTitleResolution` | Enables title-based Test Plan/Suite resolution. |
| `AllowRelationshipResults` | Allows relationship-shaped query results. |
| `Apply` | Enables deletion after validation and confirmation. |
| `ConfirmationText` | Exact confirmation required in apply mode. |
| `SkipNotifications` | Requests notification bypass where supported. |
| `LogDirectory`, `NonInteractive` | Shared JSONL directory and no-prompt mode. |

PAT precedence is `-PromptForPat` when supplied, otherwise SecureString parameter -> `ADO_PAT` -> hidden prompt.

### Input formats

`QueryUrl` must be a `dev.azure.com` saved-query URL containing a GUID query ID. The script's checked-in default (`https://dev.azure.com/spriestley/TestBed/_queries/query/8d85e2d9-900c-485f-9b10-58430e66f827/`) is environment-specific and must be overridden for any other environment. The manifest is CSV generated by discovery mode; do not hand-build or reuse it for a different query or result set.

### Outputs and logs

Discovery writes the review manifest CSV and can write an unresolved CSV. Apply mode can write delete-results CSV and records previously successful deletes. `LogPath` is a legacy text log.

Every run creates `ado-delete-query-test-scripts-success log-<run-id>.jsonl` and `ado-delete-query-test-scripts-error log-<run-id>.jsonl` in `LogDirectory` or local `logs`, UTF-8 without BOM. Records include `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; secrets are redacted.

### Detailed workflow and behavior

The script resolves the query, validates result shape, reads returned work items, filters allowed types, resolves Test Management IDs, and writes a review manifest. Apply mode re-resolves current data, validates the manifest, confirms the exact phrase, skips already-recorded successes, and calls Test Management delete APIs for reviewed artifacts.

Partial failures are logged and fail the run so the manifest/results can be reviewed before another apply attempt.

### Verification checklist

- Run `pwsh -NoProfile -File ./tests/run-offline-checks.ps1`.
- Confirm the query returns only intended test artifacts.
- Review every manifest row and unresolved artifact before apply.
- Confirm the exact deletion phrase and understand Test Plan/Suite cascade behavior.
- After apply, review JSONL logs, delete-results CSV, and the query in Azure DevOps.

Offline checks make no live calls and cannot prove a delete target is safe.

### Troubleshooting

- Relationship query refused: use a flat query or deliberately pass `-AllowRelationshipResults`.
- Unresolved Test Plan/Suite: inspect titles/IDs and only enable title resolution when ambiguity is acceptable.
- Manifest exists: use a new path or `-ForceOverwriteManifest` during discovery.
- Apply mismatch: rerun discovery and review the new manifest before deleting.
- `401`/`403`: verify PAT scopes and Test Management permissions.

### Limitations

This is a guarded cleanup tool, not a recycle-bin or rollback system. It cannot delete arbitrary WIT records, cannot guarantee cascade side effects are desirable, and does not validate business ownership beyond the reviewed manifest.

### Security

Use a short-lived PAT only for the reviewed cleanup window. Protect manifests, delete results, and logs because they contain artifact IDs, titles, and project/query details. Never embed PATs in scripts or saved manifests.

### Related workflows

Use after test-copy experiments or cleanup planning. For copying test artifacts, see [Test Management copy](../ado-copy-test-management/README.md). Shared conventions are in the [root README](../README.md).
