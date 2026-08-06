# Azure DevOps Default Area Configuration

A focused PowerShell script updates a target project's team area configuration so the selected area becomes the default area with sub-areas included.

## Scope

- Sets a specific area path as the team default area.
- Enables Include Sub Areas = Yes for that team-area entry.
- Uses the repository’s shared PAT, prompt, and JSONL logging conventions.

## Prerequisites

- Windows PowerShell 5.1 or PowerShell 7+.
- Team Administrator or Project Administrator access for the target team.
- Read & write access to the target project team settings.
- A PAT with Work Items read/write access to the target organization/project and permission to modify team area settings.

## Authentication and inputs

The script uses the same precedence as the other repo scripts:

- `Pat` → `ADO_PAT` → hidden prompt
- `ProjectUrl` is the preferred input; if you supply it, the script infers the organization and project, defaults the team to `<Project Name> Team`, and defaults the area path to the project name
- If you omit `ProjectUrl`, the script falls back to the organization/project parameters or prompts for a project URL in the same style as the other repo scripts
- If Azure DevOps returns `401 Unauthorized` or `403 Forbidden`, verify the PAT is valid and that the identity has the necessary work item and team administration permissions
- If Azure DevOps returns `404 Not Found`, verify the project and team names are exact and that the PAT can access the project
- `-NonInteractive` fails rather than prompting for missing values

## Quick start

```powershell
./ado-set-default-area.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Target%20Project' `
  -WhatIf
```

```powershell
./ado-set-default-area.ps1 `
  -ProjectUrl 'https://dev.azure.com/contoso/Target%20Project'
```

## Behavior

- Validates that the target team exists.
- Confirms the requested area already exists for the team.
- Sends a PATCH to the team-area endpoint to set the area as default and enable sub-areas.
- Performs a read-back check after a real write.

## Safety notes

- Use `-WhatIf` first to preview changes.
- The script does not create missing area paths; it only updates an already-associated team area.
- No live Azure DevOps validation is claimed by offline tests.
