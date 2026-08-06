<#
.SYNOPSIS
    Idempotently imports Azure DevOps Area Paths from a CSV file.

.DESCRIPTION
    Validates the supplied hierarchy, compares it to the project’s live Area
    Path tree, creates only missing nodes in parent-first order, and performs
    a final verification. The PAT is requested securely and is never written
    to disk by this script. Organization accepts an organization name or URL.

.CSV FORMAT
    Required columns: Name, AreaPath, ParentPath, Level

    AreaPath is relative to the project's Area root. Include a root row whose
    AreaPath and Name match the project Area root (normally the project name),
    for example:
      Name,AreaPath,ParentPath,Level
      My Project,My Project,,0
      Finance,Finance,My Project,1
      Ledger,Finance\\Ledger,Finance,2

.EXAMPLE
    .\ado-import-area-paths.ps1 `
      -Organization 'https://dev.azure.com/contoso' `
      -Project 'My Project' `
      -CsvFile 'C:\Temp\AreaPaths.csv'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Organization,

    [string]$Project,

    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$CsvFile,

    [SecureString]$Pat,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'import-area-paths'; throw }

function Get-PlainText([SecureString]$SecureValue) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

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

function Get-RelativeAreaPath([string]$ApiPath, [string]$ApiRootPath) {
    if ($ApiPath -eq $ApiRootPath) { return $null }
    $prefix = "$ApiRootPath\"
    if (-not $ApiPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "API returned an unexpected Area Path: $ApiPath"
    }
    return $ApiPath.Substring($prefix.Length)
}

$Organization = Resolve-AdoRequiredInput -Value $Organization -Name 'Organization' -Prompt (Get-AdoPrompt -Name Organization)
$Project = Resolve-AdoRequiredInput -Value $Project -Name 'Project' -Prompt 'Azure DevOps project name'
$CsvFile = Resolve-AdoRequiredInput -Value $CsvFile -Name 'CsvFile' -Prompt 'CSV file path'
if (-not (Test-Path -LiteralPath $CsvFile -PathType Leaf)) { throw "CSV file not found: $CsvFile" }

$Organization = Resolve-OrganizationUrl -InputValue $Organization
$Pat = Resolve-AdoPat -Pat $Pat -Role Default
$plainPat = ConvertFrom-AdoSecureString $Pat
try {
    $headers = @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $plainPat))
        Accept        = 'application/json'
        'Content-Type'= 'application/json'
    }

    $rows = @(Import-Csv -LiteralPath $CsvFile)
    $requiredColumns = 'Name', 'AreaPath', 'ParentPath', 'Level'
    $actualColumns = @($rows | Select-Object -First 1 | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
    $missingColumns = @($requiredColumns | Where-Object { $_ -notin $actualColumns })
    if ($missingColumns) { throw "CSV is missing required column(s): $($missingColumns -join ', ')" }
    if ($rows.Count -eq 0) { throw 'CSV has no data rows.' }

    $projectUri = [Uri]::EscapeDataString($Project)
    $baseUri = "$($Organization.TrimEnd('/'))/$projectUri/_apis/wit/classificationnodes/areas"
    $tree = (Invoke-WebRequest -Method Get -Uri "${baseUri}?`$depth=20&api-version=7.1" -Headers $headers -TimeoutSec 30 -UseBasicParsing).Content | ConvertFrom-Json
    $apiRootPath = $tree.path

    $rootRows = @($rows | Where-Object { [int]$_.Level -eq 0 })
    if ($rootRows.Count -ne 1) { throw 'CSV must contain exactly one Level 0 root row.' }
    $root = $rootRows[0]
    if ($root.Name.Trim() -ne $tree.name -or $root.AreaPath.Trim() -ne $tree.name -or $root.ParentPath.Trim()) {
        throw "CSV root must be '$($tree.name)' with an empty ParentPath."
    }

    $requested = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $rows) {
        $area = $row.AreaPath.Trim(); $name = $row.Name.Trim(); $parent = $row.ParentPath.Trim()
        if (-not $area -or -not $name) { throw 'Name and AreaPath cannot be blank.' }
        if (-not $requested.TryAdd($area, $row)) { throw "Duplicate AreaPath in CSV: $area" }
        if ([int]$row.Level -gt 0) {
            $expectedParent = if ($area.Contains('\')) { $area.Substring(0, $area.LastIndexOf('\')) } else { $tree.name }
            if ($parent -ne $expectedParent) { throw "ParentPath mismatch for '$area'. Expected '$expectedParent'." }
            if ($name -ne $area.Substring($area.LastIndexOf('\') + 1)) { throw "Name mismatch for '$area'." }
        }
    }

    # Add any omitted parents needed by requested descendants (for example, an SLS parent).
    $needed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($area in $requested.Keys) {
        if ($area -eq $tree.name) { continue }
        $parts = $area.Split([char]'\')
        for ($i = 1; $i -le $parts.Count; $i++) { [void]$needed.Add(($parts[0..($i - 1)] -join '\')) }
    }

    $existing = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Add-ExistingNodes($Node) {
        $relative = Get-RelativeAreaPath -ApiPath $Node.path -ApiRootPath $apiRootPath
        [void]$existing.Add($(if ($null -eq $relative) { $tree.name } else { $relative }))
        # ADO's classification-node API omits 'children' entirely on leaf nodes rather than
        # returning an empty array; under Set-StrictMode, $Node.children would throw on those.
        $children = if ($Node.PSObject.Properties.Name -contains 'children') { $Node.children } else { @() }
        foreach ($child in @($children)) { if ($null -ne $child) { Add-ExistingNodes $child } }
    }
    Add-ExistingNodes $tree

    $toCreate = @($needed | Where-Object { -not $existing.Contains($_) } | Sort-Object { ($_ -split '\\').Count }, @{ Expression = { $_ } })
    Write-Host "Existing Area Paths: $($existing.Count)"
    Write-Host "Missing nodes to create: $($toCreate.Count)"

    $created = [Collections.Generic.List[string]]::new()
    foreach ($area in $toCreate) {
        $parent = if ($area.Contains('\')) { $area.Substring(0, $area.LastIndexOf('\')) } else { $tree.name }
        $name = $area.Substring($area.LastIndexOf('\') + 1)
        $parentUri = if ($parent -eq $tree.name) { $baseUri } else {
            $encodedSegments = $parent.Split([char]'\') | ForEach-Object { [Uri]::EscapeDataString($_) }
            "$baseUri/$($encodedSegments -join '/')"
        }
        if ($PSCmdlet.ShouldProcess($area, 'Create Azure DevOps Area Path')) {
            $body = @{ name = $name } | ConvertTo-Json -Compress
            Invoke-WebRequest -Method Post -Uri "${parentUri}?api-version=7.1" -Headers $headers -Body $body -TimeoutSec 30 -UseBasicParsing | Out-Null
            [void]$created.Add($area)
        }
    }

    if ($WhatIfPreference) {
        Write-Host "Previewed $($requested.Count) CSV Area Paths. Planned $($created.Count) node(s); verification skipped because no writes occurred."
        Complete-AdoScriptRun -Outcome preview -Operation 'import-area-paths'
        return
    }
    # Final verification from a fresh live tree.
    $finalTree = (Invoke-WebRequest -Method Get -Uri "${baseUri}?`$depth=20&api-version=7.1" -Headers $headers -TimeoutSec 30 -UseBasicParsing).Content | ConvertFrom-Json
    $existing.Clear(); $apiRootPath = $finalTree.path; $tree = $finalTree
    Add-ExistingNodes $finalTree
    $missing = @($requested.Keys | Where-Object { -not $existing.Contains($_) })
    if ($missing) { throw "Verification failed. Missing: $($missing -join '; ')" }

    Write-Host "Verified $($requested.Count) CSV Area Paths. Created $($created.Count) node(s)."
    $created
    Complete-AdoScriptRun -Outcome succeeded -Operation 'import-area-paths'
}
finally {
    if ($plainPat) { $plainPat = $null }
}
