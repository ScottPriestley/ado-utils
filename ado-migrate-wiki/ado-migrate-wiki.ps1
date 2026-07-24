param(
    [string]$SourceWikiName,
    [string]$TargetWikiName,
    [switch]$NoExecute
)

#region Configuration
$ErrorActionPreference = 'Stop'
$VerbosePreference = 'Continue'

# Timestamp for logs and output
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logFile = ".\WikiMigration_$timestamp.log"
$outputFile = ".\WikiMigration_$timestamp.md"
$summaryFile = ".\WikiMigration_Summary_$timestamp.md"

#endregion

#region Logging Functions
function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info',
        [switch]$NoConsole
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    Add-Content -Path $logFile -Value $logEntry -ErrorAction SilentlyContinue
    
    if (-not $NoConsole) {
        switch ($Level) {
            'Error' { Write-Host $logEntry -ForegroundColor Red }
            'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
            'Success' { Write-Host $logEntry -ForegroundColor Green }
            default { Write-Host $logEntry -ForegroundColor Cyan }
        }
    }
}

function Write-Output-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$File = $outputFile
    )
    
    Add-Content -Path $File -Value $Message
}

#endregion

#region User Input Functions
function Get-UserInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,
        [switch]$IsSecret
    )
    
    if ($IsSecret) {
        return Read-Host -Prompt $Prompt -AsSecureString | ConvertFrom-SecureString -AsPlainText
    }
    else {
        return Read-Host -Prompt $Prompt
    }
}

#endregion

#region Authentication Functions
function ConvertTo-UriSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [Uri]::EscapeDataString($Value)
}

function Get-AzureDevOpsAuth {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$PAT
    )
    
    try {
        $base64AuthInfo = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$PAT"))
        return @{
            'Authorization' = "Basic $base64AuthInfo"
            'Content-Type'  = 'application/json'
        }
    }
    catch {
        Write-Log -Message "Failed to create auth headers: $_" -Level Error
        throw
    }
}

function Test-AzureDevOpsConnection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )
    
    try {
        $uri = "https://dev.azure.com/$Organization/_apis/projects?api-version=7.1"
        $null = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
        Write-Log -Message "Successfully connected to organization: $Organization" -Level Success
        return $true
    }
    catch {
        Write-Log -Message "Failed to connect to organization '$Organization': $_" -Level Error
        return $false
    }
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

    try {
        $uri = "https://dev.azure.com/$(ConvertTo-UriSegment -Value $Organization)/_apis/projects?api-version=7.1"
        $projectsResponse = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
        $projectData = @($projectsResponse.value) | Where-Object { $_.name -eq $Project -or $_.id -eq $Project } | Select-Object -First 1

        if ($null -eq $projectData) {
            throw "Project '$Project' was not found in organization '$Organization'."
        }

        return $projectData
    }
    catch {
        Write-Log -Message "Failed to retrieve project details for '$Project': $_" -Level Error
        throw
    }
}

#endregion

#region Wiki Export Functions
function Get-WikiList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )
    
    try {
        $uri = "https://dev.azure.com/$(ConvertTo-UriSegment -Value $Organization)/$(ConvertTo-UriSegment -Value $Project)/_apis/wiki/wikis?api-version=7.1"
        $wikisResponse = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop

        if ($null -ne $wikisResponse -and $null -ne $wikisResponse.value) {
            $wikis = @($wikisResponse.value)
        }
        elseif ($null -ne $wikisResponse) {
            $wikis = @($wikisResponse)
        }
        else {
            $wikis = @()
        }
        
        Write-Log -Message "Found $($wikis.Count) wiki(s) in project '$Project'" -Level Info
        return $wikis
    }
    catch {
        Write-Log -Message "Failed to retrieve wikis from project '$Project': $_" -Level Error
        throw
    }
}

function Get-WikiPages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$WikiIdentifier,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers,
        [string]$Recursion = 'full'
    )

    function Add-WikiPageTree {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Page,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [System.Collections.Generic.List[object]]$OutputPages,
            [Parameter(Mandatory = $true)]
            [AllowEmptyCollection()]
            [System.Collections.Generic.HashSet[string]]$SeenPaths
        )

        $pagePath = if ($null -ne $Page.path) { [string]$Page.path } else { '' }
        if (-not $SeenPaths.Contains($pagePath)) {
            $SeenPaths.Add($pagePath) | Out-Null
            $OutputPages.Add($Page)
        }

        if ($null -ne $Page.subPages) {
            foreach ($subPage in @($Page.subPages)) {
                if ($null -ne $subPage) {
                    Add-WikiPageTree -Page $subPage -OutputPages $OutputPages -SeenPaths $SeenPaths
                }
            }
        }
    }

    try {
        $uri = "https://dev.azure.com/$(ConvertTo-UriSegment -Value $Organization)/$(ConvertTo-UriSegment -Value $Project)/_apis/wiki/wikis/$(ConvertTo-UriSegment -Value $WikiIdentifier)/pages?recursionLevel=$Recursion&includeContent=true&path=%2F&api-version=7.1"

        $pagesResponse = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop

        if ($null -ne $pagesResponse -and $null -ne $pagesResponse.value) {
            $pages = @($pagesResponse.value)
        }
        elseif ($null -ne $pagesResponse) {
            $pages = @($pagesResponse)
        }
        else {
            $pages = @()
        }

        $flattenedPages = [System.Collections.Generic.List[object]]::new()
        $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($page in $pages) {
            if ($null -ne $page) {
                Add-WikiPageTree -Page $page -OutputPages $flattenedPages -SeenPaths $seenPaths
            }
        }

        Write-Log -Message "Retrieved $($flattenedPages.Count) page(s) from wiki '$WikiIdentifier'" -Level Info
        return $flattenedPages.ToArray()
    }
    catch {
        Write-Log -Message "Failed to retrieve wiki pages: $_" -Level Error
        throw
    }
}

function Test-PageCount {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExportData,
        [Parameter(Mandatory = $true)]
        [object]$ImportResult
    )

    $expectedCount = @($ExportData.pages).Count
    $importedCount = if ($null -ne $ImportResult -and $null -ne $ImportResult.importedPages) { [int]$ImportResult.importedPages } else { 0 }

    if ($expectedCount -eq $importedCount) {
        Write-Log -Message "Page count validation passed: exported $expectedCount page(s), imported $importedCount page(s)" -Level Success
        return $true
    }

    Write-Log -Message "Page count validation failed: exported $expectedCount page(s), imported $importedCount page(s)" -Level Warning
    return $false
}

function Test-WikiContent {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExportData,
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$WikiIdentifier,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $targetPages = @(Get-WikiPages -Organization $Organization -Project $Project `
        -WikiIdentifier $WikiIdentifier -Headers $Headers -Recursion 'full')
    $targetByPath = @{}
    foreach ($targetPage in $targetPages) {
        $targetByPath[[string]$targetPage.path] = $targetPage
    }

    $mismatches = [System.Collections.Generic.List[string]]::new()
    foreach ($sourcePage in @($ExportData.pages)) {
        $sourcePath = ConvertTo-WikiPagePath -Path ([string]$sourcePage.path)
        if (-not $targetByPath.ContainsKey($sourcePath)) {
            $mismatches.Add("Missing target page '$sourcePath'")
            continue
        }

        $sourceContent = if ($null -eq $sourcePage.content) { '' } else { [string]$sourcePage.content }
        $targetContent = if ($null -eq $targetByPath[$sourcePath].content) { '' } else { [string]$targetByPath[$sourcePath].content }
        if ($sourceContent -cne $targetContent) {
            $mismatches.Add("Content mismatch for '$sourcePath'")
        }
    }

    if ($mismatches.Count -gt 0) {
        foreach ($mismatch in $mismatches) {
            Write-Log -Message $mismatch -Level Error
        }
        return $false
    }

    Write-Log -Message "Content validation passed for $(@($ExportData.pages).Count) page(s)" -Level Success
    return $true
}

function Export-WikiContent {
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

    try {
        Write-Log -Message "Exporting wiki: $($Wiki.name)" -Level Info

        $pages = Get-WikiPages -Organization $Organization -Project $Project `
            -WikiIdentifier $Wiki.id -Headers $Headers -Recursion 'full'

        $wikiData = @{
            'id'                 = $Wiki.id
            'name'               = $Wiki.name
            'type'               = $Wiki.type
            'url'                = $Wiki.url
            'remoteUrl'          = $Wiki.remoteUrl
            'projectId'          = $Wiki.projectId
            'pages'              = @()
            'exportDate'         = Get-Date -Format 'O'
            'sourceOrganization' = $Organization
            'sourceProject'      = $Project
        }

        foreach ($page in $pages) {
            $pageData = @{
                'path'         = $page.path
                'content'      = $page.content
                'isParentPage' = $page.isParentPage
                'order'        = $page.order
                'gitItemPath'   = $page.gitItemPath
            }
            $wikiData.pages += $pageData
        }

        Write-Log -Message "Exported $($wikiData.pages.Count) pages from wiki: $($Wiki.name)" -Level Success
        return $wikiData
    }
    catch {
        Write-Log -Message "Failed to export wiki '$($Wiki.name)': $_" -Level Error
        throw
    }
}

#endregion

#region Wiki Import Functions

function New-Wiki {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$WikiName,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    try {
        $projectDetails = Get-AzureDevOpsProject -Organization $Organization -Project $Project -Headers $Headers
        $uri = "https://dev.azure.com/$(ConvertTo-UriSegment -Value $Organization)/$(ConvertTo-UriSegment -Value $Project)/_apis/wiki/wikis?api-version=7.1-preview.2"
        $body = @{
            name     = $WikiName
            type     = 'projectWiki'
            projectId = $projectDetails.id
        } | ConvertTo-Json -Depth 3

        $response = Invoke-RestMethod -Uri $uri -Headers $Headers -Method Post -Body $body -ErrorAction Stop
        Write-Log -Message "Created wiki '$WikiName' in project '$Project'" -Level Success
        return $response
    }
    catch {
        Write-Log -Message "Failed to create wiki '$WikiName': $_" -Level Error
        throw
    }
}

function ConvertTo-WikiPagePath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return '/'
    }

    $normalizedPath = $Path.Trim()
    if ($normalizedPath -eq '/' -or $normalizedPath -eq '') {
        return '/'
    }

    if (-not $normalizedPath.StartsWith('/')) {
        $normalizedPath = "/$normalizedPath"
    }

    return $normalizedPath.TrimEnd('/')
}

function Get-WikiPageState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$WikiIdentifier,
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )

    $encodedPath = [Uri]::EscapeDataString((ConvertTo-WikiPagePath -Path $Path))
    $uri = "https://dev.azure.com/$(ConvertTo-UriSegment -Value $Organization)/$(ConvertTo-UriSegment -Value $Project)/_apis/wiki/wikis/$(ConvertTo-UriSegment -Value $WikiIdentifier)/pages?path=$encodedPath&includeContent=true&api-version=7.1"

    try {
        $response = Invoke-WebRequest -Uri $uri -Headers $Headers -Method Get -ErrorAction Stop
        $page = $response.Content | ConvertFrom-Json
        return @{
            Exists  = $true
            ETag    = [string]$response.Headers['ETag']
            Content = if ($null -eq $page.content) { '' } else { [string]$page.content }
        }
    }
    catch {
        $statusCode = if ($null -ne $_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($statusCode -eq 404) {
            return @{ Exists = $false; ETag = $null; Content = $null }
        }
        throw
    }
}

function Test-WikiExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [string]$WikiName,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )
    
    try {
        $wikis = Get-WikiList -Organization $Organization -Project $Project -Headers $Headers
        $existing = $wikis | Where-Object { $_.name -eq $WikiName -or $_.name -eq "$WikiName.wiki" }
        
        return $null -ne $existing
    }
    catch {
        Write-Log -Message "Error checking if wiki exists: $_" -Level Error
        return $false
    }
}

function Import-WikiContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Organization,
        [Parameter(Mandatory = $true)]
        [string]$Project,
        [Parameter(Mandatory = $true)]
        [object]$WikiData,
        [Parameter(Mandatory = $true)]
        [string]$TargetWikiName,
        [Parameter(Mandatory = $true)]
        [hashtable]$Headers
    )
    
    try {
        $wikiName = if ($null -ne $TargetWikiName -and $TargetWikiName -ne '') { [string]$TargetWikiName } else { [string]$WikiData.name }
        Write-Log -Message "Starting import of wiki: $wikiName" -Level Info
        
        $targetWikis = @(Get-WikiList -Organization $Organization -Project $Project -Headers $Headers)
        $targetWiki = $targetWikis | Where-Object { $_.name -eq $wikiName -or $_.name -eq "$wikiName.wiki" } | Select-Object -First 1

        if ($null -ne $targetWiki) {
            $wikiIdentifier = if ($null -ne $targetWiki.id -and $targetWiki.id -ne '') { [string]$targetWiki.id } else { [string]$targetWiki.name }
            $wikiName = [string]$targetWiki.name
            Write-Log -Message "Wiki '$wikiName' already exists in target project. Adding pages to the existing wiki..." -Level Info
        }
        else {
            Write-Log -Message "Wiki '$wikiName' does not exist. Creating..." -Level Info
            try {
                $null = New-Wiki -Organization $Organization -Project $Project -WikiName $wikiName -Headers $Headers

                for ($attempt = 1; $attempt -le 3; $attempt++) {
                    $targetWikis = @(Get-WikiList -Organization $Organization -Project $Project -Headers $Headers)
                    $targetWiki = $targetWikis | Where-Object { $_.name -eq $wikiName -or $_.name -eq "$wikiName.wiki" } | Select-Object -First 1
                    if ($null -ne $targetWiki) {
                        $wikiIdentifier = if ($null -ne $targetWiki.id -and $targetWiki.id -ne '') { [string]$targetWiki.id } else { [string]$targetWiki.name }
                        $wikiName = [string]$targetWiki.name
                        break
                    }
                    if ($attempt -lt 3) {
                        Start-Sleep -Seconds 2
                    }
                }
            }
            catch {
                Write-Log -Message "Unable to create wiki '$wikiName' automatically. Please create it manually in Azure DevOps before rerunning the script." -Level Warning
            }
        }

        if ($null -eq $targetWiki) {
            Write-Log -Message "Wiki '$wikiName' is still unavailable in target project. Skipping page import." -Level Warning
            return @{
                'wikiName'      = $wikiName
                'totalPages'    = $WikiData.pages.Count
                'importedPages' = 0
                'failedPages'   = $WikiData.pages.Count
            }
        }
        
        # Import pages
        $importedPages = 0
        $createdPages = 0
        $updatedPages = 0
        $failedPages = 0
        
        $pagesToImport = @($WikiData.pages) | Sort-Object `
            @{ Expression = { (ConvertTo-WikiPagePath -Path ([string]$_.path)).Split('/').Count } }, `
            @{ Expression = { [int]$_.order } }
        foreach ($page in $pagesToImport) {
            try {
                $sourcePagePath = if ($null -ne $page.path) { [string]$page.path } else { '' }
                $pagePath = ConvertTo-WikiPagePath -Path $sourcePagePath
                $pageContent = if ($null -ne $page.content) { [string]$page.content } else { '' }
                $uri = "https://dev.azure.com/$(ConvertTo-UriSegment -Value $Organization)/$(ConvertTo-UriSegment -Value $Project)/_apis/wiki/wikis/$(ConvertTo-UriSegment -Value $wikiIdentifier)/pages?path=$([Uri]::EscapeDataString($pagePath))&api-version=7.1"
                $pageState = Get-WikiPageState -Organization $Organization -Project $Project `
                    -WikiIdentifier $wikiIdentifier -Path $pagePath -Headers $Headers
                $requestHeaders = $Headers.Clone()

                if ($pageState.Exists) {
                    if ([string]::IsNullOrWhiteSpace($pageState.ETag)) {
                        throw "Azure DevOps did not return an ETag for existing page '$pagePath'."
                    }
                    $requestHeaders['If-Match'] = $pageState.ETag
                }
                
                $body = @{
                    'content' = $pageContent
                } | ConvertTo-Json
                
                $null = Invoke-RestMethod -Uri $uri -Headers $requestHeaders -Method Put `
                    -Body $body -ErrorAction Stop
                
                $importedPages++
                if ($pageState.Exists) {
                    $updatedPages++
                    Write-Log -Message "Updated existing page '$pagePath'" -Level Info
                }
                else {
                    $createdPages++
                    Write-Log -Message "Created page '$pagePath'" -Level Info
                }
            }
            catch {
                $failedPages++
                Write-Log -Message "Failed to import page '$($page.path)': $_" -Level Warning
            }
        }
        
        Write-Log -Message "Wiki import complete. Created: $createdPages, Updated: $updatedPages, Failed: $failedPages" -Level Success
        
        return @{
            'wikiName'      = $wikiName
            'wikiIdentifier' = $wikiIdentifier
            'totalPages'    = $WikiData.pages.Count
            'importedPages' = $importedPages
            'createdPages'  = $createdPages
            'updatedPages'  = $updatedPages
            'failedPages'   = $failedPages
        }
    }
    catch {
        Write-Log -Message "Failed to import wiki content: $_" -Level Error
        throw
    }
}

#endregion

#region Report Functions
function New-ExportReport {
    param(
        [Parameter(Mandatory = $true)]
        [object]$WikiData
    )
    
    $report = @"
# Wiki Export Report

**Export Date:** $(Get-Date -Format 'o')

## Source Information
- **Organization:** $($WikiData.sourceOrganization)
- **Project:** $($WikiData.sourceProject)
- **Wiki Name:** $($WikiData.name)
- **Wiki Type:** $($WikiData.type)
- **Wiki ID:** $($WikiData.id)

## Export Summary
- **Total Pages:** $($WikiData.pages.Count)

## Pages Exported
| Path | Is Parent Page | Order |
|------|---|---|
"@
    
    foreach ($page in $WikiData.pages) {
        $report += "`n| $($page.path) | $($page.isParentPage) | $($page.order) |"
    }
    
    $report += "`n`n## Page Contents`n`n"
    
    foreach ($page in $WikiData.pages) {
        $report += "### $($page.path)`n`n"
        $report += $page.content + "`n`n---`n`n"
    }
    
    return $report
}

function New-ImportReport {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ImportResult,
        [Parameter(Mandatory = $true)]
        [string]$TargetOrganization,
        [Parameter(Mandatory = $true)]
        [string]$TargetProject
    )

    $wikiName = if ($null -ne $ImportResult -and $null -ne $ImportResult.wikiName) { $ImportResult.wikiName } else { 'N/A' }
    $totalPages = if ($null -ne $ImportResult -and $null -ne $ImportResult.totalPages) { [int]$ImportResult.totalPages } else { 0 }
    $importedPages = if ($null -ne $ImportResult -and $null -ne $ImportResult.importedPages) { [int]$ImportResult.importedPages } else { 0 }
    $failedPages = if ($null -ne $ImportResult -and $null -ne $ImportResult.failedPages) { [int]$ImportResult.failedPages } else { 0 }

    $successRate = 'N/A'
    if ($totalPages -gt 0) {
        $successRate = '{0:N2}%' -f (([double]$importedPages / [double]$totalPages) * 100)
    }

    $report = @"
# Wiki Import Report

**Import Date:** $(Get-Date -Format 'o')

## Target Information
- **Organization:** $TargetOrganization
- **Project:** $TargetProject

## Import Summary
- **Wiki Name:** $wikiName
- **Total Pages:** $totalPages
- **Successfully Imported:** $importedPages
- **Failed:** $failedPages
- **Success Rate:** $successRate

"@
    
    if ($failedPages -gt 0) {
        $report += "`n⚠️ **Warning:** Some pages failed to import. Check the log file for details.`n"
    }
    else {
        $report += "`n✅ **Success:** All pages imported successfully!`n"
    }
    
    return $report
}

function New-SummaryReport {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExportData,
        [Parameter(Mandatory = $true)]
        [object]$ImportResult,
        [Parameter(Mandatory = $true)]
        [string]$TargetOrganization,
        [Parameter(Mandatory = $true)]
        [string]$TargetProject
    )

    $sourceOrganization = if ($null -ne $ExportData -and $null -ne $ExportData.sourceOrganization) { $ExportData.sourceOrganization } else { 'N/A' }
    $sourceProject = if ($null -ne $ExportData -and $null -ne $ExportData.sourceProject) { $ExportData.sourceProject } else { 'N/A' }
    $exportWikiName = if ($null -ne $ExportData -and $null -ne $ExportData.name) { $ExportData.name } else { 'N/A' }
    $importWikiName = if ($null -ne $ImportResult -and $null -ne $ImportResult.wikiName) { $ImportResult.wikiName } else { 'N/A' }
    $pagesExported = if ($null -ne $ExportData -and $null -ne $ExportData.pages) { $ExportData.pages.Count } else { 0 }
    $pagesImported = if ($null -ne $ImportResult -and $null -ne $ImportResult.importedPages) { [int]$ImportResult.importedPages } else { 0 }
    $pagesFailed = if ($null -ne $ImportResult -and $null -ne $ImportResult.failedPages) { [int]$ImportResult.failedPages } else { 0 }
    $status = if ($pagesFailed -eq 0) { "✅ **SUCCESS** - All pages migrated successfully" } else { "⚠️ **PARTIAL** - Some pages failed to migrate" }
    
    $report = @"
# Wiki Migration Summary

**Migration Completed:** $(Get-Date -Format 'o')

## Source
- **Organization:** $sourceOrganization
- **Project:** $sourceProject
- **Wiki:** $exportWikiName

## Target
- **Organization:** $TargetOrganization
- **Project:** $TargetProject
- **Wiki:** $importWikiName

## Results
- **Pages Exported:** $pagesExported
- **Pages Imported:** $pagesImported
- **Pages Failed:** $pagesFailed

## Status
$status

## Log Files
- Detailed Log: $logFile
- Export Report: $outputFile
- Summary Report: $summaryFile

"@
    
    return $report
}

#endregion

#region Main Script
function Invoke-WikiMigration {
    try {
        Write-Log -Message "=== Azure DevOps Wiki Migration Script Started ===" -Level Info
        Write-Log -Message "Log file: $logFile" -Level Info
        
        # Gather user inputs
        Write-Host "`n=== Azure DevOps Wiki Migration ===" -ForegroundColor Cyan
        Write-Host "Please provide the following information:`n"
        
        $sourceOrg = Get-UserInput -Prompt "Source Organization (e.g., myorg)"
        $sourceProject = Get-UserInput -Prompt "Source Project Name"
        $sourcePAT = Get-UserInput -Prompt "Source PAT Token" -IsSecret
        
        $targetOrg = Get-UserInput -Prompt "Target Organization (e.g., myorg)"
        $targetProject = Get-UserInput -Prompt "Target Project Name"
        $targetPAT = Get-UserInput -Prompt "Target PAT Token" -IsSecret
        
        Write-Log -Message "User provided all required inputs" -Level Info
        
        # Get authentication headers
        Write-Log -Message "Creating authentication headers..." -Level Info
        $sourceHeaders = Get-AzureDevOpsAuth -Organization $sourceOrg -PAT $sourcePAT
        $targetHeaders = Get-AzureDevOpsAuth -Organization $targetOrg -PAT $targetPAT
        
        # Test connections
        Write-Log -Message "Testing source connection..." -Level Info
        if (-not (Test-AzureDevOpsConnection -Organization $sourceOrg -Headers $sourceHeaders)) {
            throw "Failed to connect to source organization"
        }
        
        Write-Log -Message "Testing target connection..." -Level Info
        if (-not (Test-AzureDevOpsConnection -Organization $targetOrg -Headers $targetHeaders)) {
            throw "Failed to connect to target organization"
        }
        
        # Get source wikis
        Write-Log -Message "Retrieving wikis from source project..." -Level Info
        $sourceWikis = Get-WikiList -Organization $sourceOrg -Project $sourceProject -Headers $sourceHeaders

        if (-not [string]::IsNullOrWhiteSpace($SourceWikiName)) {
            $sourceWikis = @($sourceWikis) | Where-Object {
                $_.name -eq $SourceWikiName -or $_.id -eq $SourceWikiName
            }
        }
        
        if (@($sourceWikis).Count -eq 0) {
            throw "No matching wiki was found in source project '$sourceProject'."
        }

        if (@($sourceWikis).Count -gt 1) {
            $availableWikis = (@($sourceWikis) | ForEach-Object { $_.name }) -join ', '
            throw "Multiple source wikis were found ($availableWikis). Rerun with -SourceWikiName to select one; merging them implicitly could overwrite pages with the same path."
        }
        
        # Process each wiki
        $allExportData = @()
        $allImportResults = @()
        
        foreach ($wiki in $sourceWikis) {
            Write-Host "`nProcessing wiki: $($wiki.name)" -ForegroundColor Yellow
            
            # Export wiki
            $exportData = Export-WikiContent -Organization $sourceOrg -Project $sourceProject `
                -Wiki $wiki -Headers $sourceHeaders
            $allExportData += $exportData
            
            # Import wiki
            $resolvedTargetWikiName = if ([string]::IsNullOrWhiteSpace($TargetWikiName)) { $targetProject } else { $TargetWikiName }
            $importResult = Import-WikiContent -Organization $targetOrg -Project $targetProject `
                -WikiData $exportData -TargetWikiName $resolvedTargetWikiName -Headers $targetHeaders
            if ($importResult.failedPages -gt 0) {
                throw "Failed to import $($importResult.failedPages) page(s) from wiki '$($wiki.name)'."
            }
            if (-not (Test-WikiContent -ExportData $exportData -Organization $targetOrg `
                    -Project $targetProject -WikiIdentifier $importResult.wikiIdentifier -Headers $targetHeaders)) {
                throw "Target validation failed for wiki '$($wiki.name)'."
            }
            $allImportResults += $importResult
        }
        
        # Generate reports
        Write-Log -Message "Generating reports..." -Level Info
        
        Write-Output-Log -Message "# Azure DevOps Wiki Migration - Detailed Export Report`n" -File $outputFile
        Write-Output-Log -Message "**Generated:** $(Get-Date -Format 'o')`n" -File $outputFile
        
        foreach ($exportData in $allExportData) {
            $exportReport = New-ExportReport -WikiData $exportData
            Write-Output-Log -Message $exportReport -File $outputFile
        }
        
        Write-Output-Log -Message "# Azure DevOps Wiki Migration - Import Reports`n" -File $summaryFile
        Write-Output-Log -Message "**Generated:** $(Get-Date -Format 'o')`n" -File $summaryFile
        
        for ($i = 0; $i -lt $allImportResults.Count; $i++) {
            $importReport = New-ImportReport -ImportResult $allImportResults[$i] `
                -TargetOrganization $targetOrg -TargetProject $targetProject
            Write-Output-Log -Message $importReport -File $summaryFile
        }
        
        $summaryReport = New-SummaryReport -ExportData $allExportData[0] `
            -ImportResult $allImportResults[0] -TargetOrganization $targetOrg `
            -TargetProject $targetProject
        Write-Output-Log -Message $summaryReport -File $summaryFile
        
        Write-Log -Message "=== Wiki Migration Completed Successfully ===" -Level Success
        Write-Host "`n✅ Migration completed successfully!" -ForegroundColor Green
        Write-Host "Output files generated:" -ForegroundColor Green
        Write-Host "  - Log:     $logFile" -ForegroundColor Gray
        Write-Host "  - Export:  $outputFile" -ForegroundColor Gray
        Write-Host "  - Summary: $summaryFile" -ForegroundColor Gray
    }
    catch {
        Write-Log -Message "=== Script Failed ===" -Level Error
        Write-Log -Message "Error: $_" -Level Error
        Write-Log -Message "Stack Trace: $($_.ScriptStackTrace)" -Level Error
        
        Write-Host "`n❌ Migration failed. Check the log file for details." -ForegroundColor Red
        Write-Host "Log file: $logFile" -ForegroundColor Red
        
        exit 1
    }
}

# Execute
if (-not $NoExecute) {
    Invoke-WikiMigration
}

#endregion
