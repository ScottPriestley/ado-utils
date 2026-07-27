<#
.SYNOPSIS
    Step 3: Rewrite widget settings (query GUIDs, project/team GUIDs, org URLs, names)
    and create the dashboards in the target team. Flags widgets that still carry
    unmapped source references.

.NOTES
    Requires: $env:ADO_TARGET_PAT  (scopes: Team Dashboards Manage, Work Items Read)
    Input:    <ExportDir>/dashboards/*.json, querymap.json, mapping.json
    Behavior: if a dashboard with the same name already exists on the target team,
              it is SKIPPED (delete it in the UI to re-import). Use -NameSuffix to
              import alongside instead.
#>
param(
    [Parameter(Mandatory)][string]$TargetOrg,
    [Parameter(Mandatory)][string]$TargetProject,
    [Parameter(Mandatory)][string]$TargetTeam,   # default team for dashboards with no teamMap entry
    [string]$ExportDir = "./export",
    [string]$NameSuffix = ""
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$TargetOrg = Get-OrgName $TargetOrg   # accept bare name or full URL
$headers  = Get-AdoAuthHeader -EnvVarName 'ADO_TARGET_PAT' -Purpose "TARGET org '$TargetOrg'"
$base     = "https://dev.azure.com/$(UrlEnc $TargetOrg)"
$projSeg  = UrlEnc $TargetProject
$mapping  = Read-Utf8Text (Join-Path $ExportDir 'mapping.json') | ConvertFrom-Json
if (-not ($mapping.sourceProjectId -match '^[0-9a-fA-F-]{36}$')) {
    throw "mapping.json has an invalid sourceProjectId. Run step 1 again or correct the mapping file."
}
if ([string]::IsNullOrWhiteSpace("$($mapping.sourceOrg)") -or
    [string]::IsNullOrWhiteSpace("$($mapping.sourceProjectName)")) {
    throw "mapping.json is missing sourceOrg or sourceProjectName. Run step 1 again or correct the mapping file."
}
$queryMap = @{}
(Read-Utf8Text (Join-Path $ExportDir 'querymap.json') | ConvertFrom-Json).psobject.Properties |
    ForEach-Object { $queryMap[$_.Name.ToLowerInvariant()] = $_.Value }

# --- Resolve target project + teams -------------------------------------------
$tproj  = Invoke-Ado -Headers $headers -Uri "$base/_apis/projects/$projSeg`?api-version=7.1"
$tteams = (Invoke-Ado -Headers $headers -Uri "$base/_apis/projects/$($tproj.id)/teams?`$top=200&api-version=7.1").value
$defaultTeam = $tteams | Where-Object { $_.name -eq $TargetTeam }
if (-not $defaultTeam) { throw "Team '$TargetTeam' not found in $TargetProject. Teams: $($tteams.name -join ', ')" }
$mappedTeamNames = @($mapping.teamMap | ForEach-Object {
    if ($_.targetTeamName -and $_.targetTeamName -notlike '<FILL*') { $_.targetTeamName }
} | Sort-Object -Unique)
$missingTeams = @($mappedTeamNames | Where-Object { $tteams.name -notcontains $_ })
if ($missingTeams.Count) {
    throw "Mapped target team(s) not found in '$TargetProject': $($missingTeams -join ', '). Available teams: $($tteams.name -join ', ')"
}

# --- Build the substitution table (source token -> target token) ---------------
$subs = [ordered]@{}
$subs["https://dev.azure.com/$($mapping.sourceOrg)"] = "https://dev.azure.com/$TargetOrg"
$subs[$mapping.sourceProjectId.ToLowerInvariant()]   = $tproj.id
$subs[$mapping.sourceProjectName]                    = $TargetProject
foreach ($k in $queryMap.Keys) { $subs[$k] = $queryMap[$k] }
foreach ($tm in @($mapping.teamMap)) {
    $targetName = if ($tm.targetTeamName -and $tm.targetTeamName -notlike '<FILL*') { $tm.targetTeamName } else { $TargetTeam }
    $tt = $tteams | Where-Object { $_.name -eq $targetName }
    if ($tt) { $subs[$tm.sourceTeamId.ToLowerInvariant()] = $tt.id }
}
if ($mapping.extraGuidMap) {
    $mapping.extraGuidMap.psobject.Properties | ForEach-Object { $subs[$_.Name.ToLowerInvariant()] = $_.Value }
}

function Apply-Subs {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    foreach ($k in $subs.Keys) {
        $Text = [regex]::Replace($Text, [regex]::Escape($k), [string]$subs[$k], 'IgnoreCase')
    }
    return $Text
}

# Source GUIDs that legitimately remain (target-side ids) shouldn't be flagged.
$knownTargetGuids = @($tproj.id) + @($tteams.id) + @($queryMap.Values) + @($subs.Values) |
    ForEach-Object { "$_".ToLowerInvariant() } | Sort-Object -Unique

# --- Import --------------------------------------------------------------------
$flags = @()
Get-ChildItem (Join-Path $ExportDir 'dashboards') -Filter *.json | ForEach-Object {
    $rec  = Read-Utf8Text $_.FullName | ConvertFrom-Json
    $dash = $rec.dashboard
    $name = "$($dash.name)$NameSuffix"

    # Which target team owns this dashboard?
    $tm = @($mapping.teamMap) | Where-Object { $_.sourceTeamId -eq $rec.sourceTeamId } | Select-Object -First 1
    $teamName = if ($tm -and $tm.targetTeamName -and $tm.targetTeamName -notlike '<FILL*') { $tm.targetTeamName } else { $TargetTeam }
    $teamSeg  = UrlEnc $teamName

    $existing = (Invoke-Ado -Headers $headers -Uri "$base/$projSeg/$teamSeg/_apis/dashboard/dashboards?api-version=7.1-preview.3").value
    if ($existing.name -contains $name) {
        Write-Host "SKIP [$teamName] '$name' - already exists on target." -ForegroundColor Yellow
        return
    }

    $widgets = @()
    foreach ($w in @($dash.widgets)) {
        $newSettings = Apply-Subs -Text $w.settings

        # Flag any GUID that survived substitution and isn't a known target id
        $leftover = (Get-GuidsInText -Text $newSettings) | Where-Object { $knownTargetGuids -notcontains $_ }
        if ($leftover) {
            if ($w.contributionId -like '*TcmChartWidget*') {
                # Test Plan/Suite chart - its ids are planId/suiteId/transformId, not queries.
                $flags += "[$teamName] $name / '$($w.name)': Test Plan chart - migrate the Test Plan/Suite separately, then point this chart at it. (refs $($leftover -join ', '))"
            } else {
                $flags += "[$teamName] $name / '$($w.name)' ($($w.contributionId)): unmapped refs $($leftover -join ', ') - widget will likely need manual reconfiguration."
            }
        }
        if ($w.contributionId -and $w.contributionId -notlike 'ms.*') {
            $flags += "[$teamName] $name / '$($w.name)': extension widget '$($w.contributionId)' - ensure the extension is installed in $TargetOrg."
        }

        $widgets += @{
            name            = $w.name
            contributionId  = $w.contributionId
            position        = @{ row = $w.position.row; column = $w.position.column }
            size            = @{ rowSpan = $w.size.rowSpan; columnSpan = $w.size.columnSpan }
            settings        = $newSettings
            settingsVersion = $w.settingsVersion
        }
    }

    $body = @{
        name        = $name
        description = "$($dash.description) [Migrated from $($mapping.sourceOrg)/$($mapping.sourceProjectName)]".Trim()
        widgets     = $widgets
    }
    $created = Invoke-Ado -Headers $headers -Method POST `
        -Uri "$base/$projSeg/$teamSeg/_apis/dashboard/dashboards?api-version=7.1-preview.3" -Body $body
    Write-Host "CREATED [$teamName] '$name' - $($widgets.Count)/$(@($dash.widgets).Count) widgets" -ForegroundColor Green
}

if ($flags) {
    Write-Host "`nManual follow-ups:" -ForegroundColor Yellow
    $flags | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
    Write-Utf8Text -Path (Join-Path $ExportDir 'import-flags.txt') -Text (($flags | Sort-Object -Unique) -join "`r`n")
    Write-Host "(also written to $(Join-Path $ExportDir 'import-flags.txt'))"
} else {
    Write-Host "`nNo unmapped references detected. Validate each imported dashboard and widget in Azure DevOps." -ForegroundColor Green
}
