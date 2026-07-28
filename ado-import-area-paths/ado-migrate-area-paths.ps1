<#
.SYNOPSIS
    Migrates Azure DevOps Area Paths from one project to another.

.DESCRIPTION
    Prompts for source organization/project/PAT and target
    organization/project/PAT.
    Exports the source Area Path tree, then imports missing nodes into the
    target project in parent-first order. Existing target nodes are preserved.

.NOTES
    Requires a PAT with Work Items Read & Write scope.
#>
[CmdletBinding(SupportsShouldProcess)]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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

function Get-ClassificationTree([string]$Organization, [string]$Project, [hashtable]$Headers) {
    $projectUri = [Uri]::EscapeDataString($Project)
    $baseUri = "{0}/{1}/_apis/wit/classificationnodes/areas" -f $Organization.TrimEnd('/'), $projectUri
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
        throw "API returned an unexpected Area Path: $ApiPath"
    }
    return $ApiPath.Substring($prefix.Length)
}

function Get-RelativeAreaSet($Tree) {
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rootPath = $Tree.path

    function Get-NodeChildren($Node) {
        if ($null -eq $Node) { return @() }
        $childrenProperty = $Node.PSObject.Properties['children']
        if ($null -eq $childrenProperty -or $null -eq $childrenProperty.Value) {
            return @()
        }
        return @($childrenProperty.Value)
    }

    function Add-Node($Node, [Collections.Generic.HashSet[string]]$Collector, [string]$ApiRootPath) {
        $relative = Get-RelativePath -ApiPath $Node.path -ApiRootPath $ApiRootPath
        [void]$Collector.Add($relative)
        foreach ($child in (Get-NodeChildren -Node $Node)) {
            if ($null -ne $child) { Add-Node -Node $child -Collector $Collector -ApiRootPath $ApiRootPath }
        }
    }

    Add-Node -Node $Tree -Collector $set -ApiRootPath $rootPath
    # Preserve the HashSet as a single object (avoid pipeline unrolling).
    return ,$set
}

$sourceOrganizationInput = Read-Host -Prompt 'Source Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)'
$sourceOrganization = Resolve-OrganizationUrl -InputValue $sourceOrganizationInput -Label 'Source organization'

$sourceProject = Read-Host 'Source project name'
if ([string]::IsNullOrWhiteSpace($sourceProject)) { throw 'Source project name is required.' }

$sourcePatSecure = Read-Host 'Source Azure DevOps PAT (Work Items Read & Write)' -AsSecureString
$sourcePlainPat = Get-PlainText -SecureValue $sourcePatSecure

$targetOrganizationInput = Read-Host -Prompt 'Target Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)'
$targetOrganization = Resolve-OrganizationUrl -InputValue $targetOrganizationInput -Label 'Target organization'

$targetProject = Read-Host 'Target project name'
if ([string]::IsNullOrWhiteSpace($targetProject)) { throw 'Target project name is required.' }

$targetPatSecure = Read-Host 'Target Azure DevOps PAT (Work Items Read & Write)' -AsSecureString
$targetPlainPat = Get-PlainText -SecureValue $targetPatSecure

try {
    $sourceHeaders = New-AdoHeaders -PlainPat $sourcePlainPat
    $targetHeaders = New-AdoHeaders -PlainPat $targetPlainPat

    Write-Host "Reading source Area Paths from '$sourceOrganization/$sourceProject'..."
    $source = Get-ClassificationTree -Organization $sourceOrganization -Project $sourceProject -Headers $sourceHeaders
    $sourceSet = Get-RelativeAreaSet -Tree $source.Tree

    Write-Host "Reading target Area Paths from '$targetOrganization/$targetProject'..."
    $target = Get-ClassificationTree -Organization $targetOrganization -Project $targetProject -Headers $targetHeaders
    $targetSet = Get-RelativeAreaSet -Tree $target.Tree

    $toCreate = @(
        $sourceSet |
            Where-Object { $_ -ne '' -and -not $targetSet.Contains($_) } |
            Sort-Object { ($_ -split '\\').Count }, @{ Expression = { $_ } }
    )

    Write-Host "Source Area Paths (including root): $($sourceSet.Count)"
    Write-Host "Target Area Paths (including root): $($targetSet.Count)"
    Write-Host "Missing Area Paths to create: $($toCreate.Count)"

    $created = [Collections.Generic.List[string]]::new()

    foreach ($relativeAreaPath in $toCreate) {
        $name = $relativeAreaPath.Substring($relativeAreaPath.LastIndexOf([char]'\') + 1)
        $parentRelativePath = if ($relativeAreaPath.Contains('\')) {
            $relativeAreaPath.Substring(0, $relativeAreaPath.LastIndexOf([char]'\'))
        } else {
            ''
        }

        $parentUri = if ([string]::IsNullOrEmpty($parentRelativePath)) {
            $target.BaseUri
        } else {
            $encodedSegments = $parentRelativePath.Split([char]'\') | ForEach-Object { [Uri]::EscapeDataString($_) }
            "$($target.BaseUri)/$($encodedSegments -join '/')"
        }

        if ($PSCmdlet.ShouldProcess("$targetProject/$relativeAreaPath", 'Create Azure DevOps Area Path')) {
            $body = @{ name = $name } | ConvertTo-Json -Compress
            Invoke-WebRequest -Method Post -Uri "${parentUri}?api-version=7.1" -Headers $targetHeaders -Body $body -TimeoutSec 30 -UseBasicParsing | Out-Null
            [void]$created.Add($relativeAreaPath)
        }
    }

    Write-Host 'Verifying target Area Paths...'
    $targetFinal = Get-ClassificationTree -Organization $targetOrganization -Project $targetProject -Headers $targetHeaders
    $targetFinalSet = Get-RelativeAreaSet -Tree $targetFinal.Tree

    $missingAfterImport = @(
        $sourceSet |
            Where-Object { -not $targetFinalSet.Contains($_) }
    )

    if (@($missingAfterImport).Count -gt 0) {
        throw "Verification failed. Missing in target: $($missingAfterImport -join '; ')"
    }

    Write-Host "Migration complete. Created $($created.Count) Area Path node(s) in '$targetProject'."
    $created
}
finally {
    if ($sourcePlainPat) { $sourcePlainPat = $null }
    if ($targetPlainPat) { $targetPlainPat = $null }
}
