<#
.SYNOPSIS
Exports Azure DevOps wiki pages to local Markdown files.

.DESCRIPTION
Connects to an Azure DevOps project, discovers every visible wiki and page, and
writes each page as a UTF-8 Markdown file. Use WikiName to select one wiki.

.PARAMETER Organization
Source Azure DevOps organization name or URL. Prompts when omitted.

.PARAMETER Project
Azure DevOps project name or ID. Prompts when omitted.

.PARAMETER WikiName
Optional wiki name or ID. All visible project wikis are exported when omitted.

.PARAMETER OutputPath
Optional destination directory. Defaults to a timestamped directory.

.EXAMPLE
.\ado-extract-wiki.ps1 -Organization contoso -Project Delivery

.EXAMPLE
.\ado-extract-wiki.ps1 -Organization contoso -Project Delivery `
    -WikiName Delivery.wiki -OutputPath .\wiki-export
#>
[CmdletBinding()]
param(
    [string]$Organization,
    [string]$Project,
    [string]$WikiName,
    [string]$OutputPath,
    [switch]$NoExecute
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

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
        if ([string]::IsNullOrWhiteSpace($plainTextPat)) {
            throw 'A non-empty Azure DevOps PAT is required.'
        }

        $encodedToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$plainTextPat"))
        return @{
            Authorization = "Basic $encodedToken"
            Accept        = 'application/json'
            'Content-Type' = 'application/json'
        }
    }
    finally {
        $plainTextPat = $null
    }
}

function Invoke-AzureDevOpsGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    try {
        return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get -ErrorAction Stop
    }
    catch {
        $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $responseText = $null
        if ($null -ne $_.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            $responseText = $_.ErrorDetails.Message
        }
        elseif ($null -ne $_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($null -ne $stream) {
                    $reader = [IO.StreamReader]::new($stream)
                    try { $responseText = $reader.ReadToEnd() }
                    finally { $reader.Dispose() }
                }
            }
            catch {
                $responseText = $null
            }
        }

        if ([string]::IsNullOrWhiteSpace($responseText)) {
            throw "Azure DevOps GET failed for '$Uri' with status $statusCode. $($_.Exception.Message)"
        }

        throw "Azure DevOps GET failed for '$Uri' with status $statusCode. $responseText"
    }
}

function Resolve-OutputDirectory {
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

    if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
        throw 'Output path is empty.'
    }

    $fullPath = [IO.Path]::GetFullPath($normalizedPath)
    if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
        throw "Output path points to a file, not a folder: '$fullPath'."
    }

    return $fullPath
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
    $projectSegment = ConvertTo-UriSegment -Value $Project
    $uri = "https://dev.azure.com/$organizationSegment/$projectSegment/_apis/wiki/wikis?api-version=7.1"
    $response = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers

    if ($null -ne $response.value) {
        return @($response.value)
    }

    return @($response)
}

function Get-AzureDevOpsWikiPagePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$WikiIdentifier,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    function Add-PagePaths {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Page,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [System.Collections.Generic.List[string]]$Paths,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [System.Collections.Generic.HashSet[string]]$SeenPaths
        )

        $path = if ($null -eq $Page.path) { '' } else { [string]$Page.path }
        if (-not [string]::IsNullOrWhiteSpace($path) -and $path -ne '/' -and $SeenPaths.Add($path)) {
            $Paths.Add($path)
        }

        foreach ($subPage in @($Page.subPages)) {
            if ($null -ne $subPage) {
                Add-PagePaths -Page $subPage -Paths $Paths -SeenPaths $SeenPaths
            }
        }
    }

    $organizationSegment = ConvertTo-UriSegment -Value $Organization
    $projectSegment = ConvertTo-UriSegment -Value $Project
    $wikiSegment = ConvertTo-UriSegment -Value $WikiIdentifier
    $uri = "https://dev.azure.com/$organizationSegment/$projectSegment/_apis/wiki/wikis/$wikiSegment/pages?path=%2F&recursionLevel=full&api-version=7.1"
    $rootPage = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers

    $paths = [System.Collections.Generic.List[string]]::new()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Add-PagePaths -Page $rootPage -Paths $paths -SeenPaths $seenPaths
    return $paths.ToArray()
}

function Get-AzureDevOpsWikiPage {
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
    $projectSegment = ConvertTo-UriSegment -Value $Project
    $wikiSegment = ConvertTo-UriSegment -Value $WikiIdentifier
    $encodedPath = [Uri]::EscapeDataString($PagePath)
    $uri = "https://dev.azure.com/$organizationSegment/$projectSegment/_apis/wiki/wikis/$wikiSegment/pages?path=$encodedPath&includeContent=true&api-version=7.1"
    $page = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers

    if ($null -eq $page -or $page.PSObject.Properties.Name -notcontains 'content') {
        throw "Azure DevOps did not return content for wiki page '$PagePath'."
    }

    return $page
}

function ConvertTo-SafePathSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $safeValue = $Value -replace '[<>:"/\\|?*\x00-\x1F]', '_'
    $safeValue = $safeValue.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safeValue)) {
        $safeValue = '_'
    }

    if ($safeValue -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
        $safeValue = "_$safeValue"
    }

    return $safeValue
}

function ConvertTo-RelativeMarkdownPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WikiPagePath
    )

    if ([string]::IsNullOrWhiteSpace($WikiPagePath) -or $WikiPagePath -eq '/' -or -not $WikiPagePath.StartsWith('/')) {
        throw "Wiki page path '$WikiPagePath' does not identify a writable page."
    }

    $segments = @($WikiPagePath.Trim('/') -split '/' | ForEach-Object {
        ConvertTo-SafePathSegment -Value $_
    })

    if ($segments.Count -eq 0) {
        throw "Wiki page path '$WikiPagePath' does not identify a page."
    }

    $fileName = "$($segments[$segments.Count - 1]).md"
    if ($segments.Count -eq 1) {
        return $fileName
    }

    $directoryPath = [IO.Path]::Combine([string[]]$segments[0..($segments.Count - 2)])
    return [IO.Path]::Combine($directoryPath, $fileName)
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

function Export-AzureDevOpsWiki {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [object]$Wiki,
        [Parameter(Mandatory = $true)]
        [string]$DestinationRoot,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $wikiFolderName = ConvertTo-SafePathSegment -Value ([string]$Wiki.name)
    $wikiDirectory = Join-Path $DestinationRoot $wikiFolderName

    if (Test-Path -LiteralPath $wikiDirectory -PathType Leaf) {
        throw "Destination wiki path points to a file, not a folder: '$wikiDirectory'."
    }

    if (Test-Path -LiteralPath $wikiDirectory -PathType Container) {
        $existingItems = @(Get-ChildItem -LiteralPath $wikiDirectory -Force -ErrorAction Stop | Select-Object -First 1)
        if ($existingItems.Count -gt 0) {
            throw "Destination wiki folder already contains files: '$wikiDirectory'. Choose an empty output path to avoid overwriting an earlier export."
        }
    }

    $null = New-Item -ItemType Directory -Path $wikiDirectory -Force

    Write-Host "Discovering pages in wiki '$($Wiki.name)'..." -ForegroundColor Cyan
    $pagePaths = @(Get-AzureDevOpsWikiPagePaths -Organization $Organization -Project $Project `
        -WikiIdentifier ([string]$Wiki.id) -Headers $Headers)
    if ($pagePaths.Count -eq 0) {
        throw "Wiki '$($Wiki.name)' contains no writable pages to export."
    }

    $relativePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $manifestPages = [System.Collections.Generic.List[object]]::new()
    $utf8WithoutBom = [Text.UTF8Encoding]::new($false)
    $plannedPages = [System.Collections.Generic.List[object]]::new()

    foreach ($pagePath in $pagePaths) {
        $relativePath = ConvertTo-RelativeMarkdownPath -WikiPagePath $pagePath
        if (-not $relativePaths.Add($relativePath)) {
            throw "Multiple wiki pages map to the same local path '$relativePath'. No files were overwritten."
        }

        $filePath = [IO.Path]::GetFullPath((Join-Path $wikiDirectory $relativePath))
        $wikiRoot = [IO.Path]::GetFullPath($wikiDirectory).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $wikiRootPrefix = "$wikiRoot$([IO.Path]::DirectorySeparatorChar)"
        if (-not $filePath.StartsWith($wikiRootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Wiki page path '$pagePath' resolves outside the destination folder."
        }

        $plannedPages.Add([pscustomobject]@{
            WikiPath     = $pagePath
            RelativePath = $relativePath
            FilePath     = $filePath
        })
    }

    foreach ($plannedPage in $plannedPages) {
        $pagePath = $plannedPage.WikiPath
        $page = Get-AzureDevOpsWikiPage -Organization $Organization -Project $Project `
            -WikiIdentifier ([string]$Wiki.id) -PagePath $pagePath -Headers $Headers
        $relativePath = $plannedPage.RelativePath
        $filePath = $plannedPage.FilePath
        $parentDirectory = Split-Path -Parent $filePath
        $null = New-Item -ItemType Directory -Path $parentDirectory -Force

        $content = if ($null -eq $page.content) { '' } else { [string]$page.content }
        [IO.File]::WriteAllText($filePath, $content, $utf8WithoutBom)

        $writtenContent = [IO.File]::ReadAllText($filePath, $utf8WithoutBom)
        if ($writtenContent -cne $content) {
            throw "Content validation failed after writing '$filePath'."
        }

        $manifestPages.Add([ordered]@{
            wikiPath    = [string]$page.path
            relativeFile = $relativePath
            contentLength = $content.Length
            sha256      = Get-TextSha256 -Content $content
            order       = $page.order
            gitItemPath = $page.gitItemPath
        })
        Write-Host "  Exported $pagePath -> $relativePath"
    }

    $manifest = [ordered]@{
        exportedAtUtc = [DateTime]::UtcNow.ToString('O')
        organization  = $Organization
        project       = $Project
        wikiId        = [string]$Wiki.id
        wikiName      = [string]$Wiki.name
        wikiType      = [string]$Wiki.type
        pageCount     = $manifestPages.Count
        pages         = $manifestPages.ToArray()
    }
    $manifestPath = Join-Path $wikiDirectory 'wiki-export-manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8), $utf8WithoutBom)

    Write-Host "Exported $($manifestPages.Count) page(s) from '$($Wiki.name)' to '$wikiDirectory'." -ForegroundColor Green
    return $manifest
}

function Invoke-WikiExtraction {
    try {
        $resolvedOrganization = $Organization
        if ([string]::IsNullOrWhiteSpace($resolvedOrganization)) {
            $resolvedOrganization = Read-Host -Prompt 'Source Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)'
        }

        $resolvedProject = $Project
        if ([string]::IsNullOrWhiteSpace($resolvedProject)) {
            $resolvedProject = Read-Host 'Source project name'
        }

        if ([string]::IsNullOrWhiteSpace($resolvedOrganization) -or [string]::IsNullOrWhiteSpace($resolvedProject)) {
            throw 'Source organization and project are required.'
        }

        $resolvedOrganization = ConvertTo-AdoOrganizationName -OrganizationInput $resolvedOrganization

        $personalAccessToken = Read-Host 'Source PAT token' -AsSecureString
        $headers = Get-AzureDevOpsHeaders -PersonalAccessToken $personalAccessToken

        $projectUri = "https://dev.azure.com/$(ConvertTo-UriSegment -Value $resolvedOrganization)/_apis/projects/$(ConvertTo-UriSegment -Value $resolvedProject)?api-version=7.1"
        $null = Invoke-AzureDevOpsGet -Uri $projectUri -Headers $headers
        Write-Host "Connected to '$resolvedOrganization/$resolvedProject'." -ForegroundColor Green

        $wikis = @(Get-AzureDevOpsWikis -Organization $resolvedOrganization -Project $resolvedProject -Headers $headers)
        if (-not [string]::IsNullOrWhiteSpace($WikiName)) {
            $wikis = @($wikis | Where-Object { $_.name -eq $WikiName -or $_.id -eq $WikiName })
        }

        if ($wikis.Count -eq 0) {
            throw "No matching wikis were found in project '$resolvedProject'."
        }

        $resolvedOutputPath = $OutputPath
        if ([string]::IsNullOrWhiteSpace($resolvedOutputPath)) {
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            $resolvedOutputPath = Join-Path (Get-Location) "WikiExport_${resolvedProject}_$timestamp"
        }
        $resolvedOutputPath = Resolve-OutputDirectory -Path $resolvedOutputPath
        $null = New-Item -ItemType Directory -Path $resolvedOutputPath -Force

        $exportedWikis = [System.Collections.Generic.List[object]]::new()
        $wikiFolderNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($wiki in $wikis) {
            $wikiFolderName = ConvertTo-SafePathSegment -Value ([string]$wiki.name)
            if (-not $wikiFolderNames.Add($wikiFolderName)) {
                throw "Multiple wikis map to the same local folder '$wikiFolderName'. Use -WikiName to export them separately."
            }

            $exportedWikis.Add((Export-AzureDevOpsWiki -Organization $resolvedOrganization `
                -Project $resolvedProject -Wiki $wiki -DestinationRoot $resolvedOutputPath -Headers $headers))
        }

        $totalPages = ($exportedWikis | Measure-Object -Property pageCount -Sum).Sum
        Write-Host "`nExtraction complete: $totalPages page(s) from $($exportedWikis.Count) wiki(s)." -ForegroundColor Green
        Write-Host "Output: $resolvedOutputPath" -ForegroundColor Green
    }
    catch {
        Write-Error "Wiki extraction failed: $($_.Exception.Message)"
        exit 1
    }
}

if (-not $NoExecute) {
    Invoke-WikiExtraction
}
