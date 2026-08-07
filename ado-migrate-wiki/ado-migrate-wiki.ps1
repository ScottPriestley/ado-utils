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
    # Overridable so this script can be exercised end-to-end against a local mock
    # Azure DevOps API surface without live credentials; production runs use the default.
    [string]$ApiBaseUri = 'https://dev.azure.com',
    # Missing source attachments are skipped by default so stale source image links do
    # not block page reloads. Use StrictAttachmentValidation to fail before target writes.
    [switch]$AllowMissingAttachments,
    [switch]$StrictAttachmentValidation,
    [switch]$NoExecute,
    [SecureString]$SourcePat,
    [SecureString]$TargetPat,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'
$script:ApiBaseUri = $ApiBaseUri.TrimEnd('/')
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'migrate-wiki'; throw }

# Resolve LogDirectory the same way Initialize-AdoScriptRun does to avoid system32 write failures
if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $LogDirectory = Join-Path (Split-Path -Parent $PSScriptRoot) 'logs'
}
$resolvedLogDir = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogDirectory))
$script:LogPath = Join-Path $resolvedLogDir "WikiMigration_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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
            Authorization  = "Basic $encodedToken"
            Accept         = 'application/json'
            'Content-Type' = 'application/json'
        }
    }
    finally {
        $plainTextPat = $null
    }
}

function Get-AzureDevOpsErrorMessage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)]
        [string]$Operation,
        [Parameter(Mandatory = $true)]
        [string]$Uri
    )

    $statusCode = if ($null -ne $ErrorRecord.Exception.Response) { [int]$ErrorRecord.Exception.Response.StatusCode } else { 0 }
    $responseText = $null
    if ($null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        $responseText = $ErrorRecord.ErrorDetails.Message
    }
    elseif ($null -ne $ErrorRecord.Exception.Response -and
        $ErrorRecord.Exception.Response.PSObject.Methods.Name -contains 'GetResponseStream') {
        try {
            $stream = $ErrorRecord.Exception.Response.GetResponseStream()
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
        $responseText = $ErrorRecord.Exception.Message
    }

    return "Azure DevOps $Operation failed for '$Uri' with status $statusCode. $responseText"
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
        throw (Get-AzureDevOpsErrorMessage -ErrorRecord $_ -Operation 'GET' -Uri $Uri)
    }
}

function Invoke-AzureDevOpsJsonRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Post', 'Put')]
        [string]$Method,
        [Parameter(Mandatory = $true)]
        [string]$Body
    )

    try {
        # Explicit charset. Windows PowerShell 5.1 and PowerShell before 7.4 encode a
        # string -Body as ASCII/ISO-8859-1 unless the Content-Type carries
        # charset=utf-8, silently degrading characters outside that range: an en dash
        # arrives as a hyphen, curly quotes as straight ones. Wiki pages are full of
        # such characters, so the pages wrote "successfully" and then failed
        # post-write validation because the target content no longer matched the
        # source. ado-dashboard-migration/_common.ps1 carries the same fix.
        return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method $Method -Body $Body `
            -ContentType 'application/json; charset=utf-8' -ErrorAction Stop
    }
    catch {
        throw (Get-AzureDevOpsErrorMessage -ErrorRecord $_ -Operation $Method.ToUpperInvariant() -Uri $Uri)
    }
}

function Invoke-AzureDevOpsBinaryGet {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $tempFile = [IO.Path]::GetTempFileName()
    $binaryHeaders = $Headers.Clone()
    $binaryHeaders['Accept'] = 'application/octet-stream'
    $null = $binaryHeaders.Remove('Content-Type')
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $binaryHeaders -Method Get -OutFile $tempFile -ErrorAction Stop
        if ($null -ne $response) {
            $contentType = [string]$response.Headers['Content-Type']
            if ($contentType.StartsWith('application/json', [StringComparison]::OrdinalIgnoreCase)) {
                throw "Azure DevOps returned JSON metadata instead of the requested binary content for '$Uri'."
            }
        }
        return [IO.File]::ReadAllBytes($tempFile)
    }
    catch {
        throw (Get-AzureDevOpsErrorMessage -ErrorRecord $_ -Operation 'GET' -Uri $Uri)
    }
    finally {
        if (Test-Path -LiteralPath $tempFile -PathType Leaf) {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ByteArraySha256 {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [byte[]]$Content
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Content))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Test-RequiredInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name is required."
    }
}

function Test-WikiPagePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PagePath
    )

    if ([string]::IsNullOrWhiteSpace($PagePath) -or $PagePath -eq '/' -or -not $PagePath.StartsWith('/')) {
        throw "Wiki page path '$PagePath' does not identify a writable page."
    }
}

function Get-WikiAttachmentReferences {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Pages
    )

    $references = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # The first alternative supports Markdown angle-bracket destinations containing spaces;
    # the second handles the normal URL-encoded destination emitted by Azure DevOps.
    $pattern = '(?i)(?:\.\./)*/?\.attachments/(?:[^<>\r\n]+(?=>)|[^\s\)\]\"''<>]+)'

    foreach ($page in $Pages) {
        $content = if ($null -eq $page.Content) { '' } else { [string]$page.Content }
        foreach ($match in [regex]::Matches($content, $pattern)) {
            $markdownPath = $match.Value.Trim()
            $pathWithoutFragment = ($markdownPath -split '[#?]', 2)[0]
            $normalizedPath = ($pathWithoutFragment -replace '^(?:\.\./)+', '').TrimStart('/')
            if (-not $normalizedPath.StartsWith('.attachments/', [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }

            $relativePath = [Uri]::UnescapeDataString($normalizedPath.Substring('.attachments/'.Length)).Replace('\', '/')
            $segments = @($relativePath.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($segments.Count -eq 0 -or @($segments | Where-Object { $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
                throw "Unsafe or empty wiki attachment path '$markdownPath' was found in page '$($page.Path)'."
            }

            $wikiPath = '/.attachments/' + ($segments -join '/')
            $attachmentName = $segments[-1]
            if ($seen.ContainsKey($wikiPath)) {
                if ($seen[$wikiPath] -cne $wikiPath) {
                    throw "Attachment paths '$($seen[$wikiPath])' and '$wikiPath' differ only by case, which is unsafe to migrate."
                }
                continue
            }
            $seen[$wikiPath] = $wikiPath
            $references.Add([pscustomobject]@{
                Name          = $attachmentName
                SourceGitPath = $wikiPath
                MarkdownPath  = $markdownPath
                PagePath      = [string]$page.Path
                    PageVersion   = [string]$page.Version
            })
        }
    }

    return $references.ToArray()
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

    $uri = "$script:ApiBaseUri/{0}/_apis/projects/{1}?api-version=7.1" -f `
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

    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/wiki/wikis?api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project)
    $response = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers
    if ($null -ne $response.value) {
        return @($response.value)
    }
    return @($response)
}

function Get-AzureDevOpsWiki {
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

    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/wiki/wikis/{2}?api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $WikiIdentifier)
    return Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers
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

    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/wiki/wikis/{2}/pages?path=%2F&recursionLevel=full&api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $WikiIdentifier)
    $rootPage = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers
    $paths = [System.Collections.Generic.List[string]]::new()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
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

    Test-WikiPagePath -PagePath $PagePath
    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/wiki/wikis/{2}/pages?path={3}&includeContent=true&api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $WikiIdentifier), ([Uri]::EscapeDataString($PagePath))
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
        $page = $response.Content | ConvertFrom-Json
    }
    catch {
        throw (Get-AzureDevOpsErrorMessage -ErrorRecord $_ -Operation 'GET' -Uri $uri)
    }
    if ($null -eq $page -or $page.PSObject.Properties.Name -notcontains 'content') {
        throw "Azure DevOps did not return content for '$PagePath'."
    }

    $gitVersion = ([string]$response.Headers['ETag']).Trim().Trim('"')
    if ($gitVersion -notmatch '^[0-9a-fA-F]{40}$') {
        $gitVersion = $null
    }
    $page | Add-Member -NotePropertyName SourceGitVersion -NotePropertyValue $gitVersion -Force
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
            Version = [string]$page.SourceGitVersion
        })
        Write-MigrationLog -Message "Retrieved content for '$path'."
    }
    return $pages.ToArray()
}

function Test-SourceWikiPages {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Pages
    )

    if ($Pages.Count -eq 0) {
        throw 'Source wiki contains no writable pages.'
    }

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($page in $Pages) {
        $path = if ($null -eq $page.Path) { '' } else { [string]$page.Path }
        Test-WikiPagePath -PagePath $path
        if (-not $seenPaths.Add($path)) {
            throw "Source wiki contains duplicate or case-conflicting page path '$path'. No target pages were changed."
        }
        if ($null -eq $page.PSObject.Properties['Content']) {
            throw "Source page '$path' does not contain a Content property."
        }
    }
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
        $matchingWikis = @($wikis | Where-Object {
            $_.id -eq $RequestedWikiName -or $_.name -eq $RequestedWikiName -or $_.name -eq "$RequestedWikiName.wiki"
        })
        if ($matchingWikis.Count -gt 1) {
            throw "Multiple target wikis match '$RequestedWikiName': $((@($matchingWikis.name) -join ', ')). Use the exact target wiki ID."
        }
        $wiki = $matchingWikis | Select-Object -First 1
    }
    else {
        $wiki = $wikis | Where-Object { $_.type -eq 'projectWiki' } | Select-Object -First 1
    }

    if ($null -ne $wiki) {
        Write-MigrationLog -Message "Using existing target wiki '$($wiki.name)'."
        return $wiki
    }

    # A project wiki is backed by a Git repository of the same name, and every project
    # already has a default repository named after the project. Requesting the bare
    # project name therefore fails with TF400948 (repository already exists). Azure
    # DevOps itself names project wikis "<Project>.wiki", so match that.
    $wikiName = if ([string]::IsNullOrWhiteSpace($RequestedWikiName)) { "$projectName.wiki" } else { $RequestedWikiName }
    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/wiki/wikis?api-version=7.1-preview.2" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $projectId)
    $body = @{ name = $wikiName; type = 'projectWiki'; projectId = $projectId } | ConvertTo-Json
    $wiki = Invoke-AzureDevOpsJsonRequest -Uri $uri -Headers $Headers -Method Post -Body $body
    Write-MigrationLog -Message "Created target wiki '$($wiki.name)'." -Level Success
    return $wiki
}

function Get-AzureDevOpsWikiRepositoryId {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Wiki
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Wiki.repositoryId)) {
        return [string]$Wiki.repositoryId
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Wiki.id)) {
        return [string]$Wiki.id
    }

    throw "Wiki '$($Wiki.name)' does not expose a repository ID."
}

function Get-AzureDevOpsWikiMappedPath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Wiki
    )

    $mappedPath = [string]$Wiki.mappedPath
    if ([string]::IsNullOrWhiteSpace($mappedPath) -or $mappedPath -eq '/') {
        return '/'
    }
    return '/' + $mappedPath.Trim('/')
}

function ConvertTo-AzureDevOpsWikiRepositoryPath {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Wiki,
        [Parameter(Mandatory = $true)]
        [string]$WikiPath
    )

    if (-not $WikiPath.StartsWith('/')) {
        throw "Wiki-relative repository path '$WikiPath' must start with '/'."
    }
    $mappedPath = Get-AzureDevOpsWikiMappedPath -Wiki $Wiki
    if ($mappedPath -eq '/') {
        return $WikiPath
    }
    return $mappedPath + $WikiPath
}

function Get-OptionalProperty {
    <#
        Azure DevOps omits optional fields from its JSON rather than sending them as
        null, and Set-StrictMode makes reading an absent property fatal. Version
        descriptors in particular arrive without versionType or versionOptions when
        those hold their default values.
    #>
    param([object]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return '' }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return '' }
    [string]$property.Value
}

function Get-AzureDevOpsWikiBranchRefName {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Wiki
    )

    $versionDescriptor = @($Wiki.versions) | Where-Object {
        $null -ne $_ -and -not [string]::IsNullOrWhiteSpace((Get-OptionalProperty -Object $_ -Name 'version'))
    } | Select-Object -First 1
    if ($null -eq $versionDescriptor) {
        return $null
    }

    $versionType = Get-OptionalProperty -Object $versionDescriptor -Name 'versionType'
    if ([string]::IsNullOrWhiteSpace($versionType)) {
        $versionType = 'branch'
    }
    if ($versionType -ne 'branch') {
        throw "Target wiki '$($Wiki.name)' is pinned to $versionType '$($versionDescriptor.version)' and cannot accept attachment commits."
    }

    $version = [string]$versionDescriptor.version
    if ($version.StartsWith('refs/heads/', [StringComparison]::OrdinalIgnoreCase)) {
        return $version
    }
    return "refs/heads/$version"
}
function Get-AzureDevOpsWikiVersionQuery {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Wiki
    )

    $versionDescriptor = @($Wiki.versions) | Where-Object {
        $null -ne $_ -and -not [string]::IsNullOrWhiteSpace((Get-OptionalProperty -Object $_ -Name 'version'))
    } | Select-Object -First 1
    if ($null -eq $versionDescriptor) {
        return ''
    }

    $descriptorVersion = Get-OptionalProperty -Object $versionDescriptor -Name 'version'
    $descriptorType    = Get-OptionalProperty -Object $versionDescriptor -Name 'versionType'
    $descriptorOptions = Get-OptionalProperty -Object $versionDescriptor -Name 'versionOptions'

    $query = '&versionDescriptor.version={0}' -f (ConvertTo-UriSegment -Value $descriptorVersion)
    if (-not [string]::IsNullOrWhiteSpace($descriptorType)) {
        $query += '&versionDescriptor.versionType={0}' -f (ConvertTo-UriSegment -Value $descriptorType)
    }
    if (-not [string]::IsNullOrWhiteSpace($descriptorOptions)) {
        $query += '&versionDescriptor.versionOptions={0}' -f (ConvertTo-UriSegment -Value $descriptorOptions)
    }
    return $query
}

function Get-AzureDevOpsWikiAttachmentItems {
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

    $repositoryId = Get-AzureDevOpsWikiRepositoryId -Wiki $Wiki
    $versionQuery = Get-AzureDevOpsWikiVersionQuery -Wiki $Wiki
    $attachmentRoot = ConvertTo-AzureDevOpsWikiRepositoryPath -Wiki $Wiki -WikiPath '/.attachments'
    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/git/repositories/{2}/items?scopePath={3}&recursionLevel=Full&includeContentMetadata=false$versionQuery&api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $repositoryId), ([Uri]::EscapeDataString($attachmentRoot))

    try {
        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
    }
    catch {
        $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -eq 404) {
            return @()
        }
        throw (Get-AzureDevOpsErrorMessage -ErrorRecord $_ -Operation 'GET' -Uri $uri)
    }

    $items = if ($null -ne $response.value) { @($response.value) } else { @($response) }
    return @($items | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_.path) -and
        [string]$_.path -ne $attachmentRoot -and
        -not ($_.PSObject.Properties.Name -contains 'isFolder' -and $_.isFolder)
    })
}

function Get-AzureDevOpsWikiAttachmentContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [object]$Wiki,
        [Parameter(Mandatory = $true)]
        [string]$GitPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,
        [string]$Version,
        [ValidateSet('branch', 'tag', 'commit')]
        [string]$VersionType
    )

    $repositoryId = Get-AzureDevOpsWikiRepositoryId -Wiki $Wiki
    if (-not [string]::IsNullOrWhiteSpace($Version)) {
        $versionQuery = '&versionDescriptor.version={0}' -f (ConvertTo-UriSegment -Value $Version)
        if (-not [string]::IsNullOrWhiteSpace($VersionType)) {
            $versionQuery += '&versionDescriptor.versionType={0}' -f (ConvertTo-UriSegment -Value $VersionType)
        }
    }
    else {
        $versionQuery = Get-AzureDevOpsWikiVersionQuery -Wiki $Wiki
    }

    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/git/repositories/{2}/items?path={3}&download=true$versionQuery&api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $repositoryId), ([Uri]::EscapeDataString($GitPath))
    return Invoke-AzureDevOpsBinaryGet -Uri $uri -Headers $Headers
}

function Get-AzureDevOpsGitCommitsForPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [object]$Wiki,
        [Parameter(Mandatory = $true)]
        [string]$GitPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $repositoryId = Get-AzureDevOpsWikiRepositoryId -Wiki $Wiki
    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/git/repositories/{2}/commits?searchCriteria.itemPath={3}&searchCriteria.excludeDeletes=false&%24top=1000" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $repositoryId), ([Uri]::EscapeDataString($GitPath))

    $versionDescriptor = @($Wiki.versions) | Where-Object {
        $null -ne $_ -and -not [string]::IsNullOrWhiteSpace((Get-OptionalProperty -Object $_ -Name 'version'))
    } | Select-Object -First 1
    if ($null -ne $versionDescriptor) {
        $uri += '&searchCriteria.itemVersion.version={0}' -f `
            (ConvertTo-UriSegment -Value (Get-OptionalProperty -Object $versionDescriptor -Name 'version'))
        $descriptorType = Get-OptionalProperty -Object $versionDescriptor -Name 'versionType'
        if (-not [string]::IsNullOrWhiteSpace($descriptorType)) {
            $uri += '&searchCriteria.itemVersion.versionType={0}' -f (ConvertTo-UriSegment -Value $descriptorType)
        }
    }
    $uri += '&api-version=7.1'

    try {
        $response = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers
    }
    catch {
        # Azure DevOps returns 404 for an itemPath history query when that item is
        # absent at the branch tip, even when excludeDeletes=false.
        if ($_.Exception.Message -like '*status 404*') {
            return @()
        }
        throw
    }
    if ($null -ne $response.value) {
        return @($response.value)
    }
    return @($response)
}

function Get-AzureDevOpsHistoricalWikiAttachment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [object]$Wiki,
        [Parameter(Mandatory = $true)]
        [string]$GitPath,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $commits = @(Get-AzureDevOpsGitCommitsForPath -Organization $Organization -Project $Project `
        -Wiki $Wiki -GitPath $GitPath -Headers $Headers)
    foreach ($commit in $commits) {
        $commitId = [string]$commit.commitId
        if ([string]::IsNullOrWhiteSpace($commitId)) {
            continue
        }
        try {
            $content = Get-AzureDevOpsWikiAttachmentContent -Organization $Organization -Project $Project `
                -Wiki $Wiki -GitPath $GitPath -Headers $Headers -Version $commitId -VersionType commit
            if ($content.Count -gt 0) {
                return [pscustomobject]@{ CommitId = $commitId; Content = [byte[]]$content }
            }
        }
        catch {
            if ($_.Exception.Message -notlike '*status 404*') {
                throw
            }
        }
    }
    return $null
}
function Get-AzureDevOpsGitRepositoryDefaultBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$RepositoryId,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/git/repositories/{2}?api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), (ConvertTo-UriSegment -Value $RepositoryId)
    $repo = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers
    $branch = [string]$repo.defaultBranch
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw "Repository '$RepositoryId' does not expose a default branch."
    }
    return $branch
}

function Get-AzureDevOpsGitBranchTipObjectId {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$RepositoryId,
        [Parameter(Mandatory = $true)]
        [string]$BranchRefName,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $filter = $BranchRefName -replace '^refs/', ''
    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/git/repositories/{2}/refs?filter={3}&api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), (ConvertTo-UriSegment -Value $RepositoryId), `
        (ConvertTo-UriSegment -Value $filter)
    $response = Invoke-AzureDevOpsGet -Uri $uri -Headers $Headers
    $ref = @($response.value) | Where-Object { $_.name -eq $BranchRefName } | Select-Object -First 1
    if ($null -eq $ref) {
        throw "Branch ref '$BranchRefName' was not found in repository '$RepositoryId'."
    }
    return [string]$ref.objectId
}

function Set-AzureDevOpsGitItemContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$RepositoryId,
        [Parameter(Mandatory = $true)]
        [string]$BranchRefName,
        [Parameter(Mandatory = $true)]
        [string]$OldObjectId,
        [Parameter(Mandatory = $true)]
        [string]$GitPath,
        [Parameter(Mandatory = $true)]
        [byte[]]$Content,
        [Parameter(Mandatory = $true)]
        [ValidateSet('add', 'edit')]
        [string]$ChangeType,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    # Pushed as a proper Git commit (content base64-encoded only for JSON transport, then
    # decoded server-side) rather than through the Wiki Attachments PUT endpoint, which is
    # create-only and previously received a raw base64 string instead of decoded binary.
    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/git/repositories/{2}/pushes?api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), (ConvertTo-UriSegment -Value $RepositoryId)
    $body = @{
        refUpdates = @(@{ name = $BranchRefName; oldObjectId = $OldObjectId })
        commits    = @(@{
            comment = "Migrate wiki attachment '$GitPath'"
            changes = @(@{
                changeType = $ChangeType
                item       = @{ path = $GitPath }
                # Azure DevOps' Git Push API binary example uses this exact wire value.
                newContent = @{ content = [Convert]::ToBase64String($Content); contentType = 'base64encoded' }
            })
        })
    } | ConvertTo-Json -Depth 10
    $response = Invoke-AzureDevOpsJsonRequest -Uri $uri -Headers $Headers -Method Post -Body $body
    $newObjectId = [string]$response.commits[0].commitId
    if ([string]::IsNullOrWhiteSpace($newObjectId)) {
        throw "Azure DevOps push did not return a commit ID for '$GitPath'."
    }
    return $newObjectId
}

function Copy-AzureDevOpsWikiAttachments {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Pages,
        [Parameter(Mandatory = $true)]
        [string]$SourceOrganization,
        [Parameter(Mandatory = $true)]
        [string]$SourceProject,
        [Parameter(Mandatory = $true)]
        [object]$SourceWiki,
        [Parameter(Mandatory = $true)]
        [hashtable]$SourceHeaders,
        [Parameter(Mandatory = $true)]
        [string]$TargetOrganization,
        [Parameter(Mandatory = $true)]
        [string]$TargetProject,
        [Parameter(Mandatory = $true)]
        [object]$TargetWiki,
        [Parameter(Mandatory = $true)]
        [hashtable]$TargetHeaders,
        [switch]$AllowMissingAttachments
    )

    $attachments = @(Get-WikiAttachmentReferences -Pages $Pages)
    if ($attachments.Count -eq 0) {
        Write-MigrationLog -Message 'No .attachments references were found in source wiki Markdown.'
        return [pscustomobject]@{ Total = 0; Uploaded = 0; Repaired = 0; Skipped = 0 }
    }

    Write-MigrationLog -Message "Preflighting $($attachments.Count) referenced wiki attachment(s)."
    $sourceAttachmentRootDiag = ConvertTo-AzureDevOpsWikiRepositoryPath -Wiki $SourceWiki -WikiPath '/.attachments'
    Write-MigrationLog -Message "Source wiki '$($SourceWiki.name)': repositoryId '$(Get-AzureDevOpsWikiRepositoryId -Wiki $SourceWiki)', mappedPath '$(Get-AzureDevOpsWikiMappedPath -Wiki $SourceWiki)', attachment scopePath '$sourceAttachmentRootDiag'."
    $sourceAttachmentItems = @(Get-AzureDevOpsWikiAttachmentItems -Organization $SourceOrganization -Project $SourceProject `
        -Wiki $SourceWiki -Headers $SourceHeaders)
    Write-MigrationLog -Message "Source wiki attachment listing returned $($sourceAttachmentItems.Count) item(s) under '$sourceAttachmentRootDiag'."
    $sourceAttachmentPaths = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $sourceAttachmentNames = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ambiguousSourceNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $sourceAttachmentItems) {
        $itemPath = [string]$item.path
        if ([string]::IsNullOrWhiteSpace($itemPath)) {
            continue
        }

        $sourceAttachmentPaths[$itemPath] = $itemPath
        $itemName = [IO.Path]::GetFileName($itemPath.Replace('/', [IO.Path]::DirectorySeparatorChar))
        if ([string]::IsNullOrWhiteSpace($itemName) -or $ambiguousSourceNames.Contains($itemName)) {
            continue
        }
        if ($sourceAttachmentNames.ContainsKey($itemName) -and $sourceAttachmentNames[$itemName] -cne $itemPath) {
            $null = $sourceAttachmentNames.Remove($itemName)
            $null = $ambiguousSourceNames.Add($itemName)
        }
        else {
            $sourceAttachmentNames[$itemName] = $itemPath
        }
    }

    # Resolve every reference before changing the target. A migration with a missing or
    # ambiguous source attachment must fail rather than report success with broken links.
    $resolvedAttachments = [System.Collections.Generic.List[object]]::new()
    $resolutionErrors = [System.Collections.Generic.List[string]]::new()
    $skippedAttachments = [System.Collections.Generic.List[string]]::new()
    foreach ($attachment in $attachments) {
        $expectedSourcePath = ConvertTo-AzureDevOpsWikiRepositoryPath -Wiki $SourceWiki -WikiPath $attachment.SourceGitPath
        $resolvedSourcePath = $null
        $historicalAttachment = $null
        if ($sourceAttachmentPaths.ContainsKey($expectedSourcePath)) {
            $resolvedSourcePath = $sourceAttachmentPaths[$expectedSourcePath]
        }
        else {
            # A wiki page ETag is its backing Git commit. If the attachment was later
            # removed from the branch, the page commit is the most precise recovery point.
            if (-not [string]::IsNullOrWhiteSpace($attachment.PageVersion)) {
                try {
                    $pageVersionBytes = Get-AzureDevOpsWikiAttachmentContent -Organization $SourceOrganization -Project $SourceProject `
                        -Wiki $SourceWiki -GitPath $expectedSourcePath -Headers $SourceHeaders `
                        -Version $attachment.PageVersion -VersionType commit
                    if ($pageVersionBytes.Count -gt 0) {
                        $historicalAttachment = [pscustomobject]@{
                            CommitId = $attachment.PageVersion
                            Content  = [byte[]]$pageVersionBytes
                        }
                    }
                }
                catch {
                    if ($_.Exception.Message -notlike '*status 404*') {
                        throw
                    }
                }
            }
            if ($null -eq $historicalAttachment) {
                $historicalAttachment = Get-AzureDevOpsHistoricalWikiAttachment -Organization $SourceOrganization -Project $SourceProject `
                    -Wiki $SourceWiki -GitPath $expectedSourcePath -Headers $SourceHeaders
            }
            if ($null -ne $historicalAttachment) {
                $resolvedSourcePath = $expectedSourcePath
                Write-MigrationLog -Message "Recovered attachment '$($attachment.Name)' from source commit '$($historicalAttachment.CommitId)' because it is no longer present at the source branch tip." -Level Warning
            }
            elseif ($sourceAttachmentNames.ContainsKey($attachment.Name)) {
                $resolvedSourcePath = $sourceAttachmentNames[$attachment.Name]
                Write-MigrationLog -Message "Resolved attachment '$($attachment.Name)' to source repository path '$resolvedSourcePath'." -Level Warning
            }
            elseif ($ambiguousSourceNames.Contains($attachment.Name)) {
                $message = "'$($attachment.MarkdownPath)' on '$($attachment.PagePath)' has an ambiguous filename '$($attachment.Name)'"
                if ($AllowMissingAttachments) {
                    $skippedAttachments.Add($message)
                    Write-MigrationLog -Message "Skipping unresolved attachment (ambiguous): $message." -Level Warning
                }
                else {
                    $resolutionErrors.Add($message)
                }
            }
            else {
                $candidateMatches = @($sourceAttachmentPaths.Keys | Where-Object { $_ -like "*$($attachment.Name)*" })
                if ($candidateMatches.Count -eq 0) {
                    $nameStem = [IO.Path]::GetFileNameWithoutExtension($attachment.Name)
                    if (-not [string]::IsNullOrWhiteSpace($nameStem)) {
                        $candidateMatches = @($sourceAttachmentPaths.Keys | Where-Object { $_ -like "*$nameStem*" })
                    }
                }
                if ($candidateMatches.Count -gt 0) {
                    Write-MigrationLog -Message "Diagnostic: '$($attachment.Name)' was not found at '$expectedSourcePath', but the source listing ($($sourceAttachmentPaths.Count) total item(s)) contains similarly-named path(s): $($candidateMatches -join ', ')." -Level Warning
                }
                else {
                    Write-MigrationLog -Message "Diagnostic: no path in the source attachment listing ($($sourceAttachmentPaths.Count) total item(s)) resembles '$($attachment.Name)'. Expected path was '$expectedSourcePath'." -Level Warning
                }
                $message = "'$($attachment.MarkdownPath)' on '$($attachment.PagePath)' was not found at '$expectedSourcePath' or in its Git history"
                if ($AllowMissingAttachments) {
                    $skippedAttachments.Add($message)
                    Write-MigrationLog -Message "Skipping unresolved attachment (missing): $message." -Level Warning
                }
                else {
                    $resolutionErrors.Add($message)
                }
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($resolvedSourcePath)) {
            $resolvedAttachments.Add([pscustomobject]@{
                Attachment      = $attachment
                SourcePath      = $resolvedSourcePath
                Historical      = $null -ne $historicalAttachment
                HistoricalBytes = if ($null -eq $historicalAttachment) { $null } else { [byte[]]$historicalAttachment.Content }
            })
        }
    }
    if ($resolutionErrors.Count -gt 0) {
        throw "Attachment preflight failed; no target attachments were changed. $($resolutionErrors -join '; ')."
    }

    $targetRepositoryId = Get-AzureDevOpsWikiRepositoryId -Wiki $TargetWiki
    $targetAttachmentItems = @(Get-AzureDevOpsWikiAttachmentItems -Organization $TargetOrganization -Project $TargetProject `
        -Wiki $TargetWiki -Headers $TargetHeaders)
    $targetExistingPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $targetAttachmentItems) {
        $itemPath = [string]$item.path
        if (-not [string]::IsNullOrWhiteSpace($itemPath)) {
            $null = $targetExistingPaths.Add($itemPath)
        }
    }

    $targetBranchRefName = Get-AzureDevOpsWikiBranchRefName -Wiki $TargetWiki
    if ([string]::IsNullOrWhiteSpace($targetBranchRefName)) {
        $targetBranchRefName = Get-AzureDevOpsGitRepositoryDefaultBranch -Organization $TargetOrganization -Project $TargetProject `
            -RepositoryId $targetRepositoryId -Headers $TargetHeaders
    }
    $targetBranchTip = Get-AzureDevOpsGitBranchTipObjectId -Organization $TargetOrganization -Project $TargetProject `
        -RepositoryId $targetRepositoryId -BranchRefName $targetBranchRefName -Headers $TargetHeaders
    Write-MigrationLog -Message "Writing attachments to repository '$targetRepositoryId' branch '$targetBranchRefName' under '$(Get-AzureDevOpsWikiMappedPath -Wiki $TargetWiki)'."

    $uploaded = 0
    $repaired = 0
    $identicalAttachments = 0
    foreach ($resolved in $resolvedAttachments) {
        $attachment = $resolved.Attachment
        if ($resolved.Historical) {
            $content = [byte[]]$resolved.HistoricalBytes
        }
        else {
            $content = Get-AzureDevOpsWikiAttachmentContent -Organization $SourceOrganization -Project $SourceProject `
                -Wiki $SourceWiki -GitPath $resolved.SourcePath -Headers $SourceHeaders
        }
        if ($content.Count -eq 0) {
            throw "Source attachment '$($attachment.Name)' at '$($resolved.SourcePath)' is empty."
        }

        $targetGitPath = ConvertTo-AzureDevOpsWikiRepositoryPath -Wiki $TargetWiki -WikiPath $attachment.SourceGitPath
        $changeType = if ($targetExistingPaths.Contains($targetGitPath)) { 'edit' } else { 'add' }
        if ($changeType -eq 'edit') {
            $existingContent = Get-AzureDevOpsWikiAttachmentContent -Organization $TargetOrganization -Project $TargetProject `
                -Wiki $TargetWiki -GitPath $targetGitPath -Headers $TargetHeaders
            if ($existingContent.Count -eq $content.Count -and (Get-ByteArraySha256 $existingContent) -ceq (Get-ByteArraySha256 $content)) {
                $identicalAttachments++
                Write-MigrationLog -Message "Skipped identical attachment '$($attachment.Name)'."
                continue
            }
        }
        $targetBranchTip = Set-AzureDevOpsGitItemContent -Organization $TargetOrganization -Project $TargetProject `
            -RepositoryId $targetRepositoryId -BranchRefName $targetBranchRefName -OldObjectId $targetBranchTip `
            -GitPath $targetGitPath -Content $content -ChangeType $changeType -Headers $TargetHeaders
        $null = $targetExistingPaths.Add($targetGitPath)

        $targetContent = Get-AzureDevOpsWikiAttachmentContent -Organization $TargetOrganization -Project $TargetProject `
            -Wiki $TargetWiki -GitPath $targetGitPath -Headers $TargetHeaders `
            -Version $targetBranchTip -VersionType commit
        $sourceHash = Get-ByteArraySha256 -Content $content
        $targetHash = Get-ByteArraySha256 -Content $targetContent
        if ($content.Count -ne $targetContent.Count -or $sourceHash -cne $targetHash) {
            throw "Target attachment validation failed for '$targetGitPath'. Source: $($content.Count) bytes ($sourceHash); target: $($targetContent.Count) bytes ($targetHash)."
        }

        if ($changeType -eq 'edit') {
            $repaired++
            Write-MigrationLog -Message "Repaired and validated attachment '$($attachment.Name)' ($($content.Count) bytes, SHA-256 $sourceHash)."
        }
        else {
            $uploaded++
            Write-MigrationLog -Message "Uploaded and validated attachment '$($attachment.Name)' ($($content.Count) bytes, SHA-256 $sourceHash)."
        }
    }

    if ($skippedAttachments.Count -gt 0) {
        Write-MigrationLog -Message "Skipped $($skippedAttachments.Count) unresolved attachment(s); affected pages keep their existing broken link(s): $($skippedAttachments -join '; ')." -Level Warning
    }

    return [pscustomobject]@{ Total = $attachments.Count; Uploaded = $uploaded; Repaired = $repaired; Skipped = ($skippedAttachments.Count + $identicalAttachments) }
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

    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/wiki/wikis/{2}/pages?path={3}&includeContent=true&api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $WikiIdentifier), ([Uri]::EscapeDataString($PagePath))
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
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
        throw (Get-AzureDevOpsErrorMessage -ErrorRecord $_ -Operation 'GET' -Uri $uri)
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

    Test-WikiPagePath -PagePath $PagePath
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

    $uri = "$script:ApiBaseUri/{0}/{1}/_apis/wiki/wikis/{2}/pages?path={3}&api-version=7.1" -f `
        (ConvertTo-UriSegment -Value $Organization), (ConvertTo-UriSegment -Value $Project), `
        (ConvertTo-UriSegment -Value $WikiIdentifier), ([Uri]::EscapeDataString($PagePath))
    $body = @{ content = $Content } | ConvertTo-Json
    $null = Invoke-AzureDevOpsJsonRequest -Uri $uri -Headers $requestHeaders -Method Put -Body $body
    if ($state.Exists) { return 'Updated' }
    return 'Created'
}

function Invoke-WikiMigration {
    try {
        Write-MigrationLog -Message '=== Azure DevOps Wiki Migration Started ==='
        $sourceOrg = if ([string]::IsNullOrWhiteSpace($SourceOrganization)) { Read-AdoInput -Prompt (Get-AdoPrompt SourceOrganization) } else { $SourceOrganization }
        $sourceProjectName = if ([string]::IsNullOrWhiteSpace($SourceProject)) { Read-AdoInput 'Source project name or ID' } else { $SourceProject }
        $sourcePat = Resolve-AdoPat -Pat $SourcePat -Role Source
        $targetOrg = if ([string]::IsNullOrWhiteSpace($TargetOrganization)) { Read-AdoInput -Prompt (Get-AdoPrompt TargetOrganization) } else { $TargetOrganization }
        $targetProjectName = if ([string]::IsNullOrWhiteSpace($TargetProject)) { Read-AdoInput 'Target project name or ID' } else { $TargetProject }
        $targetPat = Resolve-AdoPat -Pat $TargetPat -Role Target

        Test-RequiredInput -Name 'Source organization' -Value $sourceOrg
        Test-RequiredInput -Name 'Source project' -Value $sourceProjectName
        Test-RequiredInput -Name 'Target organization' -Value $targetOrg
        Test-RequiredInput -Name 'Target project' -Value $targetProjectName

        $sourceOrg = ConvertTo-AdoOrganizationName -OrganizationInput $sourceOrg
        $targetOrg = ConvertTo-AdoOrganizationName -OrganizationInput $targetOrg

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

        $sourceWiki = Get-AzureDevOpsWiki -Organization $sourceOrg -Project ([string]$sourceProjectDetails.id) `
            -WikiIdentifier ([string]$sourceWikis[0].id) -Headers $sourceHeaders
        Write-MigrationLog -Message "Reading source wiki '$($sourceWiki.name)'."
        $sourcePages = @(Get-SourceWikiPages -Organization $sourceOrg -Project ([string]$sourceProjectDetails.id) `
            -Wiki $sourceWiki -Headers $sourceHeaders)
        if ($sourcePages.Count -eq 0) {
            throw "Source wiki '$($sourceWiki.name)' contains no writable pages."
        }
        Test-SourceWikiPages -Pages $sourcePages
        Write-MigrationLog -Message "Retrieved content for $($sourcePages.Count) source page(s)." -Level Success

        $targetWiki = Get-OrCreateTargetWiki -Organization $targetOrg -ProjectDetails $targetProjectDetails `
            -RequestedWikiName $TargetWikiName -Headers $targetHeaders
        $targetWikiIdentifier = if ([string]::IsNullOrWhiteSpace([string]$targetWiki.id)) { [string]$targetWiki.name } else { [string]$targetWiki.id }
        $targetWiki = Get-AzureDevOpsWiki -Organization $targetOrg -Project ([string]$targetProjectDetails.id) `
            -WikiIdentifier $targetWikiIdentifier -Headers $targetHeaders

        $attachmentResult = Copy-AzureDevOpsWikiAttachments -Pages $sourcePages `
            -SourceOrganization $sourceOrg -SourceProject ([string]$sourceProjectDetails.id) -SourceWiki $sourceWiki -SourceHeaders $sourceHeaders `
            -TargetOrganization $targetOrg -TargetProject ([string]$targetProjectDetails.id) -TargetWiki $targetWiki -TargetHeaders $targetHeaders `
            -AllowMissingAttachments:($AllowMissingAttachments -or -not $StrictAttachmentValidation)
        if ($attachmentResult.Total -gt 0) {
            Write-MigrationLog -Message "Attachment migration complete. Total: $($attachmentResult.Total), Uploaded: $($attachmentResult.Uploaded), Repaired: $($attachmentResult.Repaired), Skipped: $($attachmentResult.Skipped)." -Level Success
        }

        $orderedPages = $sourcePages | Sort-Object `
            @{ Expression = { ([string]$_.Path).Trim('/').Split('/').Count } }, `
            @{ Expression = { [int]$_.Order } }, `
            @{ Expression = { [string]$_.Path } }

        $created = 0
        $updated = 0
        $skipped = 0
        foreach ($page in $orderedPages) {
            $operation = Set-AzureDevOpsWikiPage -Organization $targetOrg -Project ([string]$targetProjectDetails.id) `
                -WikiIdentifier $targetWikiIdentifier -PagePath $page.Path -Content $page.Content -Headers $targetHeaders
            if ($operation -eq 'Created') { $created++ } elseif ($operation -eq 'Updated') { $updated++ } else { $skipped++ }
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

        Write-MigrationLog -Message "Migration complete. Total: $($orderedPages.Count), Created: $created, Updated: $updated, Skipped: $skipped." -Level Success
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
Complete-AdoScriptRun -Outcome $(if ($NoExecute) { 'preview' } else { 'succeeded' }) -Operation 'migrate-wiki'
