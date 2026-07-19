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
    [string]$ExportDir = "./export",
    [string]$QueryFolderName = "Migrated Dashboards",
    [string]$SourceProjectName = ""   # if set, occurrences in WIQL are rewritten to TargetProject
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_common.ps1')

$headers = Get-AdoAuthHeader -EnvVarName 'ADO_TARGET_PAT'
$base    = "https://dev.azure.com/$(UrlEnc $TargetOrg)"
$projSeg = UrlEnc $TargetProject
$queries = Get-Content (Join-Path $ExportDir 'queries.json') -Raw | ConvertFrom-Json
if (-not $queries) { throw "No queries found in $ExportDir/queries.json — run step 1 first." }

# Auto-detect source project name from mapping.json if not passed
if (-not $SourceProjectName) {
    $map = Get-Content (Join-Path $ExportDir 'mapping.json') -Raw | ConvertFrom-Json
    $SourceProjectName = $map.sourceProjectName
}

function Ensure-QueryFolder {
    param([string]$ParentPath, [string]$Name)   # ParentPath like "Shared Queries" or "Shared Queries/Sub"
    try {
        Invoke-Ado -Headers $headers -Method POST `
            -Uri "$base/$projSeg/_apis/wit/queries/$(UrlEnc $ParentPath)?api-version=7.1" `
            -Body @{ name = $Name; isFolder = $true } | Out-Null
    } catch {
        if ($_.Exception.Message -notmatch '409|already exists|TF237018') { throw }
    }
    return "$ParentPath/$Name"
}

$rootPath = Ensure-QueryFolder -ParentPath 'Shared Queries' -Name $QueryFolderName
$queryMap = @{}
$warnings = @()

foreach ($q in $queries) {
    # Preserve the source folder structure under the migration folder.
    # Source path looks like "Shared Queries/Folder A/My Query" or "My Queries/..."
    $relDir = ($q.path -replace '^(Shared Queries|My Queries)/', '') -replace "/$([regex]::Escape($q.name))$", ''
    if ($relDir -eq $q.name -or [string]::IsNullOrWhiteSpace($relDir)) { $relDir = '' }
    $parent = $rootPath
    foreach ($seg in ($relDir -split '/' | Where-Object { $_ })) {
        $parent = Ensure-QueryFolder -ParentPath $parent -Name $seg
    }

    # WIQL transform: retarget explicit project references. @project needs no change.
    $wiql = $q.wiql
    if ($SourceProjectName -and $wiql -match [regex]::Escape($SourceProjectName)) {
        $wiql = $wiql -replace [regex]::Escape($SourceProjectName), $TargetProject
        $warnings += "REWROTE project name in WIQL of '$($q.name)' — verify area/iteration paths exist in target."
    }
    if ($wiql -match '\[System\.(AreaPath|IterationPath)\]\s*(=|under|in)') {
        $warnings += "'$($q.name)' filters on Area/Iteration path — if the path doesn't exist in '$TargetProject', it returns 0 results."
    }

    try {
        $created = Invoke-Ado -Headers $headers -Method POST `
            -Uri "$base/$projSeg/_apis/wit/queries/$(UrlEnc $parent)?api-version=7.1" `
            -Body @{ name = $q.name; wiql = $wiql }
        $queryMap[$q.id] = $created.id
        Write-Host "  created: $parent/$($q.name)"
    } catch {
        # Already exists (rerun) -> fetch existing id. Otherwise surface the error (bad WIQL etc.)
        try {
            $existing = Invoke-Ado -Headers $headers `
                -Uri "$base/$projSeg/_apis/wit/queries/$(UrlEnc "$parent/$($q.name)")?api-version=7.1"
            $queryMap[$q.id] = $existing.id
            Write-Host "  exists:  $parent/$($q.name) (reusing)"
        } catch {
            $warnings += "FAILED to create '$($q.name)': $($_.Exception.Message) — likely WIQL references a field/type/state missing in the target process. Fix manually, then add its id to querymap.json."
        }
    }
}

$queryMap | ConvertTo-Json | Set-Content -Path (Join-Path $ExportDir 'querymap.json') -Encoding utf8
Write-Host "`nMapped $($queryMap.Count) of $(@($queries).Count) queries -> $(Join-Path $ExportDir 'querymap.json')" -ForegroundColor Green
if ($warnings) {
    Write-Host "`nWarnings:" -ForegroundColor Yellow
    $warnings | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
