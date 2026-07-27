<#
.SYNOPSIS
    Step 1: Export all dashboards + widgets from a source ADO project, resolve which
    GUIDs in widget settings are work item queries, and produce an inventory report.

.NOTES
    Requires: $env:ADO_SOURCE_PAT  (scopes: Work Items Read, Team Dashboards Read)
    Output:   <OutDir>/dashboards/*.json   raw dashboard payloads (one per team+dashboard)
              <OutDir>/queries.json        referenced queries with folder path + WIQL
              <OutDir>/mapping.json        template for step 3 (fill in target values)
              <OutDir>/inventory.md        human review report - read before proceeding
#>
param(
    [Parameter(Mandatory)][string]$Org,
    [Parameter(Mandatory)][string]$Project,
    [string]$OutDir = "./export"
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$Org = Get-OrgName $Org   # accept bare name or full URL
$headers = Get-AdoAuthHeader -EnvVarName 'ADO_SOURCE_PAT' -Purpose "SOURCE org '$Org'"
$base    = "https://dev.azure.com/$(UrlEnc $Org)"
$projSeg = UrlEnc $Project

New-Item -ItemType Directory -Force -Path $OutDir, (Join-Path $OutDir 'dashboards') | Out-Null

# --- Helpers -------------------------------------------------------------------
# Walk the source project's *Shared Queries* tree and index every query by name.
# Used to recover widgets whose stored query GUID has drifted (query rebuilt /
# dashboards copied from another project) but whose name still matches a live query.
function Get-SharedQueryIndex {
    param([hashtable]$Headers, [string]$Base, [string]$ProjSeg)
    $index   = @{}   # lowercased name -> list of @{ id; name; path; wiql }
    $folders = New-Object System.Collections.Queue
    $folders.Enqueue('Shared%20Queries')   # already URL-encoded seed path
    while ($folders.Count) {
        $fid = $folders.Dequeue()
        try {
            $node = Invoke-Ado -Headers $Headers `
                -Uri "$Base/$ProjSeg/_apis/wit/queries/$fid`?`$depth=1&`$expand=wiql&api-version=7.1"
        } catch { continue }
        foreach ($c in @($node.children)) {
            if ($c.isFolder) { $folders.Enqueue($c.id) }
            elseif (-not [string]::IsNullOrWhiteSpace($c.name)) {
                $k = "$($c.name)".ToLowerInvariant()
                if (-not $index.ContainsKey($k)) { $index[$k] = @() }
                $index[$k] += [pscustomobject]@{
                    id = "$($c.id)".ToLowerInvariant(); name = $c.name; path = $c.path; wiql = $c.wiql }
            }
        }
    }
    return $index
}

# Extract query references a widget depends on, with candidate name hints.
# kind: 'query' (reliable names), 'chart' (best-effort names), 'test' (not a query).
# Multiple names are returned because ADO may store a disambiguated queryName
# (e.g. "Issues - Open ... - a15aa") alongside a clean lastArtifactName; we also
# add a suffix-stripped variant so name matching survives the " - <hex>" tag.
function Get-QueryRefsFromWidget {
    param($Widget)
    $refs = @()
    if ([string]::IsNullOrWhiteSpace($Widget.settings)) { return $refs }
    try { $cfg = $Widget.settings | ConvertFrom-Json } catch { return $refs }
    $cid = "$($Widget.contributionId)"
    $mk = {
        param($guid, $raw, $kind)
        $names = @()
        foreach ($n in $raw) {
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            $names += $n
            $stripped = [regex]::Replace($n, '\s-\s[0-9a-fA-F]{4,8}$', '')
            if ($stripped -ne $n) { $names += $stripped }
        }
        @{ guid = "$guid".ToLowerInvariant(); names = @($names | Select-Object -Unique); kind = $kind }
    }
    if     ($cid -like '*QueryScalarWidget*' -and $cfg.queryId)       { $refs += (& $mk $cfg.queryId       @($cfg.queryName, $cfg.lastArtifactName)       'query') }
    elseif ($cid -like '*WitViewWidget*'     -and $cfg.query.queryId) { $refs += (& $mk $cfg.query.queryId @($cfg.query.queryName, $cfg.lastArtifactName) 'query') }
    elseif ($cid -like '*WitChartWidget*'    -and $cfg.groupKey)      { $refs += (& $mk $cfg.groupKey      @($cfg.lastArtifactName, $cfg.title)          'chart') }
    elseif ($cid -like '*TcmChartWidget*')                            { $refs += @{ guid = $null; names = @(); kind = 'test' } }
    return $refs
}

# --- Project + teams -----------------------------------------------------------
$proj = Invoke-Ado -Headers $headers -Uri "$base/_apis/projects/$projSeg`?api-version=7.1"
# A bad PAT / wrong org can return a 200 sign-in page instead of throwing; a wrong
# name can resolve to an empty object. Fail loudly rather than exporting nothing.
if (-not ($proj.id -match '^[0-9a-fA-F-]{36}$')) {
    throw @"
Could not resolve project '$Project' in org '$Org'.
  - Verify the exact project name (list projects: GET $base/_apis/projects?api-version=7.1)
  - Verify `$env:ADO_SOURCE_PAT is a token for org '$Org' (PATs are org-specific) with 'Project and Team (Read)' + 'Work Items (Read)' + 'Dashboards (Read)' scopes.
"@
}
$teams = (Invoke-Ado -Headers $headers -Uri "$base/_apis/projects/$($proj.id)/teams?`$top=200&api-version=7.1").value
Write-Host "Project '$Project' ($($proj.id)) - $($teams.Count) team(s)"

# --- Dashboards + widgets ------------------------------------------------------
$allGuids   = [System.Collections.Generic.HashSet[string]]::new()
$testGuids  = [System.Collections.Generic.HashSet[string]]::new()   # belong to Test Plan charts, not queries
$guidNames  = @{}   # query GUID -> embedded name hint (for drift recovery)
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
        Write-Utf8Text -Path (Join-Path $OutDir "dashboards/$safe.json") -Text ($record | ConvertTo-Json -Depth 50)

        foreach ($w in @($dash.widgets)) {
            $guids = Get-GuidsInText -Text ("$($w.settings) $($w.artifactId)")
            $guids | ForEach-Object { [void]$allGuids.Add($_) }
            foreach ($ref in (Get-QueryRefsFromWidget -Widget $w)) {
                if ($ref.kind -eq 'test') {
                    # Test Plan/Suite chart: none of its GUIDs are work-item queries.
                    $guids | ForEach-Object { [void]$testGuids.Add($_) }
                }
                elseif ($ref.guid -and @($ref.names).Count) {
                    if (-not $guidNames.ContainsKey($ref.guid)) { $guidNames[$ref.guid] = @() }
                    $guidNames[$ref.guid] = @(@($guidNames[$ref.guid]) + @($ref.names) | Where-Object { $_ } | Select-Object -Unique)
                }
            }
            $widgetRows += [pscustomobject]@{
                Team = $team.name; Dashboard = $dash.name; Widget = $w.name
                ContributionId = $w.contributionId; Guids = $guids
            }
        }
        Write-Host "  exported: [$($team.name)] $($dash.name) - $(@($dash.widgets).Count) widget(s)"
    }
}

# --- Resolve GUIDs: which ones are work item queries? --------------------------
# Pass 1: direct lookup by the GUID stored in the widget.
# Pass 2: for GUIDs that 404 (drift), recover via the widget's embedded query name
#         against the live Shared Queries tree, and record the dead GUID as an alias
#         so step 2/3 can rewire the widget to the recreated query.
$qById       = [ordered]@{}   # target query id -> entry (id,name,path,wiql,aliasIds)
$failed      = @()
$recovered   = @()
$ambiguous   = @()
$testRefs    = @()
$unresolved  = @()

foreach ($g in $allGuids) {
    if ($g -eq $proj.id.ToLowerInvariant()) { continue }
    if ($teams.id -contains $g)             { continue }
    if ($testGuids.Contains($g))            { $testRefs += $g; continue }
    try {
        $q = Invoke-Ado -Headers $headers -Uri "$base/$projSeg/_apis/wit/queries/$g`?`$expand=wiql&api-version=7.1"
        if (-not $q.isFolder -and -not $qById.Contains($g)) {
            $qById[$g] = [pscustomobject]@{ id = $g; name = $q.name; path = $q.path; wiql = $q.wiql; aliasIds = @() }
        }
    }
    catch { $failed += $g }
}

$sharedIndex = $null
if ($failed) {
    Write-Host "Direct lookup failed for $($failed.Count) GUID(s); indexing Shared Queries by name to recover..."
    $sharedIndex = Get-SharedQueryIndex -Headers $headers -Base $base -ProjSeg $projSeg
}
foreach ($g in $failed) {
    # Try every candidate name; dedupe hits by the resulting query id so a
    # suffixed queryName and a clean lastArtifactName pointing at the same query
    # count as one match (not an ambiguity).
    $byId = @{}
    foreach ($nm in @($guidNames[$g])) {
        if ([string]::IsNullOrWhiteSpace($nm)) { continue }
        foreach ($m in @($sharedIndex[("$nm".ToLowerInvariant())])) { if ($m) { $byId[$m.id] = $m } }
    }
    $ids = @($byId.Keys)
    if ($ids.Count -eq 1) {
        $m = $byId[$ids[0]]
        if ($qById.Contains($m.id)) { $qById[$m.id].aliasIds += $g }
        else { $qById[$m.id] = [pscustomobject]@{ id = $m.id; name = $m.name; path = $m.path; wiql = $m.wiql; aliasIds = @($g) } }
        $recovered += "$g -> '$($m.name)' [$($m.id)]"
    }
    elseif ($ids.Count -gt 1) {
        $unresolved += $g
        $ambiguous += "$g (names: $(@($guidNames[$g]) -join ' | ')) matches $($ids.Count) shared queries - pick one manually"
    }
    else { $unresolved += $g }
}

$queries = @($qById.Values)
Write-Utf8Text -Path (Join-Path $OutDir 'queries.json') -Text ($queries | ConvertTo-Json -Depth 10)

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
} | ConvertTo-Json -Depth 10 | ForEach-Object { Write-Utf8Text -Path (Join-Path $OutDir 'mapping.json') -Text $_ }

# --- Inventory report ----------------------------------------------------------
$extWidgets = $widgetRows | Where-Object { $_.ContributionId -and $_.ContributionId -notlike 'ms.*' }
$byContrib  = $widgetRows | Group-Object ContributionId | Sort-Object Count -Descending

$report = @()
$report += "# Export inventory - $Org / $Project"
$report += ""
$report += "- Dashboards exported: **$dashCount** (across $($teams.Count) team(s))"
$report += "- Widgets total: **$($widgetRows.Count)**"
$report += "- Distinct queries to recreate: **$($queries.Count)** (see queries.json; includes name-recovered)"
$report += "- Query GUIDs recovered by name (had drifted): **$($recovered.Count)**"
$report += "- Test Plan/Suite chart refs (not queries - migrate separately): **$(@($testRefs | Sort-Object -Unique).Count)**"
$report += "- Still-unresolved GUIDs (need manual handling): **$($unresolved.Count)**"
$report += ""
$report += "## Widget types"
$report += "| Contribution ID | Count |"
$report += "|---|---|"
$byContrib | ForEach-Object { $report += "| $($_.Name) | $($_.Count) |" }
$report += ""
$report += "## Marketplace-extension widgets (install these extensions in the TARGET org before import)"
if ($extWidgets) {
    $extWidgets | Group-Object ContributionId | ForEach-Object {
        $report += "- ``$($_.Name)`` - $($_.Count) widget(s)"
    }
} else { $report += "- none - all widgets are built-in" }
$report += ""
$report += "## Recovered queries (widget GUID had drifted; matched a live Shared Query by name)"
if ($recovered) { $recovered | Sort-Object -Unique | ForEach-Object { $report += "- $_" } }
else { $report += "- none" }
$report += ""
if ($ambiguous) {
    $report += "## Ambiguous names (same name in multiple Shared Query folders - resolve manually)"
    $ambiguous | Sort-Object -Unique | ForEach-Object { $report += "- $_" }
    $report += ""
}
$report += "## Test Plan/Suite charts (TcmChartWidget - migrate Test Plans/Suites separately, then reconfigure)"
if ($testRefs) {
    foreach ($g in ($testRefs | Sort-Object -Unique)) {
        $where = ($widgetRows | Where-Object { $_.Guids -contains $g } |
                  ForEach-Object { "[$($_.Team)] $($_.Dashboard) / $($_.Widget)" }) -join '; '
        $report += "- ``$g`` - used by: $where"
    }
} else { $report += "- none" }
$report += ""
$report += "## Still-unresolved GUIDs (no name match in Shared Queries - likely personal 'My Queries', deleted, or cross-project)"
if ($unresolved) {
    foreach ($g in $unresolved) {
        $nm = if (@($guidNames[$g]).Count) { " (widget names: $(@($guidNames[$g]) -join ' | '))" } else { "" }
        $where = ($widgetRows | Where-Object { $_.Guids -contains $g } |
                  ForEach-Object { "[$($_.Team)] $($_.Dashboard) / $($_.Widget)" }) -join '; '
        $report += "- ``$g``$nm - used by: $where"
    }
} else { $report += "- none" }
Write-Utf8Text -Path (Join-Path $OutDir 'inventory.md') -Text ($report -join "`n")

if ($recovered) { Write-Host "Recovered $($recovered.Count) drifted query GUID(s) by name." -ForegroundColor Green }
if ($unresolved) { Write-Host "$($unresolved.Count) GUID(s) still unresolved - see inventory.md." -ForegroundColor Yellow }

Write-Host "`nDone. REVIEW $(Join-Path $OutDir 'inventory.md') before running step 2." -ForegroundColor Green
