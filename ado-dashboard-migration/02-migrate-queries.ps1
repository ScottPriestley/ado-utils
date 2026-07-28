<#
.SYNOPSIS
    Step 2: Recreate the queries referenced by exported dashboards in the target
    project's Shared Queries, and write querymap.json (source GUID -> target GUID).

.NOTES
    Requires: $env:ADO_TARGET_PAT  (scopes: Work Items Read & Write)
    Input:    <ExportDir>/queries.json  (from step 1)
    Output:   <ExportDir>/querymap.json
    Idempotent: if a query already exists at the target path, its existing id is reused.
#>
param(
    [Parameter(Mandatory)][string]$TargetOrg,
    [Parameter(Mandatory)][string]$TargetProject,
    [string]$ExportDir = "export",
    [string]$QueryFolderName = "",    # optional wrapper folder under Shared Queries; empty = preserve the source folder structure as-is (e.g. Shared Queries/Dashboard Queries/...)
    [string]$SourceProjectName = ""   # if set, occurrences in WIQL are rewritten to TargetProject
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

if (-not [System.IO.Path]::IsPathRooted($ExportDir)) {
    $ExportDir = Join-Path $PSScriptRoot $ExportDir
}
$ExportDir = [System.IO.Path]::GetFullPath($ExportDir)

$TargetOrg = Get-OrgName $TargetOrg   # accept bare name or full URL

# Validate input files exist
$queriesPath = Join-Path $ExportDir 'queries.json'
if (-not (Test-Path -LiteralPath $queriesPath)) {
    throw "Input file not found: $queriesPath - run step 1 first and verify export directory."
}
$queries = @(Read-Utf8Text $queriesPath | ConvertFrom-Json)
if (-not @($queries).Count) { throw "No queries found in $queriesPath - run step 1 first." }

# Auto-detect source project name from mapping.json if not passed
if (-not $SourceProjectName) {
    $mapPath = Join-Path $ExportDir 'mapping.json'
    if (-not (Test-Path -LiteralPath $mapPath)) {
        throw "Input file not found: $mapPath - run step 1 first and verify export directory."
    }
    $map = Read-Utf8Text $mapPath | ConvertFrom-Json
    $SourceProjectName = $map.sourceProjectName
    if (-not $SourceProjectName) { throw "Could not detect source project name from mapping.json - pass -SourceProjectName explicitly." }
}

$headers = Get-AdoAuthHeader -EnvVarName 'ADO_TARGET_PAT' -Purpose "TARGET org '$TargetOrg'"
$base    = "https://dev.azure.com/$(UrlEnc $TargetOrg)"
$projSeg = UrlEnc $TargetProject

function Confirm-QueryFolder {
    param([string]$ParentPath, [string]$Name)   # ParentPath like "Shared Queries" or "Shared Queries/Sub"
    if ([string]::IsNullOrWhiteSpace($ParentPath) -or [string]::IsNullOrWhiteSpace($Name)) {
        throw "Invalid folder parameters: ParentPath='$ParentPath', Name='$Name'"
    }
    try {
        Invoke-Ado -Headers $headers -Method POST `
            -Uri "$base/$projSeg/_apis/wit/queries/$(UrlEncQueryPath $ParentPath)?api-version=7.1" `
            -Body @{ name = $Name; isFolder = $true } | Out-Null
    } catch {
        # 409: Conflict = already exists, which is fine (idempotent)
        # TF237018, VS402371: folder already exists error codes
        if ($_.Exception.Message -notmatch '409|already exists|TF237018|VS402371') {
            throw "Failed to create query folder '$ParentPath/$Name': $($_.Exception.Message)"
        }
    }
    return "$ParentPath/$Name"
}

function UrlEncQueryPath {
    param([Parameter(Mandatory)][string]$Path)
    return (($Path -split '/' | Where-Object { $_ } | ForEach-Object { UrlEnc $_ }) -join '/')
}

# Root: preserve the source structure directly under Shared Queries (default),
# or nest it under an optional wrapper folder if -QueryFolderName was supplied.
$rootPath = if ([string]::IsNullOrWhiteSpace($QueryFolderName)) { 'Shared Queries' } else { Confirm-QueryFolder -ParentPath 'Shared Queries' -Name $QueryFolderName }
$queryMap      = @{}
$skippedProc   = @()   # genuinely can't be created here: missing field/type/state
$failedOther   = @()   # failed for another reason (e.g. transient) - rerun may fix
$createdCount  = 0
$reusedCount   = 0
$rewroteCount  = 0
$areaFilterCnt = 0

# Pull the concise ADO "message" out of an error (Invoke-Ado folds the JSON body in).
function Get-AdoMsg {
    param($ErrorRecord)
    $m = "$($ErrorRecord.Exception.Message)"
    if ($m -match '"message"\s*:\s*"([^"]+)"') { return $Matches[1] }
    return $m
}

foreach ($q in @($queries)) {
    # Validate required properties exist
    if (-not $q.id -or -not $q.name -or -not $q.wiql) {
        $queryName = if ($q.name) { $q.name } else { 'unnamed' }
        $failedOther += "Query missing required properties (id/name/wiql): $queryName"
        Write-Host "  skip:    (missing properties)" -ForegroundColor DarkYellow
        continue
    }

    # Preserve the source folder structure (minus the "Shared Queries"/"My Queries" root
    # and the query's own name). Source path looks like
    # "Shared Queries/Dashboard Queries/RAID/Open Risk" -> relDir "Dashboard Queries/RAID".
    $qpath = if ([string]::IsNullOrWhiteSpace($q.path)) { $q.name } else { $q.path }
    $qpath = $qpath -replace '\\', '/'
    $relDir = ($qpath -replace '^(Shared Queries|My Queries)/', '') -replace "/$([regex]::Escape($q.name))$", ''
    if ($relDir -eq $q.name -or [string]::IsNullOrWhiteSpace($relDir)) { $relDir = '' }
    $parent = $rootPath
    foreach ($seg in ($relDir -split '/' | Where-Object { $_ })) {
        $parent = Confirm-QueryFolder -ParentPath $parent -Name $seg
    }

    # WIQL transform: retarget explicit project references. @project needs no change.
    $wiql = $q.wiql
    if ($SourceProjectName -and -not [string]::IsNullOrWhiteSpace($SourceProjectName) -and $wiql -match [regex]::Escape($SourceProjectName)) {
        $wiql = [regex]::Replace($wiql, [regex]::Escape($SourceProjectName), [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $TargetProject }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        $rewroteCount++
    }
    if ($wiql -match '\[System\.(AreaPath|IterationPath)\]\s*(=|under|in)') { $areaFilterCnt++ }

    # Local function to record query mapping (including aliases)
    $Set_Map = {
        param($TargetId)
        if ($TargetId) { $queryMap[$q.id] = $TargetId }
        foreach ($a in @($q.aliasIds | Where-Object { $_ })) {
            if ($a -and $a -ne $q.id) { $queryMap[$a] = $TargetId }
        }
    };

    try {
        $created = Invoke-Ado -Headers $headers -Method POST `
            -Uri "$base/$projSeg/_apis/wit/queries/$(UrlEncQueryPath $parent)?api-version=7.1" `
            -Body @{ name = $q.name; wiql = $wiql }
        if ($created.id) {
            & $Set_Map $created.id
            $createdCount++
            $aliasCount = @($q.aliasIds | Where-Object { $_ }).Count
            $aliasDisplay = if ($aliasCount) { " (+$aliasCount drifted alias)" } else { "" }
            Write-Host "  created: $parent/$($q.name)$aliasDisplay"
        } else {
            $failedOther += "$($q.name) - API response missing 'id' property"
        }
    } catch {
        $postMsg = Get-AdoMsg $_
        if ($postMsg -match '409|already exists|TF237018|VS402371') {
            # Query already there (rerun) -> reuse its id.
            try {
                $existing = Invoke-Ado -Headers $headers `
                    -Uri "$base/$projSeg/_apis/wit/queries/$(UrlEncQueryPath "$parent/$($q.name)")?api-version=7.1"
                if ($existing.id) {
                    & $Set_Map $existing.id
                    $reusedCount++
                    Write-Host "  exists:  $parent/$($q.name) (reusing)"
                } else {
                    $failedOther += "$($q.name): exists but couldn't read id"
                }
            } catch {
                $failedOther += "$($q.name): exists but couldn't read id - $(Get-AdoMsg $_)"
            }
        }
        elseif ($postMsg -match 'TF51005|does not exist|is not (a )?valid|unknown field|not recognized|VS403|field|system\.iterationpath|system\.areapath') {
            # WIQL references a field/type/state the target process doesn't have.
            $skippedProc += "$($q.name) - $postMsg"
            Write-Host "  skip:    $parent/$($q.name) (process mismatch)" -ForegroundColor DarkYellow
        }
        else {
            # Something else (often transient after retries) - a rerun may succeed.
            $failedOther += "$($q.name) - $postMsg"
            Write-Host "  FAILED:  $parent/$($q.name) - $postMsg" -ForegroundColor Red
        }
    }
}

$queryMapJson = if ($queryMap.Count) { $queryMap | ConvertTo-Json -Depth 10 } else { '{}' }
Write-Utf8Text -Path (Join-Path $ExportDir 'querymap.json') -Text $queryMapJson

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host ("  created:        {0}" -f $createdCount) -ForegroundColor Green
Write-Host ("  reused:         {0}" -f $reusedCount)
Write-Host ("  skipped (process mismatch): {0}" -f @($skippedProc).Count) -ForegroundColor DarkYellow
$failedColor = if (@($failedOther).Count) { 'Red' } else { 'Gray' }
Write-Host ("  failed (other / transient): {0}" -f @($failedOther).Count) -ForegroundColor $failedColor
Write-Host ("  querymap entries written:   {0} -> {1}" -f $queryMap.Count, (Join-Path $ExportDir 'querymap.json'))
if ($rewroteCount)  { Write-Host "  ($rewroteCount queries had the source project name rewritten in WIQL - verify area/iteration paths exist in target.)" }
if ($areaFilterCnt) { Write-Host "  ($areaFilterCnt queries filter on Area/Iteration path - they return 0 results if that path doesn't exist in '$TargetProject'.)" }

if (@($skippedProc).Count) {
    Write-Host "`nSkipped - target process is missing a field/type/state (can't recreate as-is):" -ForegroundColor DarkYellow
    @($skippedProc) | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor DarkYellow }
}
if (@($failedOther).Count) {
    Write-Host "`nFailed for another reason - RERUN this script; these are often transient and idempotent:" -ForegroundColor Red
    @($failedOther) | Where-Object { $_ } | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
}
Write-Utf8Text -Path (Join-Path $ExportDir 'queries-skipped.txt') -Text ((@($skippedProc) | Where-Object { $_ } | Sort-Object -Unique) -join "`r`n")
