[CmdletBinding()]
param(
    [string]$ProjectUrl,
    [SecureString]$Pat,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$commonModulePath = Join-Path $PSScriptRoot 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'extract-discussions'; throw }

function Invoke-AdoRestMethod {
    param(
        [Parameter(Mandatory)]
        [string]$Uri,

        [ValidateSet('Get', 'Post')]
        [string]$Method = 'Get',

        [hashtable]$Headers,
        [object]$Body,
        [string]$ContentType,
        [int]$MaxAttempts = 5
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $parameters = @{
                Uri         = $Uri
                Method      = $Method
                Headers     = $Headers
                ErrorAction = 'Stop'
            }

            if ($null -ne $Body) {
                $parameters.Body = $Body
            }
            if ($ContentType) {
                $parameters.ContentType = $ContentType
            }

            return Invoke-RestMethod @parameters
        }
        catch {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            $isTransient = $statusCode -eq 0 -or $statusCode -in 408, 429, 500, 502, 503, 504

            if (-not $isTransient -or $attempt -eq $MaxAttempts) {
                throw
            }

            $delaySeconds = [Math]::Min([Math]::Pow(2, $attempt), 30)
            Write-Warning "Request failed (attempt $attempt of $MaxAttempts). Retrying in $delaySeconds seconds: $($_.Exception.Message)"
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Export-AdoWorkItem {
    param(
        [Parameter(Mandatory)]
        [psobject]$InputObject,

        [Parameter(Mandatory)]
        [string]$Path,

        [int]$MaxAttempts = 10
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $InputObject | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8 -Append -ErrorAction Stop
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -eq $MaxAttempts) {
                throw
            }

            Write-Warning "Output file is temporarily unavailable (attempt $attempt of $MaxAttempts). Retrying in 2 seconds."
            Start-Sleep -Seconds 2
        }
    }
}

# Prompt for inputs
if ([string]::IsNullOrWhiteSpace($ProjectUrl)) {
    $ProjectUrl = Read-AdoInput "Enter the Azure DevOps Project URL (e.g. https://dev.azure.com/contoso/ProjectName)"
}
$orgUrl = $ProjectUrl.TrimEnd('/')
$resolvedPat = Resolve-AdoPat -Pat $Pat -Role Default
$patPlain = ConvertFrom-AdoSecureString -SecureString $resolvedPat

# Encode PAT for Authorization header
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$patPlain"))
$patPlain = $null
$headers = @{ Authorization = "Basic $auth" }

# Output CSV
$outFile = Join-Path $PSScriptRoot "AdoWorkItemDiscussions.csv"
$completedIds = [System.Collections.Generic.HashSet[int]]::new()

if (Test-Path $outFile) {
    $existingRows = @(Import-Csv -Path $outFile)

    try {
        $outputStream = [System.IO.File]::Open($outFile, 'Open', 'Write', 'Read')
        $outputStream.Dispose()
    }
    catch [System.IO.IOException] {
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $resumeFile = Join-Path $PSScriptRoot "AdoWorkItemDiscussions.resume-$timestamp.csv"
        $existingRows | Export-Csv -Path $resumeFile -NoTypeInformation -Encoding UTF8
        Write-Warning "Output file is locked. Continuing in $resumeFile."
        $outFile = $resumeFile
    }

    foreach ($existingRow in $existingRows) {
        [void]$completedIds.Add([int]$existingRow.ID)
    }
    Write-Host "Resuming from $outFile with $($completedIds.Count) work items already exported."
}

Write-Host "Retrieving all Work Item IDs..."

# 1. Get all Work Item IDs in pages below the WIQL 20,000-result limit.
$workItemIds = [System.Collections.Generic.List[int]]::new()
$lastWorkItemId = 0
$wiqlPageSize = 19999

do {
    $wiql = @{
        query = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @Project AND [System.Id] > $lastWorkItemId ORDER BY [System.Id]"
    }

    $wiqlResult = Invoke-AdoRestMethod -Uri "$orgUrl/_apis/wit/wiql?api-version=7.1&`$top=$wiqlPageSize" `
        -Method Post -Headers $headers -ContentType 'application/json' -Body ($wiql | ConvertTo-Json)
    $pageIds = @($wiqlResult.workItems.id)

    foreach ($pageId in $pageIds) {
        $workItemIds.Add([int]$pageId)
    }

    if ($pageIds.Count -gt 0) {
        $lastWorkItemId = [int]$pageIds[-1]
    }
} while ($pageIds.Count -eq $wiqlPageSize)

Write-Host "Found $($workItemIds.Count) work items."

# 2. Loop through each Work Item
foreach ($id in $workItemIds) {

    if ($completedIds.Contains([int]$id)) {
        continue
    }

    Write-Host "Processing Work Item $id..."

    # Get Work Item fields
    $wi = Invoke-AdoRestMethod -Uri "$orgUrl/_apis/wit/workitems/${id}?api-version=7.1" `
        -Headers $headers -Method Get

    $title = $wi.fields.'System.Title'
    $description = $wi.fields.'System.Description'

    # Get Comments (Discussions)
    $comments = [System.Collections.Generic.List[object]]::new()
    $continuationToken = $null
    do {
        $commentsUri = "$orgUrl/_apis/wit/workItems/${id}/comments?api-version=7.1-preview.4&`$top=200"
        if ($continuationToken) {
            $commentsUri += "&continuationToken=$([Uri]::EscapeDataString($continuationToken))"
        }

        $commentsResult = Invoke-AdoRestMethod -Uri $commentsUri -Headers $headers -Method Get
        foreach ($comment in $commentsResult.comments) {
            $comments.Add($comment)
        }
        $continuationToken = $commentsResult.continuationToken
    } while ($continuationToken)

    $discussionText = ($comments | ForEach-Object {
        "[$($_.createdDate)] $($_.createdBy.displayName): $($_.text)"
    }) -join "`n"

    # Export each completed work item so interrupted runs can resume.
    $outputRow = [PSCustomObject]@{
        ID          = $id
        Title       = $title
        Description = $description
        Discussions = $discussionText
    }
    Export-AdoWorkItem -InputObject $outputRow -Path $outFile
    [void]$completedIds.Add([int]$id)
}

Write-Host "Done! Exported to $outFile"
Complete-AdoScriptRun -Outcome succeeded -Operation 'extract-discussions' -Target $outFile
