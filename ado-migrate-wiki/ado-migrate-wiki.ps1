<#
.SYNOPSIS
Migrates one Azure DevOps wiki directly between projects.

.DESCRIPTION
Reads every source wiki page and its Markdown content, creates or reuses the
selected target wiki, writes pages in parent-first order, and validates all
content by reading it back from the target.

.EXAMPLE
.\ado-migrate-wiki.ps1

.EXAMPLE
.\ado-migrate-wiki.ps1 -SourceWikiName Source.wiki -TargetWikiName Target.wiki
#>
[CmdletBinding()]
param(
    [string]$SourceOrganization,
    [string]$SourceProject,
    [string]$SourceWikiName,
    [string]$TargetOrganization,
    [string]$TargetProject,
    [string]$TargetWikiName,
    [switch]$NoExecute
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'
$script:LogPath = Join-Path (Get-Location) "WikiMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-MigrationLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [$Level] $Message"
    Add-Content -LiteralPath $script:LogPath -Value $entry -Encoding UTF8
    $color = switch ($Level) {
        'Error' { 'Red' }
        'Warning' { 'Yellow' }
        'Success' { 'Green' }
        default { 'Cyan' }
    }
    Write-Host $entry -ForegroundColor $color
}

function ConvertTo-UriSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [Uri]::EscapeDataString($Value)
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

    $uri = 'https://dev.azure.com/{0}/_apis/projects/{1}?api-version=7.1' -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project)
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

    $uri = 'https://dev.azure.com/{0}/{1}/_apis/wiki/wikis?api-version=7.1' -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project)
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

    function Add-WikiPagePaths {
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
                Add-WikiPagePaths -Page $subPage -Paths $Paths -SeenPaths $SeenPaths
            }
        }
    }

    $uri = 'https://dev.azure.com/{0}/{1}/_apis/wiki/wikis/{2}/pages?path=%2F&recursionLevel=full&api-version=7.1' -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $WikiIdentifier)
    $rootPage = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers
    $paths = [System.Collections.Generic.List[string]]::new()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    Add-WikiPagePaths -Page $rootPage -Paths $paths -SeenPaths $seenPaths
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

    $uri = 'https://dev.azure.com/{0}/{1}/_apis/wiki/wikis/{2}/pages?path={3}&includeContent=true&api-version=7.1' -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $WikiIdentifier), ([Uri]::EscapeDataString($PagePath))
    $page = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers
    if ($null -eq $page -or $page.PSObject.Properties.Name -notcontains 'content') {
        throw "Azure DevOps did not return content for '$PagePath'."
    }
    return $page
}

function Get-SourceWikiPages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [object]$Wiki,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $paths = @(Get-AzureDevOpsWikiPagePaths -Organization $Organization -Project $Project `
        -WikiIdentifier ([string]$Wiki.id) -Headers $Headers)
    $pages = [System.Collections.Generic.List[object]]::new()
    foreach ($path in $paths) {
        $page = Get-AzureDevOpsWikiPage -Organization $Organization -Project $Project `
            -WikiIdentifier ([string]$Wiki.id) -PagePath $path -Headers $Headers
        $pages.Add([pscustomobject]@{
            Path    = [string]$page.path
            Content = if ($null -eq $page.content) { '' } else { [string]$page.content }
            Order   = $page.order
        })
        Write-MigrationLog -Message "Retrieved content for '$path'."
    }
    return $pages.ToArray()
}

function Get-OrCreateTargetWiki {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [object]$ProjectDetails,
        [string]$RequestedWikiName,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $projectId = [string]$ProjectDetails.id
    $projectName = [string]$ProjectDetails.name
    $wikis = @(Get-AzureDevOpsWikis -Organization $Organization -Project $projectId -Headers $Headers)
    $wiki = $null
    if (-not [string]::IsNullOrWhiteSpace($RequestedWikiName)) {
        $wiki = $wikis | Where-Object {
            $_.id -eq $RequestedWikiName -or $_.name -eq $RequestedWikiName -or $_.name -eq "$RequestedWikiName.wiki"
        } | Select-Object -First 1
    }
    else {
        $wiki = $wikis | Where-Object { $_.type -eq 'projectWiki' } | Select-Object -First 1
    }

    if ($null -ne $wiki) {
        Write-MigrationLog -Message "Using existing target wiki '$($wiki.name)'."
        return $wiki
    }

    $wikiName = if ([string]::IsNullOrWhiteSpace($RequestedWikiName)) { $projectName } else { $RequestedWikiName }
    $uri = 'https://dev.azure.com/{0}/{1}/_apis/wiki/wikis?api-version=7.1-preview.2' -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $projectId)
    $body = @{ name = $wikiName; type = 'projectWiki'; projectId = $projectId } | ConvertTo-Json
    $wiki = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Post -Body $body -ErrorAction Stop
    Write-MigrationLog -Message "Created target wiki '$($wiki.name)'." -Level Success
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

    $uri = 'https://dev.azure.com/{0}/{1}/_apis/wiki/wikis/{2}/pages?path={3}&includeContent=true&api-version=7.1' -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $WikiIdentifier), ([Uri]::EscapeDataString($PagePath))
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
        if ([string]::IsNullOrWhiteSpace($state.ETag)) {
            throw "Azure DevOps did not return an ETag for existing page '$PagePath'."
        }
        $requestHeaders['If-Match'] = $state.ETag
    }

    $uri = 'https://dev.azure.com/{0}/{1}/_apis/wiki/wikis/{2}/pages?path={3}&api-version=7.1' -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $WikiIdentifier), ([Uri]::EscapeDataString($PagePath))
    $body = @{ content = $Content } | ConvertTo-Json
    $null = Invoke-RestMethod -Uri $uri -Headers $requestHeaders -Method Put -Body $body -ErrorAction Stop
    if ($state.Exists) { return 'Updated' }
    return 'Created'
}

function Invoke-WikiMigration {
    try {
        Write-MigrationLog -Message '=== Azure DevOps Wiki Migration Started ==='
        $sourceOrg = if ([string]::IsNullOrWhiteSpace($SourceOrganization)) { Read-Host 'Source organization name' } else { $SourceOrganization }
        $sourceProjectName = if ([string]::IsNullOrWhiteSpace($SourceProject)) { Read-Host 'Source project name or ID' } else { $SourceProject }
        $sourcePat = Read-Host 'Source PAT token' -AsSecureString
        $targetOrg = if ([string]::IsNullOrWhiteSpace($TargetOrganization)) { Read-Host 'Target organization name' } else { $TargetOrganization }
        $targetProjectName = if ([string]::IsNullOrWhiteSpace($TargetProject)) { Read-Host 'Target project name or ID' } else { $TargetProject }
        $targetPat = Read-Host 'Target PAT token' -AsSecureString

        $sourceHeaders = Get-AzureDevOpsHeaders -PersonalAccessToken $sourcePat
        $targetHeaders = Get-AzureDevOpsHeaders -PersonalAccessToken $targetPat
        $sourceProjectDetails = Get-AzureDevOpsProject -Organization $sourceOrg -Project $sourceProjectName -Headers $sourceHeaders
        $targetProjectDetails = Get-AzureDevOpsProject -Organization $targetOrg -Project $targetProjectName -Headers $targetHeaders
        Write-MigrationLog -Message 'Connected to source and target projects.' -Level Success

        $sourceWikis = @(Get-AzureDevOpsWikis -Organization $sourceOrg -Project ([string]$sourceProjectDetails.id) -Headers $sourceHeaders)
        if (-not [string]::IsNullOrWhiteSpace($SourceWikiName)) {
            $sourceWikis = @($sourceWikis | Where-Object {
                $_.id -eq $SourceWikiName -or $_.name -eq $SourceWikiName -or $_.name -eq "$SourceWikiName.wiki"
            })
        }
        if ($sourceWikis.Count -eq 0) {
            throw 'No matching source wiki was found.'
        }
        if ($sourceWikis.Count -gt 1) {
            throw "Multiple source wikis were found: $((@($sourceWikis.name) -join ', ')). Use -SourceWikiName."
        }

        $sourceWiki = $sourceWikis[0]
        Write-MigrationLog -Message "Reading source wiki '$($sourceWiki.name)'."
        $sourcePages = @(Get-SourceWikiPages -Organization $sourceOrg -Project ([string]$sourceProjectDetails.id) `
            -Wiki $sourceWiki -Headers $sourceHeaders)
        if ($sourcePages.Count -eq 0) {
            throw "Source wiki '$($sourceWiki.name)' contains no writable pages."
        }
        Write-MigrationLog -Message "Retrieved content for $($sourcePages.Count) source page(s)." -Level Success

        $targetWiki = Get-OrCreateTargetWiki -Organization $targetOrg -ProjectDetails $targetProjectDetails `
            -RequestedWikiName $TargetWikiName -Headers $targetHeaders
        $targetWikiIdentifier = if ([string]::IsNullOrWhiteSpace([string]$targetWiki.id)) { [string]$targetWiki.name } else { [string]$targetWiki.id }
        $orderedPages = $sourcePages | Sort-Object `
            @{ Expression = { ([string]$_.Path).Trim('/').Split('/').Count } }, `
            @{ Expression = { [int]$_.Order } }, `
            @{ Expression = { [string]$_.Path } }

        $created = 0
        $updated = 0
        foreach ($page in $orderedPages) {
            $operation = Set-AzureDevOpsWikiPage -Organization $targetOrg -Project ([string]$targetProjectDetails.id) `
                -WikiIdentifier $targetWikiIdentifier -PagePath $page.Path -Content $page.Content -Headers $targetHeaders
            if ($operation -eq 'Created') { $created++ } else { $updated++ }
            Write-MigrationLog -Message "$operation '$($page.Path)'."
        }

        Write-MigrationLog -Message 'Validating target page content.'
        foreach ($page in $orderedPages) {
            $targetState = Get-AzureDevOpsWikiPageState -Organization $targetOrg -Project ([string]$targetProjectDetails.id) `
                -WikiIdentifier $targetWikiIdentifier -PagePath $page.Path -Headers $targetHeaders
            if (-not $targetState.Exists -or $targetState.Content -cne $page.Content) {
                throw "Target validation failed for '$($page.Path)'."
            }
        }

        Write-MigrationLog -Message "Migration complete. Total: $($orderedPages.Count), Created: $created, Updated: $updated." -Level Success
        Write-Host "Log: $script:LogPath" -ForegroundColor Green
    }
    catch {
        Write-MigrationLog -Message "Migration failed: $($_.Exception.Message)" -Level Error
        throw
    }
}

if (-not $NoExecute) {
    Invoke-WikiMigration
}
