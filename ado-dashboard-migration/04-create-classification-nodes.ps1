<#
.SYNOPSIS
    Step 4 (optional, run BEFORE re-running step 2): create the Area/Iteration
    classification nodes that the migrated queries reference, so queries that were
    skipped with "TF51011: The specified iteration/area path does not exist" can be
    created on the rerun.

.NOTES
    Requires: $env:ADO_TARGET_PAT  (scopes: Work Items Read & Write)
    Input:    <ExportDir>/queries.json, mapping.json  (from step 1)
    Reads Area/Iteration path literals out of each query's WIQL, strips the source
    project root, and creates the equivalent nodes under the TARGET project.
    Idempotent: nodes that already exist are left as-is. Paths that reference a
    DIFFERENT project (e.g. a cross-project 'ProServ PMO Sandbox\...') are reported,
    not created. Does not add work items or set dates - it only makes the query WIQL valid.
#>
param(
    [Parameter(Mandatory)][string]$TargetOrg,
    [Parameter(Mandatory)][string]$TargetProject,
    [string]$ExportDir = "./export",
    [string]$SourceProjectName = "",   # default: from mapping.json
    [switch]$WhatIfOnly                 # list what would be created, create nothing
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$TargetOrg = Get-OrgName $TargetOrg
$headers   = Get-AdoAuthHeader -EnvVarName 'ADO_TARGET_PAT' -Purpose "TARGET org '$TargetOrg'"
$base      = "https://dev.azure.com/$(UrlEnc $TargetOrg)"
$projSeg   = UrlEnc $TargetProject
$queries   = Read-Utf8Text (Join-Path $ExportDir 'queries.json') | ConvertFrom-Json
if (-not $queries) { throw "No queries found in $ExportDir/queries.json - run step 1 first." }
if (-not $SourceProjectName) {
    $SourceProjectName = (Read-Utf8Text (Join-Path $ExportDir 'mapping.json') | ConvertFrom-Json).sourceProjectName
}

# --- Extract Area/Iteration path literals from WIQL ----------------------------
$areaPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$iterPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$foreign   = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Match [System.AreaPath] / [System.IterationPath] <op> ('a','b') | 'a'
$fieldRe = "\[System\.(AreaPath|IterationPath)\]\s*(?:=|<>|UNDER|NOT\s+UNDER|IN|CONTAINS)\s*(\([^)]*\)|'[^']*')"

foreach ($q in $queries) {
    $wiql = "$($q.wiql)"
    if ([string]::IsNullOrWhiteSpace($wiql)) { continue }
    foreach ($m in [regex]::Matches($wiql, $fieldRe, 'IgnoreCase')) {
        $kind    = $m.Groups[1].Value
        $valPart = $m.Groups[2].Value
        foreach ($lit in [regex]::Matches($valPart, "'([^']*)'")) {
            $p = $lit.Groups[1].Value
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            $segs = $p -split '\\'
            if ($segs.Count -lt 2) { continue }   # bare project root - nothing to create
            $root = $segs[0]
            if ($root -ieq $SourceProjectName -or $root -ieq $TargetProject) {
                $rel = ($segs[1..($segs.Count - 1)] -join '\')
                if ($kind -ieq 'AreaPath') { [void]$areaPaths.Add($rel) } else { [void]$iterPaths.Add($rel) }
            } else {
                [void]$foreign.Add($p)
            }
        }
    }
}

# Expand each relative path into all ancestor prefixes; order shallow -> deep.
function Expand-Ancestors {
    param([string[]]$Paths)
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Paths) {
        $segs = $p -split '\\'
        for ($i = 0; $i -lt $segs.Count; $i++) { [void]$seen.Add(($segs[0..$i] -join '\')) }
    }
    return $seen | Sort-Object { ($_ -split '\\').Count }, { $_ }
}

function Ensure-Node {
    param([ValidateSet('areas','iterations')][string]$Structure, [string]$RelPath)
    $segs      = $RelPath -split '\\'
    $name      = $segs[-1]
    $parentRel = if ($segs.Count -gt 1) { ($segs[0..($segs.Count - 2)] -join '\') } else { '' }
    $uri = "$base/$projSeg/_apis/wit/classificationnodes/$Structure"
    if ($parentRel) { $uri += '/' + (($parentRel -split '\\' | ForEach-Object { UrlEnc $_ }) -join '/') }
    $uri += "?api-version=7.1"
    if ($WhatIfOnly) { Write-Host "  would create $Structure`: $RelPath" -ForegroundColor Cyan; return $true }
    try {
        Invoke-Ado -Headers $headers -Method POST -Uri $uri -Body @{ name = $name } | Out-Null
        Write-Host "  created $Structure`: $RelPath" -ForegroundColor Green
        return $true
    } catch {
        $msg = "$($_.Exception.Message)"
        if ($msg -match 'already exists|VS402371|TF237018|409') { Write-Host "  exists  $Structure`: $RelPath"; return $true }
        Write-Host "  FAILED  $Structure`: $RelPath - $msg" -ForegroundColor Red
        return $false
    }
}

Write-Host "Source project root in WIQL: '$SourceProjectName'  ->  target project: '$TargetProject'"
Write-Host "Iteration paths referenced: $($iterPaths.Count) leaf(s); Area paths: $($areaPaths.Count) leaf(s)."

$ok = 0; $fail = 0
Write-Host "`nIterations:" -ForegroundColor Cyan
foreach ($rp in (Expand-Ancestors -Paths @($iterPaths))) { if (Ensure-Node -Structure 'iterations' -RelPath $rp) { $ok++ } else { $fail++ } }
Write-Host "`nAreas:" -ForegroundColor Cyan
foreach ($rp in (Expand-Ancestors -Paths @($areaPaths)))  { if (Ensure-Node -Structure 'areas'      -RelPath $rp) { $ok++ } else { $fail++ } }

Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host ("  nodes created/existing: {0}" -f $ok) -ForegroundColor Green
if ($fail) { Write-Host ("  nodes failed:           {0}" -f $fail) -ForegroundColor Red }
if ($foreign.Count) {
    Write-Host "`nCross-project paths (belong to another project - create/repoint manually):" -ForegroundColor Yellow
    $foreign | Sort-Object | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
if (-not $WhatIfOnly) {
    Write-Host "`nNext: re-run step 2 to create the queries that were blocked on missing paths:" -ForegroundColor Green
    Write-Host "  pwsh `"$(Join-Path $PSScriptRoot '02-migrate-queries.ps1')`" -TargetOrg $TargetOrg -TargetProject `"$TargetProject`""
}
