<#
.SYNOPSIS
    Migrates Azure DevOps Iteration Paths from one project to another.

.DESCRIPTION
    Prompts for source organization/project/PAT and target
    organization/project/PAT. Exports the source Iteration Path tree,
    creates missing nodes in the target project in parent-first order,
    carries source start/finish dates for newly created nodes, and performs
    a final verification.

.NOTES
    Requires PATs with Work Items Read & Write scope.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$SourceOrganization,
    [string]$SourceProject,
    [SecureString]$SourcePat,
    [string]$TargetOrganization,
    [string]$TargetProject,
    [SecureString]$TargetPat,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'migrate-iterations'; throw }

function Get-PlainText([SecureString]$SecureValue) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function New-AdoHeaders([string]$PlainPat) {
    @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $PlainPat))
        Accept        = 'application/json'
        'Content-Type'= 'application/json'
    }
}

function Resolve-OrganizationUrl([string]$InputValue, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($InputValue)) {
        throw "$Label is required."
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

    throw "$Label must be an organization name or URL (for example, contoso or https://dev.azure.com/contoso)."
}

function Get-IterationTree([string]$Organization, [string]$Project, [hashtable]$Headers) {
    $projectUri = [Uri]::EscapeDataString($Project)
    $baseUri = "{0}/{1}/_apis/wit/classificationnodes/iterations" -f $Organization.TrimEnd('/'), $projectUri
    $tree = (Invoke-WebRequest -Method Get -Uri "${baseUri}?`$depth=20&api-version=7.1" -Headers $Headers -TimeoutSec 30 -UseBasicParsing).Content | ConvertFrom-Json
    [pscustomobject]@{
        BaseUri = $baseUri
        Tree    = $tree
    }
}

function Get-RelativePath([string]$ApiPath, [string]$ApiRootPath) {
    if ($ApiPath -eq $ApiRootPath) { return '' }
    $prefix = "$ApiRootPath\"
    if (-not $ApiPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "API returned an unexpected Iteration Path: $ApiPath"
    }
    return $ApiPath.Substring($prefix.Length)
}

function Get-NodeChildren($Node) {
    if ($null -eq $Node) { return @() }
    $childrenProperty = $Node.PSObject.Properties['children']
    if ($null -eq $childrenProperty -or $null -eq $childrenProperty.Value) {
        return @()
    }
    return @($childrenProperty.Value)
}

function Get-IterationPathSet($Tree) {
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rootPath = $Tree.path

    function Add-Node($Node, [Collections.Generic.HashSet[string]]$Collector, [string]$ApiRootPath) {
        $relative = Get-RelativePath -ApiPath $Node.path -ApiRootPath $ApiRootPath
        [void]$Collector.Add($relative)
        foreach ($child in (Get-NodeChildren -Node $Node)) {
            if ($null -ne $child) { Add-Node -Node $child -Collector $Collector -ApiRootPath $ApiRootPath }
        }
    }

    Add-Node -Node $Tree -Collector $set -ApiRootPath $rootPath
    return ,$set
}

function Get-SourceNodeLookup($Tree) {
    $lookup = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
    $rootPath = $Tree.path

    function Add-Node($Node, [Collections.Generic.Dictionary[string, object]]$Collector, [string]$ApiRootPath) {
        $relative = Get-RelativePath -ApiPath $Node.path -ApiRootPath $ApiRootPath
        if (-not $Collector.ContainsKey($relative)) {
            $Collector.Add($relative, $Node)
        }
        foreach ($child in (Get-NodeChildren -Node $Node)) {
            if ($null -ne $child) { Add-Node -Node $child -Collector $Collector -ApiRootPath $ApiRootPath }
        }
    }

    Add-Node -Node $Tree -Collector $lookup -ApiRootPath $rootPath
    return ,$lookup
}

function Get-IsoDateOrNull($Value) {
    if ($null -eq $Value) { return $null }
    try {
        $dt = [datetime]$Value
        return $dt.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    catch {
        return $null
    }
}

$sourceOrganizationInput = if ($SourceOrganization) { $SourceOrganization } else { Read-AdoInput -Prompt (Get-AdoPrompt SourceOrganization) }
$sourceOrganization = Resolve-OrganizationUrl -InputValue $sourceOrganizationInput -Label 'Source organization'

$sourceProject = if ($SourceProject) { $SourceProject } else { Read-AdoInput 'Source project name' }
if ([string]::IsNullOrWhiteSpace($sourceProject)) { throw 'Source project name is required.' }

$sourcePatSecure = Resolve-AdoPat -Pat $SourcePat -Role Source
$sourcePlainPat = ConvertFrom-AdoSecureString $sourcePatSecure

$targetOrganizationInput = if ($TargetOrganization) { $TargetOrganization } else { Read-AdoInput -Prompt (Get-AdoPrompt TargetOrganization) }
$targetOrganization = Resolve-OrganizationUrl -InputValue $targetOrganizationInput -Label 'Target organization'

$targetProject = if ($TargetProject) { $TargetProject } else { Read-AdoInput 'Target project name' }
if ([string]::IsNullOrWhiteSpace($targetProject)) { throw 'Target project name is required.' }

$targetPatSecure = Resolve-AdoPat -Pat $TargetPat -Role Target
$targetPlainPat = ConvertFrom-AdoSecureString $targetPatSecure

try {
    $sourceHeaders = New-AdoHeaders -PlainPat $sourcePlainPat
    $targetHeaders = New-AdoHeaders -PlainPat $targetPlainPat

    Write-Host "Reading source Iteration Paths from '$sourceOrganization/$sourceProject'..."
    $source = Get-IterationTree -Organization $sourceOrganization -Project $sourceProject -Headers $sourceHeaders
    $sourceSet = Get-IterationPathSet -Tree $source.Tree
    $sourceNodes = Get-SourceNodeLookup -Tree $source.Tree

    Write-Host "Reading target Iteration Paths from '$targetOrganization/$targetProject'..."
    $target = Get-IterationTree -Organization $targetOrganization -Project $targetProject -Headers $targetHeaders
    $targetSet = Get-IterationPathSet -Tree $target.Tree

    $toCreate = @(
        $sourceSet |
            Where-Object { $_ -ne '' -and -not $targetSet.Contains($_) } |
            Sort-Object { ($_ -split '\\').Count }, @{ Expression = { $_ } }
    )

    Write-Host "Source Iteration Paths (including root): $($sourceSet.Count)"
    Write-Host "Target Iteration Paths (including root): $($targetSet.Count)"
    Write-Host "Missing Iteration Paths to create: $($toCreate.Count)"

    $created = [Collections.Generic.List[string]]::new()

    foreach ($relativePath in $toCreate) {
        $name = $relativePath.Substring($relativePath.LastIndexOf([char]'\') + 1)
        $parentRelativePath = if ($relativePath.Contains('\')) {
            $relativePath.Substring(0, $relativePath.LastIndexOf([char]'\'))
        } else {
            ''
        }

        $parentUri = if ([string]::IsNullOrEmpty($parentRelativePath)) {
            $target.BaseUri
        }
        else {
            $encodedSegments = $parentRelativePath.Split([char]'\') | ForEach-Object { [Uri]::EscapeDataString($_) }
            "$($target.BaseUri)/$($encodedSegments -join '/')"
        }

        $body = @{ name = $name }
        if ($sourceNodes.ContainsKey($relativePath)) {
            $sourceNode = $sourceNodes[$relativePath]
            $attributesProperty = $sourceNode.PSObject.Properties['attributes']
            if ($null -ne $attributesProperty -and $null -ne $attributesProperty.Value) {
                $startDate = Get-IsoDateOrNull -Value $attributesProperty.Value.startDate
                $finishDate = Get-IsoDateOrNull -Value $attributesProperty.Value.finishDate
                if ($startDate -or $finishDate) {
                    $body.attributes = @{}
                    if ($startDate) { $body.attributes.startDate = $startDate }
                    if ($finishDate) { $body.attributes.finishDate = $finishDate }
                }
            }
        }

        if ($PSCmdlet.ShouldProcess("$targetProject/$relativePath", 'Create Azure DevOps Iteration Path')) {
            Invoke-WebRequest -Method Post -Uri "${parentUri}?api-version=7.1" -Headers $targetHeaders -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 30 -UseBasicParsing | Out-Null
            [void]$created.Add($relativePath)
        }
    }

    if ($WhatIfPreference) {
        Write-Host "Preview complete. Planned $($created.Count) Iteration Path node(s); verification skipped because no writes occurred."
        Complete-AdoScriptRun -Outcome preview -Operation 'migrate-iterations'
        return
    }
    Write-Host 'Verifying target Iteration Paths...'
    $targetFinal = Get-IterationTree -Organization $targetOrganization -Project $targetProject -Headers $targetHeaders
    $targetFinalSet = Get-IterationPathSet -Tree $targetFinal.Tree

    $missingAfterImport = @(
        $sourceSet |
            Where-Object { -not $targetFinalSet.Contains($_) }
    )

    if (@($missingAfterImport).Count -gt 0) {
        throw "Verification failed. Missing in target: $($missingAfterImport -join '; ')"
    }

    Write-Host "Migration complete. Created $($created.Count) Iteration Path node(s) in '$targetProject'."
    $created
    Complete-AdoScriptRun -Outcome succeeded -Operation 'migrate-iterations'
}
finally {
    if ($sourcePlainPat) { $sourcePlainPat = $null }
    if ($targetPlainPat) { $targetPlainPat = $null }
}
