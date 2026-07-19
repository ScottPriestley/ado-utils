<#
.SYNOPSIS
    Step 1: Export all dashboards + widgets from a source ADO project, resolve which
    GUIDs in widget settings are work item queries, and produce an inventory report.

.NOTES
    Requires: $env:ADO_SOURCE_PAT  (scopes: Work Items Read, Team Dashboards Read)
    Output:   <OutDir>/dashboards/*.json   raw dashboard payloads (one per team+dashboard)
              <OutDir>/queries.json        referenced queries with folder path + WIQL
              <OutDir>/mapping.json        template for step 3 (fill in target values)
              <OutDir>/inventory.md        human review report — read before proceeding
#>
param(
    [Parameter(Mandatory)][string]$Org,
    [Parameter(Mandatory)][string]$Project,
    [string]$OutDir = "./export"
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$headers = Get-AdoAuthHeader -EnvVarName 'ADO_SOURCE_PAT'
$base    = "https://dev.azure.com/$(UrlEnc $Org)"
$projSeg = UrlEnc $Project

New-Item -ItemType Directory -Force -Path $OutDir, (Join-Path $OutDir 'dashboards') | Out-Null

# --- Project + teams -----------------------------------------------------------
$proj  = Invoke-Ado -Headers $headers -Uri "$base/_apis/projects/$projSeg`?api-version=7.1"
$teams = (Invoke-Ado -Headers $headers -Uri "$base/_apis/projects/$($proj.id)/teams?`$top=200&api-version=7.1").value
Write-Host "Project '$Project' ($($proj.id)) — $($teams.Count) team(s)"

# --- Dashboards + widgets ------------------------------------------------------
$allGuids   = [System.Collections.Generic.HashSet[string]]::new()
$widgetRows = @()
$dashCount  = 0

foreach ($team in $teams) {
    $teamSeg = UrlEnc $team.name
    $list = Invoke-Ado -Headers $headers -Uri "$base/$projSeg/$teamSeg/_apis/dashboard/dashboards?api-version=7.1-preview.3"
    foreach ($d in $list.value) {
        $dash = Invoke-Ado -Headers $headers -Uri "$base/$projSeg/$teamSeg/_apis/dashboard/dashboards/$($d.id)?api-version=7.1-preview.3"
        $dashCount++
        $safe = ("{0}__{1}" -f $team.name, $dash.name) -replace '[\\/:*?"<>|]', '_'
        $record = [pscustomobject]@{
            sourceTeamName = $team.name
            sourceTeamId   = $team.id
            dashboard      = $dash
        }
        $record | ConvertTo-Json -Depth 50 | Set-Content -Path (Join-Path $OutDir "dashboards/$safe.json") -Encoding utf8

        foreach ($w in @($dash.widgets)) {
            $guids = Get-GuidsInText -Text ("$($w.settings) $($w.artifactId)")
            $guids | ForEach-Object { [void]$allGuids.Add($_) }
            $widgetRows += [pscustomobject]@{
                Team = $team.name; Dashboard = $dash.name; Widget = $w.name
                ContributionId = $w.contributionId; Guids = $guids
            }
        }
        Write-Host "  exported: [$($team.name)] $($dash.name) — $(@($dash.widgets).Count) widget(s)"
    }
}

# --- Resolve GUIDs: which ones are work item queries? --------------------------
$queries    = @()
$unresolved = @()
foreach ($g in $allGuids) {
    if ($g -eq $proj.id.ToLowerInvariant()) { continue }
    if ($teams.id -contains $g) { continue }
    try {
        $q = Invoke-Ado -Headers $headers -Uri "$base/$projSeg/_apis/wit/queries/$g`?`$expand=wiql&api-version=7.1"
        if (-not $q.isFolder) {
            $queries += [pscustomobject]@{ id = $g; name = $q.name; path = $q.path; wiql = $q.wiql }
        }
    }
    catch { $unresolved += $g }
}
$queries | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $OutDir 'queries.json') -Encoding utf8

# --- Mapping template for step 3 ----------------------------------------------
[pscustomobject]@{
    sourceOrg         = $Org
    sourceProjectName = $Project
    sourceProjectId   = $proj.id
    targetOrg         = "<FILL: e.g. HSOUSCloud>"
    targetProjectName = "<FILL: e.g. Internal Hub>"
    targetProjectId   = "<AUTO: filled by step 3>"
    teamMap           = @( $teams | ForEach-Object {
                            @{ sourceTeamName = $_.name; sourceTeamId = $_.id
                               targetTeamName = "<FILL or leave to use -TargetTeam>"; targetTeamId = "" } } )
    extraGuidMap      = @{}   # any additional sourceGuid -> targetGuid substitutions
} | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $OutDir 'mapping.json') -Encoding utf8

# --- Inventory report ----------------------------------------------------------
$extWidgets = $widgetRows | Where-Object { $_.ContributionId -and $_.ContributionId -notlike 'ms.*' }
$byContrib  = $widgetRows | Group-Object ContributionId | Sort-Object Count -Descending

$report = @()
$report += "# Export inventory — $Org / $Project"
$report += ""
$report += "- Dashboards exported: **$dashCount** (across $($teams.Count) team(s))"
$report += "- Widgets total: **$($widgetRows.Count)**"
$report += "- Distinct queries referenced: **$($queries.Count)** (see queries.json)"
$report += "- GUIDs found in settings that are NOT this project / a team / a query: **$($unresolved.Count)**"
$report += ""
$report += "## Widget types"
$report += "| Contribution ID | Count |"
$report += "|---|---|"
$byContrib | ForEach-Object { $report += "| $($_.Name) | $($_.Count) |" }
$report += ""
$report += "## Marketplace-extension widgets (install these extensions in the TARGET org before import)"
if ($extWidgets) {
    $extWidgets | Group-Object ContributionId | ForEach-Object {
        $report += "- ``$($_.Name)`` — $($_.Count) widget(s)"
    }
} else { $report += "- none — all widgets are built-in" }
$report += ""
$report += "## Unresolved GUIDs (likely build defs, repos, pipelines, or cross-project refs — will need manual handling)"
if ($unresolved) {
    foreach ($g in $unresolved) {
        $where = ($widgetRows | Where-Object { $_.Guids -contains $g } |
                  ForEach-Object { "[$($_.Team)] $($_.Dashboard) / $($_.Widget)" }) -join '; '
        $report += "- ``$g`` — used by: $where"
    }
} else { $report += "- none" }
$report -join "`n" | Set-Content -Path (Join-Path $OutDir 'inventory.md') -Encoding utf8

Write-Host "`nDone. REVIEW $(Join-Path $OutDir 'inventory.md') before running step 2." -ForegroundColor Green
