<#
.SYNOPSIS
Loads an extracted Azure DevOps wiki into a target project wiki.

.DESCRIPTION
Reads Markdown files and wiki-export-manifest.json produced by
ado-extract-wiki.ps1, creates or reuses the target project wiki, uploads pages
in parent-first order, and validates every target page after writing it.

.PARAMETER SourcePath
Path to one extracted wiki folder containing wiki-export-manifest.json. Prompts
when omitted.

.PARAMETER Organization
Target Azure DevOps organization name or URL. Prompts when omitted.

.PARAMETER Project
Target Azure DevOps project name or ID. Prompts when omitted.

.EXAMPLE
.\ado-load-wiki.ps1

.EXAMPLE
.\ado-load-wiki.ps1 -SourcePath .\wiki-export\Source.wiki `
    -Organization contoso -Project TargetProject
#>
[CmdletBinding()]
param(
    [string]$SourcePath,
    [string]$Organization,
    [string]$Project,
    [switch]$NoExecute,
    [SecureString]$TargetPat,
    [string]$ApiBaseUri = 'https://dev.azure.com',
    [string]$LogDirectory,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
$script:ApiBaseUri = $ApiBaseUri.TrimEnd('/')
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'load-wiki'; throw }

function ConvertTo-UriSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [Uri]::EscapeDataString($Value)
}

function ConvertTo-AdoOrganizationName {
    param(
        [Parameter(Mandatory)]
        [string]$OrganizationInput
    )

    $value = $OrganizationInput.Trim().TrimEnd('/')
    if ($value -match '^https?://dev\.azure\.com/([^/?#]+)$') {
        return $Matches[1]
    }
    if ($value -match '^https?://([^.]+)\.visualstudio\.com$') {
        return $Matches[1]
    }
    if ($value -match '^[^/\s]+$') {
        return $value
    }

    throw 'Azure DevOps organization must be an organization name or URL (for example, contoso or https://dev.azure.com/contoso).'
}

function Get-AzureDevOpsHeaders {
    param(
        [Parameter(Mandatory = $true)]
        [securestring]$PersonalAccessToken
    )

    $credential = [pscredential]::new('pat', $PersonalAccessToken)
    $plainTextPat = $credential.GetNetworkCredential().Password
    try {
        $encodedToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$plainTextPat"))
        return @{
            Authorization  = "Basic $encodedToken"
            Accept         = 'application/json'
            'Content-Type' = 'application/json'
        }
    }
    finally {
        $plainTextPat = $null
    }
}

function Get-TextSha256 {
    param(
        [AllowEmptyString()]
        [string]$Content
    )

    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Content)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function ConvertFrom-QuotedPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedPath = $Path.Trim()
    if ($normalizedPath.Length -ge 2) {
        $firstCharacter = $normalizedPath[0]
        $lastCharacter = $normalizedPath[$normalizedPath.Length - 1]
        if (($firstCharacter -eq '"' -and $lastCharacter -eq '"') -or
            ($firstCharacter -eq "'" -and $lastCharacter -eq "'")) {
            $normalizedPath = $normalizedPath.Substring(1, $normalizedPath.Length - 2)
        }
    }

    return $normalizedPath
}

function Resolve-WikiExport {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedPath = ConvertFrom-QuotedPath -Path $Path
    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        throw 'Source path is empty.'
    }

    $resolvedPath = (Resolve-Path -LiteralPath $normalizedPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Container)) {
        throw "Source path is not a folder: $resolvedPath"
    }

    $directManifest = Join-Path $resolvedPath 'wiki-export-manifest.json'
    if (Test-Path -LiteralPath $directManifest -PathType Leaf) {
        $manifestPath = $directManifest
        $wikiDirectory = $resolvedPath
    }
    else {
        $manifests = @(Get-ChildItem -LiteralPath $resolvedPath -Filter 'wiki-export-manifest.json' -File -Recurse)
        if ($manifests.Count -eq 0) {
            throw "No wiki-export-manifest.json was found under '$resolvedPath'. Select a folder created by ado-extract-wiki.ps1."
        }
        if ($manifests.Count -gt 1) {
            throw "Multiple wiki exports were found under '$resolvedPath'. Select one wiki folder containing a single wiki-export-manifest.json."
        }

        $manifestPath = $manifests[0].FullName
        $wikiDirectory = $manifests[0].Directory.FullName
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $manifest.pages) {
        throw "The manifest does not contain a pages collection: $manifestPath"
    }

    $wikiRoot = [IO.Path]::GetFullPath($wikiDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $wikiRootPrefix = "$wikiRoot$([IO.Path]::DirectorySeparatorChar)"
    $validatedPages = [System.Collections.Generic.List[object]]::new()
    $seenWikiPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($manifestPage in @($manifest.pages)) {
        $wikiPath = if ($null -eq $manifestPage.wikiPath) { '' } else { [string]$manifestPage.wikiPath }
        $relativeFile = if ($null -eq $manifestPage.relativeFile) { '' } else { [string]$manifestPage.relativeFile }

        if ([string]::IsNullOrWhiteSpace($wikiPath) -or $wikiPath -eq '/' -or -not $wikiPath.StartsWith('/')) {
            throw "Manifest contains an invalid wiki path: '$wikiPath'."
        }
        if (-not $seenWikiPaths.Add($wikiPath)) {
            throw "Manifest contains duplicate wiki path '$wikiPath'."
        }
        if ([string]::IsNullOrWhiteSpace($relativeFile)) {
            throw "Manifest page '$wikiPath' has no relativeFile value."
        }

        $filePath = [IO.Path]::GetFullPath((Join-Path $wikiDirectory $relativeFile))
        if (-not $filePath.StartsWith($wikiRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Manifest page '$wikiPath' resolves outside the source folder."
        }
        if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Markdown file is missing for '$wikiPath': $filePath"
        }

        $content = [IO.File]::ReadAllText($filePath, [Text.UTF8Encoding]::new($false))
        $actualHash = Get-TextSha256 -Content $content
        $expectedHash = if ($null -eq $manifestPage.sha256) { '' } else { [string]$manifestPage.sha256 }
        if ([string]::IsNullOrWhiteSpace($expectedHash) -or $actualHash -cne $expectedHash.ToLowerInvariant()) {
            throw "SHA-256 validation failed for '$wikiPath'. The Markdown file differs from its export manifest."
        }

        $validatedPages.Add([pscustomobject]@{
            WikiPath     = $wikiPath
            RelativeFile = $relativeFile
            FilePath     = $filePath
            Content      = $content
            Sha256       = $actualHash
            Order        = $manifestPage.order
        })
    }

    $declaredPageCount = if ($null -eq $manifest.pageCount) { -1 } else { [int]$manifest.pageCount }
    if ($declaredPageCount -ne $validatedPages.Count) {
        throw "Manifest pageCount is $declaredPageCount but $($validatedPages.Count) page entries were validated."
    }

    return [pscustomobject]@{
        Directory = $wikiDirectory
        Manifest  = $manifest
        Pages     = $validatedPages.ToArray()
    }
}

function Invoke-AzureDevOpsGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
}

function Get-AzureDevOpsProject {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $organizationSegment = ConvertTo-UriSegment -Value $Organization
    $uri = "$script:ApiBaseUri/{0}/_apis/projects/{1}?api-version=7.1" -f `
        $organizationSegment, (ConvertTo-UriSegment -Value $Project)
    return Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers
}

function Get-AzureDevOpsWikis {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $organizationSegment = ConvertTo-UriSegment -Value $Organization
    $uri = "$script:ApiBaseUri/$organizationSegment/$(ConvertTo-UriSegment -Value $Project)/_apis/wiki/wikis?api-version=7.1"
    $response = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers
    if ($null -ne $response.value) {
        return @($response.value)
    }

    return @($response)
}

function Get-OrCreateTargetWiki {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [object]$ProjectDetails,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $projectId = [string]$ProjectDetails.id
    $projectName = [string]$ProjectDetails.name
    $wikis = @(Get-AzureDevOpsWikis -Organization $Organization -Project $projectId -Headers $Headers)
    $projectWiki = $wikis | Where-Object { $_.type -eq 'projectWiki' } | Select-Object -First 1
    if ($null -eq $projectWiki) {
        $projectWiki = $wikis | Where-Object {
            $_.name -eq $projectName -or $_.name -eq "$projectName.wiki"
        } | Select-Object -First 1
    }

    if ($null -ne $projectWiki) {
        Write-Host "Using existing target wiki '$($projectWiki.name)'." -ForegroundColor Cyan
        return $projectWiki
    }

    $organizationSegment = ConvertTo-UriSegment -Value $Organization
    $uri = "$script:ApiBaseUri/$organizationSegment/$(ConvertTo-UriSegment -Value $projectId)/_apis/wiki/wikis?api-version=7.1-preview.2"
    $body = @{
        name      = $projectName
        type      = 'projectWiki'
        projectId = $projectId
    } | ConvertTo-Json -Depth 3

    $wiki = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Post -Body $body -ErrorAction Stop
    Write-Host "Created target wiki '$($wiki.name)'." -ForegroundColor Green
    return $wiki
}

function Get-AzureDevOpsWikiPageState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$WikiIdentifier,
        [Parameter(Mandatory = $true)]
        [string]$PagePath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $organizationSegment = ConvertTo-UriSegment -Value $Organization
    $wikiSegment = ConvertTo-UriSegment -Value $WikiIdentifier
    $encodedPath = [Uri]::EscapeDataString($PagePath)
    $uri = "$script:ApiBaseUri/$organizationSegment/$(ConvertTo-UriSegment -Value $Project)/_apis/wiki/wikis/$wikiSegment/pages?path=$encodedPath&includeContent=true&api-version=7.1"

    try {
        $response = Invoke-WebRequest -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
        $page = $response.Content | ConvertFrom-Json
        return [pscustomobject]@{
            Exists  = $true
            ETag    = [string]$response.Headers['ETag']
            Content = if ($null -eq $page.content) { '' } else { [string]$page.content }
        }
    }
    catch {
        $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -eq 404) {
            return [pscustomobject]@{ Exists = $false; ETag = $null; Content = $null }
        }
        throw
    }
}

function Set-AzureDevOpsWikiPage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$WikiIdentifier,
        [Parameter(Mandatory = $true)]
        [string]$PagePath,
        [AllowEmptyString()]
        [string]$Content,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $state = Get-AzureDevOpsWikiPageState -Organization $Organization -Project $Project `
        -WikiIdentifier $WikiIdentifier -PagePath $PagePath -Headers $Headers
    $requestHeaders = $Headers.Clone()

    if ($state.Exists) {
        if ($state.Content -cne $null -and $state.Content -ceq $Content) { return 'Skipped' }
        if ([string]::IsNullOrWhiteSpace($state.ETag)) {
            throw "Azure DevOps did not return an ETag for existing page '$PagePath'."
        }
        $requestHeaders['If-Match'] = $state.ETag
    }

    $organizationSegment = ConvertTo-UriSegment -Value $Organization
    $wikiSegment = ConvertTo-UriSegment -Value $WikiIdentifier
    $encodedPath = [Uri]::EscapeDataString($PagePath)
    $uri = "$script:ApiBaseUri/$organizationSegment/$(ConvertTo-UriSegment -Value $Project)/_apis/wiki/wikis/$wikiSegment/pages?path=$encodedPath&api-version=7.1"
    $body = @{ content = $Content } | ConvertTo-Json
    $null = Invoke-RestMethod -Uri $uri -Headers $requestHeaders -Method Put -Body $body -ErrorAction Stop

    if ($state.Exists) {
        return 'Updated'
    }

    return 'Created'
}

function Test-AzureDevOpsWikiPage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$WikiIdentifier,
        [Parameter(Mandatory = $true)]
        [object]$SourcePage,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $state = Get-AzureDevOpsWikiPageState -Organization $Organization -Project $Project `
        -WikiIdentifier $WikiIdentifier -PagePath $SourcePage.WikiPath -Headers $Headers
    if (-not $state.Exists) {
        throw "Target validation failed: page '$($SourcePage.WikiPath)' does not exist."
    }

    $targetHash = Get-TextSha256 -Content $state.Content
    if ($targetHash -cne $SourcePage.Sha256) {
        throw "Target validation failed: content differs for '$($SourcePage.WikiPath)'."
    }
}

function Import-AzureDevOpsWiki {
    param(
        [Parameter(Mandatory = $true)]
        [object]$WikiExport,
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [object]$ProjectDetails,
        [Parameter(Mandatory = $true)]
        [object]$Wiki,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $projectId = [string]$ProjectDetails.id
    $wikiIdentifier = if ([string]::IsNullOrWhiteSpace([string]$Wiki.id)) { [string]$Wiki.name } else { [string]$Wiki.id }
    $pages = @($WikiExport.Pages) | Sort-Object `
        @{ Expression = { ([string]$_.WikiPath).Trim('/').Split('/').Count } }, `
        @{ Expression = { [int]$_.Order } }, `
        @{ Expression = { [string]$_.WikiPath } }

    $created = 0
    $updated = 0
    $skipped = 0
    foreach ($page in $pages) {
        $operation = Set-AzureDevOpsWikiPage -Organization $Organization -Project $projectId `
            -WikiIdentifier $wikiIdentifier -PagePath $page.WikiPath -Content $page.Content -Headers $Headers
        if ($operation -eq 'Created') { $created++ }
        elseif ($operation -eq 'Updated') { $updated++ }
        else { $skipped++ }
        Write-Host "  $operation $($page.WikiPath)"
    }

    Write-Host 'Validating target page content...' -ForegroundColor Cyan
    foreach ($page in $pages) {
        Test-AzureDevOpsWikiPage -Organization $Organization -Project $projectId `
            -WikiIdentifier $wikiIdentifier -SourcePage $page -Headers $Headers
    }

    return [pscustomobject]@{
        Total   = $pages.Count
        Created = $created
        Updated = $updated
        Skipped = $skipped
    }
}

function Invoke-WikiLoad {
    try {
        $resolvedSourcePath = $SourcePath
        if ([string]::IsNullOrWhiteSpace($resolvedSourcePath)) {
            $resolvedSourcePath = Read-AdoInput 'Path to source wiki files folder'
        }

        $resolvedOrganization = $Organization
        if ([string]::IsNullOrWhiteSpace($resolvedOrganization)) {
            $resolvedOrganization = Read-AdoInput -Prompt (Get-AdoPrompt TargetOrganization)
        }

        $resolvedProject = $Project
        if ([string]::IsNullOrWhiteSpace($resolvedProject)) {
            $resolvedProject = Read-AdoInput 'Target project name or ID'
        }

        if ([string]::IsNullOrWhiteSpace($resolvedSourcePath) -or
            [string]::IsNullOrWhiteSpace($resolvedOrganization) -or
            [string]::IsNullOrWhiteSpace($resolvedProject)) {
            throw 'Source path, target organization, and target project are required.'
        }

        $resolvedOrganization = ConvertTo-AdoOrganizationName -OrganizationInput $resolvedOrganization

        Write-Host 'Validating source wiki export...' -ForegroundColor Cyan
        $wikiExport = Resolve-WikiExport -Path $resolvedSourcePath
        Write-Host "Validated $($wikiExport.Pages.Count) source page(s) from '$($wikiExport.Manifest.wikiName)'." -ForegroundColor Green

        $personalAccessToken = Resolve-AdoPat -Pat $TargetPat -Role Target
        $headers = Get-AzureDevOpsHeaders -PersonalAccessToken $personalAccessToken
        $projectDetails = Get-AzureDevOpsProject -Organization $resolvedOrganization `
            -Project $resolvedProject -Headers $headers
        Write-Host "Connected to '$resolvedOrganization/$($projectDetails.name)'." -ForegroundColor Green

        $targetWiki = Get-OrCreateTargetWiki -Organization $resolvedOrganization `
            -ProjectDetails $projectDetails -Headers $headers
        $result = Import-AzureDevOpsWiki -WikiExport $wikiExport -Organization $resolvedOrganization `
            -ProjectDetails $projectDetails -Wiki $targetWiki -Headers $headers

        Write-Host "`nWiki load complete. Total: $($result.Total), Created: $($result.Created), Updated: $($result.Updated), Skipped: $($result.Skipped)." -ForegroundColor Green
        Write-Host 'All target page content passed read-back validation.' -ForegroundColor Green
    }
    catch {
        Write-Error "Wiki load failed: $($_.Exception.Message)"
        throw
    }
}

if (-not $NoExecute) {
    Invoke-WikiLoad
}
Complete-AdoScriptRun -Outcome $(if ($NoExecute) { 'preview' } else { 'succeeded' }) -Operation 'load-wiki'
