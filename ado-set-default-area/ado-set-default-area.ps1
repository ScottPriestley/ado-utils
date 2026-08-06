<#
.SYNOPSIS
    Sets the default Azure DevOps team area path and include-sub-areas flag for a target project team.

.DESCRIPTION
    Resolves the target project and team, reads the team's current area-path configuration,
    and updates the default area path to the requested area while enabling include-sub-areas.
    The script is preview-friendly via -WhatIf and uses canonical run logging.

.EXAMPLE
    .\ado-set-default-area.ps1 `
      -Organization 'https://dev.azure.com/contoso' `
      -Project 'My Project' `
      -Team 'My Team' `
      -AreaPath 'My Project\Finance'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProjectUrl,

    [string]$Organization,

    [string]$Project,

    [string]$Team,

    [string]$AreaPath,

    [SecureString]$Pat,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$null = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'set-default-area'; throw $_ }

function Resolve-OrganizationUrl([string]$InputValue) {
    if ([string]::IsNullOrWhiteSpace($InputValue)) {
        throw 'Azure DevOps organization is required.'
    }

    $value = $InputValue.Trim().TrimEnd('/')
    if ($value -match '^https?://dev\.azure\.com/([^/?#]+)$') {
        return "https://dev.azure.com/$($Matches[1])"
    }
    if ($value -match '^https?://([^.]+)\.visualstudio\.com$') {
        return "https://dev.azure.com/$($Matches[1])"
    }
    if ($value -match '^[^/\s]+$') {
        return "https://dev.azure.com/$value"
    }

    throw 'Azure DevOps organization must be an organization name or URL (for example, contoso or https://dev.azure.com/contoso).'
}

function Resolve-ProjectContext([string]$ProjectUrlValue, [string]$OrganizationValue, [string]$ProjectValue) {
    if ([string]::IsNullOrWhiteSpace($ProjectUrlValue) -and [string]::IsNullOrWhiteSpace($OrganizationValue) -and [string]::IsNullOrWhiteSpace($ProjectValue)) {
        $ProjectUrlValue = Read-AdoInput -Prompt (Get-AdoPrompt -Name TargetProjectUrl)
    }

    if (-not [string]::IsNullOrWhiteSpace($ProjectUrlValue)) {
        $parsed = ConvertFrom-AdoProjectUrl -Url $ProjectUrlValue -Role Default
        return [pscustomobject]@{
            OrganizationUrl = "https://dev.azure.com/$($parsed.Org)"
            Project         = $parsed.Project
        }
    }

    if ([string]::IsNullOrWhiteSpace($OrganizationValue)) {
        $OrganizationValue = Read-AdoInput -Prompt (Get-AdoPrompt -Name Organization)
    }
    if ([string]::IsNullOrWhiteSpace($ProjectValue)) {
        $ProjectValue = Read-AdoInput -Prompt 'Azure DevOps project name'
    }

    return [pscustomobject]@{
        OrganizationUrl = Resolve-OrganizationUrl -InputValue $OrganizationValue
        Project         = $ProjectValue
    }
}

function Resolve-DefaultTeamName([string]$ProjectName) {
    if ([string]::IsNullOrWhiteSpace($ProjectName)) {
        throw 'Azure DevOps project name is required to resolve the default team name.'
    }

    return "$($ProjectName.Trim()) Team"
}

function Get-TeamFieldValuesUrl([string]$BaseOrganizationUrl, [string]$ProjectName, [string]$TeamName) {
    $projectUri = [Uri]::EscapeDataString($ProjectName)
    $teamUri = [Uri]::EscapeDataString($TeamName)
    return "$($BaseOrganizationUrl.TrimEnd('/'))/$projectUri/$teamUri/_apis/work/teamsettings/teamfieldvalues"
}

function ConvertTo-TeamFieldAreaValue([string]$AreaPathValue) {
    if ([string]::IsNullOrWhiteSpace($AreaPathValue)) {
        throw 'Area path is required.'
    }

    return $AreaPathValue.Trim().TrimStart([char]'\')
}

function Get-TeamFieldAreaCandidates([string]$AreaPathValue, [string]$ProjectName) {
    $normalized = ConvertTo-TeamFieldAreaValue -AreaPathValue $AreaPathValue
    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($normalized)

    if ($normalized -eq $ProjectName) {
        $candidates.Add("\$ProjectName")
    } elseif ($normalized.StartsWith("$ProjectName\")) {
        $candidates.Add("\$normalized")
    } else {
        $candidates.Add("$ProjectName\$normalized")
        $candidates.Add("\$ProjectName\$normalized")
    }

    $candidates | Select-Object -Unique
}

function Resolve-RequestedAreaPath([string]$InputValue, [string]$ProjectName) {
    $trimmed = if ($null -eq $InputValue) { '' } else { $InputValue.Trim() }
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return "\$ProjectName"
    }

    if ($trimmed.StartsWith('\')) {
        return $trimmed
    }

    if ($trimmed -eq $ProjectName) {
        return "\$ProjectName"
    }

    return "\$ProjectName\$trimmed"
}

function Get-HttpStatusCode([object]$ErrorRecord) {
    if ($null -eq $ErrorRecord) { return $null }
    try {
        if ($null -ne $ErrorRecord.Exception.Response.StatusCode) { return [int]$ErrorRecord.Exception.Response.StatusCode }
    } catch { }
    try {
        if ($null -ne $ErrorRecord.Exception.StatusCode) { return [int]$ErrorRecord.Exception.StatusCode }
    } catch { }
    $null
}

function Get-AdoApiErrorMessage([object]$ErrorRecord, [string]$ProjectName, [string]$TeamName) {
    $statusCode = Get-HttpStatusCode -ErrorRecord $ErrorRecord
    if ($statusCode -eq 401 -or $statusCode -eq 403) {
        return "Azure DevOps rejected the supplied PAT for team area updates. Verify the PAT is valid for the organization and has Work Items read/write access plus permission to administer team settings for project '$ProjectName' and team '$TeamName'."
    }

    if ($statusCode -eq 404) {
        return "Azure DevOps could not find team area settings for project '$ProjectName' and team '$TeamName'. Verify both names are exact and that the PAT can access the project."
    }

    if ($null -ne $ErrorRecord) {
        return [string]$ErrorRecord.Exception.Message
    }

    return 'Azure DevOps returned an unexpected error.'
}

$projectContext = Resolve-ProjectContext -ProjectUrlValue $ProjectUrl -OrganizationValue $Organization -ProjectValue $Project
$Organization = $projectContext.OrganizationUrl
$Project = $projectContext.Project
if ([string]::IsNullOrWhiteSpace($Team)) {
    $Team = Resolve-DefaultTeamName -ProjectName $Project
}
if ([string]::IsNullOrWhiteSpace($AreaPath)) {
    $AreaPath = $Project
}

$resolvedAreaPath = Resolve-RequestedAreaPath -InputValue $AreaPath -ProjectName $Project
Write-Host "Using project '$Project' and team '$Team'."
Write-Host "Using area path '$resolvedAreaPath'."

$Pat = Resolve-AdoPat -Pat $Pat -Role Default
$plainPat = ConvertFrom-AdoSecureString $Pat
if ([string]::IsNullOrWhiteSpace($plainPat)) {
    throw 'A non-empty Azure DevOps PAT is required to update team area settings.'
}

try {
    $headers = @{ 
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $plainPat))
        Accept = 'application/json'
        'Content-Type' = 'application/json'
    }

    $teamFieldValuesUrl = Get-TeamFieldValuesUrl -BaseOrganizationUrl $Organization -ProjectName $Project -TeamName $Team
    try {
        $existingValues = (Invoke-WebRequest -Method Get -Uri "${teamFieldValuesUrl}?api-version=7.1" -Headers $headers -TimeoutSec 30).Content | ConvertFrom-Json
    } catch {
        throw (Get-AdoApiErrorMessage -ErrorRecord $_ -ProjectName $Project -TeamName $Team)
    }

    $resolvedAreaValue = ConvertTo-TeamFieldAreaValue -AreaPathValue $resolvedAreaPath
    $areaCandidates = @(Get-TeamFieldAreaCandidates -AreaPathValue $resolvedAreaPath -ProjectName $Project)
    $existingAreaValue = $existingValues.values | Where-Object {
        $areaCandidates -contains $_.value
    } | Select-Object -First 1

    if (-not $existingAreaValue) {
        throw "The team does not currently have area path '$resolvedAreaPath'."
    }

    $values = @($existingValues.values | ForEach-Object {
        [pscustomobject]@{
            value = $_.value
            includeChildren = if ($_.value -eq $resolvedAreaValue -or $_.value -eq $existingAreaValue.value) { $true } else { [bool]$_.includeChildren }
        }
    })

    $matchingAreaValueCount = ($values | Where-Object { $areaCandidates -contains $_.value } | Measure-Object).Count
    if ($matchingAreaValueCount -eq 0) {
        $values = @($values + [pscustomobject]@{ value = $existingAreaValue.value; includeChildren = $true })
    }

    $updateBody = @{ 
        defaultValue = $existingAreaValue.value
        values = $values
    } | ConvertTo-Json -Compress

    if ($PSCmdlet.ShouldProcess($resolvedAreaPath, 'Update Azure DevOps team area path settings')) {
        Invoke-WebRequest -Method Patch -Uri "${teamFieldValuesUrl}?api-version=7.1" -Headers $headers -Body $updateBody -TimeoutSec 30 | Out-Null
    }

    if ($WhatIfPreference) {
        Write-Host "Previewed team area update for '$resolvedAreaPath'."
        Complete-AdoScriptRun -Outcome preview -Operation 'set-default-area'
        return
    }

    $updatedValues = (Invoke-WebRequest -Method Get -Uri "${teamFieldValuesUrl}?api-version=7.1" -Headers $headers -TimeoutSec 30).Content | ConvertFrom-Json
    $updatedArea = $updatedValues.values | Where-Object { $areaCandidates -contains $_.value } | Select-Object -First 1
    if (-not $updatedArea) {
        throw "Verification failed. Area path '$resolvedAreaPath' was not returned by the team field values endpoint."
    }

    Write-Host "Updated team area path '$resolvedAreaPath' to be the default and include sub-areas."
    Complete-AdoScriptRun -Outcome succeeded -Operation 'set-default-area'
}
finally {
    if ($plainPat) { $plainPat = $null }
}
