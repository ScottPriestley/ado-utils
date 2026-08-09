# Azure DevOps Default Area Configuration

A focused PowerShell script that sets a team's default Area Path in a target project, with sub-areas included.

## Using the tool

**What it does:** Updates a team's Area Path settings in Azure DevOps so that a chosen area becomes that team's default area, with "Include Sub Areas" turned on. This is the same setting you'd otherwise change by hand in Project Settings → Team Configuration → Areas.

**When you'd use it:** After creating or migrating an Area Path hierarchy into a project, you need the team's default area pointed at the right node (instead of the project root) so new work items land in the correct area automatically.

**What to have ready before starting:**

- The target project's URL (easiest), or the organization and project names.
- Team Administrator or Project Administrator access on the target team.
- A PAT with read/write access to work items and permission to modify team area settings.
- The area path must already exist for the team — this script does not create areas (use the [Area Path import tool](../ado-import-area-paths/README.md) first if it doesn't).

**How to run it:**

```powershell
# Preview first — see what would change without making the update.
./ado-set-default-area.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Target%20Project' `
  -WhatIf

# Apply the change.
./ado-set-default-area.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Target%20Project'
```

If you just give it the project URL, the script figures out the organization and project on its own, defaults the team to `<Project Name> Team`, and defaults the area path to the project name — so in the simplest case that's the only input you need.

**What to expect as output:** The script prints what it's doing and confirms the update by reading the setting back after making the change. It writes a run log as well. Nothing else in Azure DevOps is touched.

**What it will NOT do:**

- It will not create the Area Path if it doesn't already exist for the team — it only points the default at an existing, already-associated area.
- It will not change any other team setting (iterations, backlog configuration, boards, etc.).
- It does not claim to have validated the change through any means other than reading the setting back once after a real update.

## Technical reference

### Scope

- Sets a specific area path as the team default area.
- Enables Include Sub Areas = Yes for that team-area entry.
- Uses the repository's shared PAT, prompt, and JSONL logging conventions.

### Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Team Administrator or Project Administrator access for the target team.
- Read & write access to the target project team settings.
- A PAT with Work Items read/write access to the target organization/project and permission to modify team area settings.

### Authentication and inputs

The script uses the same precedence as the other repo scripts:

- `Pat` → `ADO_PAT` → hidden prompt
- `ProjectUrl` is the preferred input; if you supply it, the script infers the organization and project, defaults the team to `<Project Name> Team`, and defaults the area path to the project name
- If you omit `ProjectUrl`, the script falls back to the organization/project parameters or prompts for a project URL in the same style as the other repo scripts
- If Azure DevOps returns `401 Unauthorized` or `403 Forbidden`, verify the PAT is valid and that the identity has the necessary work item and team administration permissions
- If Azure DevOps returns `404 Not Found`, verify the project and team names are exact and that the PAT can access the project
- `-NonInteractive` fails rather than prompting for missing values

### Behavior

- Validates that the target team exists.
- Confirms the requested area already exists for the team.
- Sends a PATCH to the team-area endpoint to set the area as default and enable sub-areas.
- Performs a read-back check after a real write.

### Safety notes

- Use `-WhatIf` first to preview changes.
- The script does not create missing area paths; it only updates an already-associated team area.
- No live Azure DevOps validation is claimed by offline tests.
