# Azure DevOps Test Management Copy

`ado-copy-test-management.ps1` copies Azure DevOps Test Plans, suite trees, Test Case work items, rich-text fields, and suite membership from a source project to a target project. It is additive, resumable, and designed for reviewed migrations rather than full-fidelity Test Management cloning.

## Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-copy-test-management.ps1` | Creates or reuses target Test Plans, recreates suite hierarchy, creates Test Case work items, copies selected rich-text fields, maps state, and links mapped cases into mapped suites. | Does not migrate history, attachments, test runs/results, permissions, identities, shared-step artifacts, reusable shared steps, or cross-organization configuration IDs. |

Dynamic and requirement suites are copied as static suites unless `-DoNotConvertDynamicSuitesToStatic` is supplied. Source discovery can fall back from Test Plan REST APIs to Work Item Tracking APIs when licensing or service visibility blocks source Test Plan reads.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source Test Management Read and Work Items Read.
- Target Test Management Read & write and Work Items Read & write.
- Target project process, Test Case type, Area/Iteration paths, and test configurations reviewed before write runs.

## Authentication and minimum PAT scopes

`SourcePat` resolves from SecureString parameter -> `ADO_SOURCE_PAT` -> hidden prompt `Source Azure DevOps PAT (input hidden)`. `TargetPat` resolves through `ADO_TARGET_PAT` and `Target Azure DevOps PAT (input hidden)`. `-NonInteractive` rejects missing values. PATs are registered for redaction and are not stored.

Source needs Test Management Read plus Work Items Read. Target needs Test Management Read & write plus Work Items Read & write. Licensing and project visibility can still affect Test Plan API access.

## Safety and rerun behavior

The script uses `SupportsShouldProcess`, so `-WhatIf` previews supported create/link operations. It never deletes. State is saved after successful artifact creation and maps source plan IDs, suite IDs, Test Case work item IDs, and suite-case memberships to target artifacts. Reruns reuse mapped items and may patch supported fields on existing mapped target Test Cases.

If source point configuration IDs cannot be used in the target suite, the script retries suite membership with target defaults and logs a warning. A final partial outcome means warnings or partial fidelity concerns require review.

## Quick start

```powershell
./ado-copy-test-management/ado-copy-test-management.ps1 `
  -SourceProjectUrl 'https://dev.azure.com/source/Source%20Project' `
  -TargetProjectUrl 'https://dev.azure.com/target/Target%20Project' `
  -SourcePlanIds @(123) `
  -SourcePat $sourcePat `
  -TargetPat $targetPat `
  -LogDirectory './run-logs' `
  -NonInteractive
```

Preview:

```powershell
./ado-copy-test-management.ps1 `
  -SourceProjectUrl 'https://dev.azure.com/source/Source%20Project' `
  -TargetProjectUrl 'https://dev.azure.com/target/Target%20Project' `
  -SourcePat $sourcePat -TargetPat $targetPat -WhatIf
```

## Parameters and precedence

| Parameter | Description |
| --- | --- |
| `SourceProjectUrl` / `TargetProjectUrl` | Preferred full project URLs. If omitted, split org/project values are used or prompted as `Source URL` / `Target URL`. |
| `SourceOrg`, `SourceProject`, `TargetOrg`, `TargetProject` | Split endpoint inputs for callers that already have org/project values. |
| `SourcePlanIds` | Optional numeric source plan IDs; omitted means all visible source plans. |
| `SourcePat` / `TargetPat` | Role-specific `SecureString` PATs. |
| `StatePath` | Default `ado-copy-test-management.state.json` beside the script. |
| `LogPath` | Optional legacy text log path. |
| `AdditionalFieldReferenceNames` | Extra rich-text field reference names to copy. |
| `PreserveClassificationPaths` | Keeps source classification paths instead of rewriting to target root. |
| `SkipNotifications` | Adds bypass flags where the relevant REST call supports it. |
| `DoNotConvertDynamicSuitesToStatic` | Prevents dynamic/requirement suite conversion to static suites. |
| `CopyStandaloneTestCasesWhenSuitesUnavailable` | Copies visible Test Cases without suite links when suite membership cannot be discovered. |
| `LogDirectory`, `NonInteractive` | Shared logging directory and no-prompt automation mode. |

PAT precedence is SecureString parameter -> environment variable -> hidden prompt. Non-secret project inputs use parameter -> prompt.

## Input formats

Project URLs must look like `https://dev.azure.com/{org}/{project}` or the supported legacy organization URL form. `SourcePlanIds` is a PowerShell integer array. Additional fields are Azure DevOps field reference names.

## Outputs and logs

The state JSON is the primary rerun artifact. Optional `LogPath` writes a human-readable text log. The script prints a JSON summary.

Every run creates `ado-copy-test-management-success log-<run-id>.jsonl` and `ado-copy-test-management-error log-<run-id>.jsonl` under `LogDirectory` or local `logs`, UTF-8 without BOM. Records include `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; secrets are redacted.

## Detailed workflow and behavior

The script resolves endpoints and credentials, loads or initializes state, discovers source plans through Test Plan APIs, and falls back to Work Item Tracking discovery for known source discovery failures. It creates missing target plans, recreates suites parent-first, creates Test Case work items with supported fields, patches rich text, and adds mapped cases to mapped suites.

State is written after each successful creation unless running under `-WhatIf`. The final readout is scoped to the operations performed; it is not a full comparison of Test Management history, configurations, or execution data.

## Verification checklist

- Run `pwsh -NoProfile -File ./tests/run-offline-checks.ps1`.
- Confirm source/target URLs, selected plan IDs, PAT scopes, and target process readiness.
- Use `-WhatIf` in a nonproduction target before writes.
- Review JSONL logs, text log if used, final JSON summary, and warnings.
- Manually inspect representative plans, suites, copied Test Cases, rich-text steps, and suite membership.

Offline checks do not call Azure DevOps and do not prove live Test Management fidelity.

## Troubleshooting

- Source Test Plan visibility errors: verify license/project visibility; the WIT fallback may still run with reduced suite fidelity.
- Missing configurations: review warning logs; target defaults may be used for suite membership.
- Missing fields/paths: prepare target process/classification paths or use preservation only when paths already exist.
- Partial result: retain state, fix the cause, and rerun.

## Limitations

No rollback, deletes, history, attachments, runs/results, identity mapping, permissions, complete shared-step fidelity, or configuration-ID migration. Dynamic/requirement suite behavior is not preserved as dynamic behavior by default.

## Security

Use short-lived least-privilege PATs. Protect state and logs because they can disclose plan names, suite names, Test Case text, IDs, and configuration details. Never store PATs in source control.

## Related workflows

Prepare target [work item types](../ado-migrate-workitemtype/README.md), [Area Paths](../ado-import-area-paths/README.md), and [Iteration Paths](../ado-import-iterations/README.md) first. Shared conventions and project-order guidance are in the [root README](../README.md).
