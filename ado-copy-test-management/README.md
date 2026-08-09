<div align="center">

# Azure DevOps Test Management Copy

**Copies Azure DevOps Test Plans, suite trees, Test Case work items, rich-text fields, and suite membership from a source project to a target project.**

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-5391FE?style=flat-square&logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows-0078D4?style=flat-square)
![Azure DevOps](https://img.shields.io/badge/Azure%20DevOps-0078D4?style=flat-square&logo=azuredevops&logoColor=white)
![Dry Run](https://img.shields.io/badge/DryRun-WhatIf%20Supported-718096?style=flat-square)

</div>

It is additive, resumable, and designed for reviewed migrations rather than full-fidelity Test Management cloning.

## Table of Contents

- [Using the tool](#using-the-tool)
- [Technical reference](#technical-reference)
  - [Scripts, capabilities, and exclusions](#scripts-capabilities-and-exclusions)
  - [Prerequisites](#prerequisites)
  - [Authentication and minimum PAT scopes](#authentication-and-minimum-pat-scopes)
  - [Safety and rerun behavior](#safety-and-rerun-behavior)
    - [State file schema](#state-file-schema)
    - [Network-level retry](#network-level-retry)
    - [Fallback if the target rejects Test Plan API writes](#fallback-if-the-target-rejects-test-plan-api-writes)
  - [Quick start](#quick-start)
  - [Parameters and precedence](#parameters-and-precedence)
  - [Input formats](#input-formats)
  - [Outputs and logs](#outputs-and-logs)
  - [Detailed workflow and behavior](#detailed-workflow-and-behavior)
    - [Fields copied to each Test Case](#fields-copied-to-each-test-case)
    - [Standalone Test Cases (`-CopyStandaloneTestCasesWhenSuitesUnavailable`)](#standalone-test-cases--copystandalonetestcaseswhensuitesunavailable)
  - [Verification checklist](#verification-checklist)
  - [Troubleshooting](#troubleshooting)
  - [Limitations](#limitations)
  - [Security](#security)
  - [Related workflows](#related-workflows)

---

## Using the tool

```mermaid
graph LR
    A[Source Test Plans & Suites] --> B[ado-copy-test-management]
    B --> C[Target Plans, Suites & Test Cases]

    style A fill:#4a5568,color:#fff
    style B fill:#718096,color:#fff
    style C fill:#4a5568,color:#fff
```

**What it does:** Copies Test Plans, their suite structure, and the Test Case work items in them from one Azure DevOps project to another. It recreates the plan/suite hierarchy in the target, creates matching Test Case work items, copies over the key fields (title, description, steps, etc.), and puts each copied case back into the right suite.

**When to use it:** You're moving Test Management content — plans, suites, test cases — from a source project to a new or different target project, and you want the structure and case content to show up ready for review rather than starting from scratch.

> [!WARNING]
> **What it will NOT do:** It does not copy test run history, test results, attachments, permissions, or user identities. It doesn't copy reusable shared steps as shared-step artifacts. It doesn't migrate configuration IDs across organizations. It never deletes anything in either project. This is a one-way, additive copy — not a full clone and not a backup/restore tool.

**Before you start, have ready:**
- The source project URL and the target project URL (e.g. `https://dev.azure.com/yourorg/YourProject`).
- A Personal Access Token (PAT) for the source org with **Test Management (Read)** and **Work Items (Read)** access.
- A PAT for the target org with **Test Management (Read & write)** and **Work Items (Read & write)** access.
- The target project's process, Test Case work item type, Area/Iteration paths, and test configurations should already be set up before you run this for real — the tool doesn't create any of that for you.
- Optionally, the specific Test Plan ID(s) you want to copy. If you don't give any, it copies every plan visible in the source project.

**How to run it:**

1. Open PowerShell in the repo folder.
2. Have your source and target PATs ready (you'll be prompted for them if you don't pass them in).
3. Run the script, pointing it at your source and target project URLs:

```powershell
./ado-copy-test-management/ado-copy-test-management.ps1 `
  -SourceProjectUrl 'https://dev.azure.com/source/Source%20Project' `
  -TargetProjectUrl 'https://dev.azure.com/target/Target%20Project' `
  -SourcePlanIds @(123) `
  -LogDirectory './run-logs'
```

4. If you'd rather see what the script *would* do before it changes anything, add `-WhatIf` and it will preview the creates without actually writing to the target.
5. If something goes wrong partway through, just run the same command again — it remembers what it already copied and picks up where it left off, rather than duplicating work.

**What to expect afterward:**
- A summary printed at the end of the run telling you what was created and whether anything needs review.
- A small state file that the script uses to track what's already been copied (this is also what makes reruns safe).
- A log folder with a plain success log and an error/warning log you can skim for anything that needs a second look.
- If the run finishes with warnings (for example, a suite configuration that couldn't be matched exactly), that's flagged as a "partial" outcome — worth a manual look at the affected plan or suite rather than assuming everything transferred perfectly.

> [!TIP]
> A couple of behavioral quirks worth knowing before you run this against real data: dynamic and requirement-based suites get converted into plain static suites automatically. If you don't want that conversion, there's a switch to prevent it — but if you use that switch and the tool then hits a dynamic/requirement suite, it stops the whole run right there rather than skipping past it, so you'd need to rerun without the switch to get past that plan.

## Technical reference

### Scripts, capabilities, and exclusions

| Script | Capability | Exclusions |
| --- | --- | --- |
| `ado-copy-test-management.ps1` | Creates or reuses target Test Plans, recreates suite hierarchy, creates Test Case work items, copies selected rich-text fields, maps state, and links mapped cases into mapped suites. | Does not migrate history, attachments, test runs/results, permissions, identities, shared-step artifacts, reusable shared steps, or cross-organization configuration IDs. |

Dynamic and requirement suites are copied as static suites unless `-DoNotConvertDynamicSuitesToStatic` is supplied; with that switch, the script does not skip such a suite, it throws and stops the run the first time it encounters one, so the run must be repeated without the switch to continue past it. Source discovery can fall back from Test Plan REST APIs to Work Item Tracking APIs when licensing (`TF400409`) or service-specific project visibility (`TF200016`) blocks source Test Plan reads. Every REST call also retries automatically on transient `408`/`429`/`5xx` responses.

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Source Test Management Read and Work Items Read.
- Target Test Management Read & write and Work Items Read & write.
- Target project process, Test Case type, Area/Iteration paths, and test configurations reviewed before write runs.

### Authentication and minimum PAT scopes

`SourcePat` resolves from SecureString parameter -> `ADO_SOURCE_PAT` -> hidden prompt `Source Azure DevOps PAT (input hidden)`. `TargetPat` resolves through `ADO_TARGET_PAT` and `Target Azure DevOps PAT (input hidden)`. `-NonInteractive` rejects missing values. PATs are registered for redaction and are not stored.

Source needs Test Management Read plus Work Items Read. Target needs Test Management Read & write plus Work Items Read & write. Licensing and project visibility can still affect Test Plan API access.

### Safety and rerun behavior

The script uses `SupportsShouldProcess`, so `-WhatIf` previews supported create/link operations. It never deletes. State is saved after successful artifact creation and maps source plan IDs, suite IDs, Test Case work item IDs, and suite-case memberships to target artifacts. Reruns reuse mapped items and may patch supported fields on existing mapped target Test Cases.

> [!NOTE]
> If source point configuration IDs cannot be used in the target suite, the script retries suite membership with target defaults and logs a warning. A final partial outcome means warnings or partial fidelity concerns require review.

#### State file schema

<details>
<summary><strong>State JSON layout</strong> — the four buckets tracked in <code>StatePath</code></summary>

`StatePath` is a single JSON object with four buckets, each keyed by string:

| Bucket | Key | Value |
| --- | --- | --- |
| `plans` | source plan id | `{ targetPlanId, targetRootSuiteId, name }` |
| `suites` | `"<sourcePlanId>/<sourceSuiteId>"` | `{ targetPlanId, targetSuiteId, name }` |
| `cases` | source Test Case work item id | `{ targetCaseId, title }` |
| `suiteCases` | `"<sourcePlanId>/<sourceSuiteId>/<sourceCaseId>"` | `{ targetPlanId, targetSuiteId, targetCaseId }` |

The file is written after every successful create (atomically, via a
`.tmp` file and rename) unless the run is under `-WhatIf`. A rerun reloads
this file and skips any key already present, so a suite, case, or suite-case
link created by a prior run is never recreated.

</details>

#### Network-level retry

<details>
<summary><strong>Retry behavior</strong> — status codes, attempt count, and backoff</summary>

Every Test Plan/Work Item Tracking REST call (`GET`, `POST`, `PATCH`) retries
automatically, independent of the state-file rerun behavior above. A `408`,
`429`, or any `5xx` response is retried up to 4 attempts total, waiting
`min(30, 2^(attempt-1))` seconds between attempts. Any other status, or the
4th failed attempt, throws immediately. A `401`/`403` on the final attempt
adds a hint that source needs Test Management Read plus Work Items Read and
target needs Test Management Read & write plus Work Items Read & write.

</details>

#### Fallback if the target rejects Test Plan API writes

> [!NOTE]
> If creating the target Test Plan through the Test Plan REST API fails with an authorization error (`UnauthorizedAccessException`, "not authorized to access this API", or an HTTP 403 on the create call), and the source plan has at most one suite level (no nested suite hierarchy to reproduce), the script falls back to creating the target Test Plan as a plain Work Item Tracking `Test Plan` work item instead, copying its title and (if the target process defines it) `System.Description`. This is logged as a warning and counts toward the run's warning total. If the source plan has more than one suite level, the script cannot fall back (a WIT work item cannot represent a suite tree) and throws, asking for Test Management Read & write on the target before rerunning.

### Quick start

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

### Parameters and precedence

<details>
<summary><strong>Parameter reference</strong> — every parameter this script accepts</summary>

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

</details>

PAT precedence is SecureString parameter -> environment variable -> hidden prompt. Non-secret project inputs use parameter -> prompt.

### Input formats

Project URLs must look like `https://dev.azure.com/{org}/{project}` or the supported legacy organization URL form. `SourcePlanIds` is a PowerShell integer array. Additional fields are Azure DevOps field reference names.

### Outputs and logs

The state JSON is the primary rerun artifact. Optional `LogPath` writes a human-readable text log. The script prints a JSON summary.

Every run creates `ado-copy-test-management-success log-<run-id>.jsonl` and `ado-copy-test-management-error log-<run-id>.jsonl` under `LogDirectory` or local `logs`, UTF-8 without BOM. Records include `timestampUtc`, `level`, `script`, `runId`, `operation`, `outcome`, `target`, `message`, `errorType`, and `statusCode`; secrets are redacted.

### Detailed workflow and behavior

The script resolves endpoints and credentials, loads or initializes state, discovers source plans through Test Plan APIs, and falls back to Work Item Tracking discovery for known source discovery failures (`TF400409` license, `TF200016` project visibility). It creates missing target plans (falling back to a Work Item Tracking Test Plan if the target rejects Test Plan API writes), recreates suites parent-first, creates Test Case work items with supported fields, patches rich text, and adds mapped cases to mapped suites.

#### Fields copied to each Test Case

<details>
<summary><strong>Default field set</strong> — copied fields and the additional-fields switch</summary>

The default field set copied to every created Test Case is not limited to
rich-text fields; it is:

```text
System.Title, System.Description, System.Tags, System.AreaPath,
System.IterationPath, Microsoft.VSTS.Common.Priority,
Microsoft.VSTS.Common.Activity, Microsoft.VSTS.TCM.Steps,
Microsoft.VSTS.TCM.LocalDataSource, Microsoft.VSTS.TCM.Parameters,
Microsoft.VSTS.TCM.AutomationStatus
```

`-AdditionalFieldReferenceNames` appends any field reference name to this
list (deduplicated); it is documented as a way to add custom rich-text
fields, but it accepts any field reference name. A field absent from the
target process is skipped with a warning rather than failing the create.
`System.Title` is always set from the source title (falling back to
"Copied Test Case `<id>`" if blank); `System.AreaPath`/`System.IterationPath`
are set from the rest of the list and rebased unless
`-PreserveClassificationPaths` is used.

</details>

#### Standalone Test Cases (`-CopyStandaloneTestCasesWhenSuitesUnavailable`)

<details>
<summary><strong>Fallback scope and behavior</strong> — when the project-wide standalone fallback triggers</summary>

This is a project-wide fallback, not a per-plan one: after processing every
loaded plan, the script checks whether **any** plan/suite in the run had
visible suite-case membership. Only if none did does it query every
`Test Case` work item in the source project (via WIQL) and, when the switch
is supplied, create each one as a standalone target Test Case not attached to
any suite. Standalone cases are created using the target's default
Area/Iteration Path rather than a rebased source path. Without the switch,
this condition is logged as a warning and does not create anything.

</details>

State is written after each successful creation unless running under `-WhatIf`. The final readout is scoped to the operations performed; it is not a full comparison of Test Management history, configurations, or execution data.

### Verification checklist

- Run `pwsh -NoProfile -File ./tests/run-offline-checks.ps1`.
- Confirm source/target URLs, selected plan IDs, PAT scopes, and target process readiness.
- Use `-WhatIf` in a nonproduction target before writes.
- Review JSONL logs, text log if used, final JSON summary, and warnings.
- Manually inspect representative plans, suites, copied Test Cases, rich-text steps, and suite membership.

Offline checks do not call Azure DevOps and do not prove live Test Management fidelity.

### Troubleshooting

<details>
<summary>Common errors and what they mean</summary>

- Source Test Plan visibility errors (`TF400409` missing Test Plans license, `TF200016`/`ProjectDoesNotExist` project visibility): the script falls back to Work Item Tracking discovery automatically; suite fidelity depends on the source Test Plan/Test Suite/Test Case work items actually being linked to each other.
- Target Test Plan API rejects plan creation (403/unauthorized): the script falls back to creating the plan as a Work Item Tracking Test Plan work item, but only when the source plan has a single suite level; a multi-level suite hierarchy makes the run throw and ask for Test Management Read & write on the target.
- Repeated `401`/`403` on other calls after 4 retry attempts: verify the PAT scope matches the section above; the error message is annotated with the required scopes.
- Missing configurations: review warning logs; target defaults may be used for suite membership.
- Missing fields/paths: prepare target process/classification paths or use preservation only when paths already exist.
- Partial result: retain state, fix the cause, and rerun.

</details>

### Limitations

> [!NOTE]
> No rollback, deletes, history, attachments, runs/results, identity mapping, permissions, complete shared-step fidelity, or configuration-ID migration. Dynamic/requirement suite behavior is not preserved as dynamic behavior by default.

### Security

> [!WARNING]
> Use short-lived least-privilege PATs. Protect state and logs because they can disclose plan names, suite names, Test Case text, IDs, and configuration details. Never store PATs in source control.

### Related workflows

Prepare target [work item types](../ado-migrate-workitemtype/README.md), [Area Paths](../ado-import-area-paths/README.md), and [Iteration Paths](../ado-import-iterations/README.md) first. Shared conventions and project-order guidance are in the [root README](../README.md).
