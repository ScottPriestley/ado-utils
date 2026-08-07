[CmdletBinding()]
param(
    [string]$ProjectUrl,
    [string]$QueryUrl,
    [SecureString]$Pat,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$commonModulePath = Join-Path $PSScriptRoot 'AdoUtils.Common.psm1'
if (-not (Test-Path -LiteralPath $commonModulePath)) {
    $commonModulePath = Join-Path $PSScriptRoot '..\AdoUtils.Common.psm1'
}
Import-Module $commonModulePath -Force
$null = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'extract-discussions'; throw $_ }

function UrlEnc {
    param([Parameter(Mandatory)][string]$Value)
    [uri]::EscapeDataString($Value)
}

function ConvertFrom-AdoQueryUrl {
    param([Parameter(Mandatory)][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -notmatch '^https?://') { throw 'QueryUrl must be an absolute Azure DevOps query URL.' }
    $uri = [uri]$Url
    if ($uri.Host -ne 'dev.azure.com') { throw 'QueryUrl must point to dev.azure.com.' }
    $segments = @($uri.AbsolutePath.Trim('/') -split '/' | Where-Object { $_ })
    if ($segments.Count -lt 5 -or $segments[2] -ne '_queries' -or $segments[3] -ne 'query') { throw 'QueryUrl must look like https://dev.azure.com/{org}/{project}/_queries/query/{queryId}/' }
    if ($segments[4] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw 'QueryUrl must contain a valid saved-query GUID.' }
    [pscustomobject]@{
        Org     = [uri]::UnescapeDataString($segments[0])
        Project = [uri]::UnescapeDataString($segments[1])
        QueryId = [uri]::UnescapeDataString($segments[4])
    }
}

function Get-AdoPropertyValue {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $property.Value
}

function Get-AdoFieldValue {
    param([AllowNull()][object]$Fields, [Parameter(Mandatory)][string]$ReferenceName)
    Get-AdoPropertyValue -InputObject $Fields -Name $ReferenceName
}

function Get-AdoExceptionStatusCode {
    param([AllowNull()][object]$ErrorRecord)
    if ($null -eq $ErrorRecord -or $null -eq $ErrorRecord.Exception) { return 0 }

    $response = Get-AdoPropertyValue -InputObject $ErrorRecord.Exception -Name 'Response'
    if ($null -ne $response) {
        $responseStatusCode = Get-AdoPropertyValue -InputObject $response -Name 'StatusCode'
        if ($null -ne $responseStatusCode) { return [int]$responseStatusCode }
    }

    $exceptionStatusCode = Get-AdoPropertyValue -InputObject $ErrorRecord.Exception -Name 'StatusCode'
    if ($null -ne $exceptionStatusCode) { return [int]$exceptionStatusCode }

    0
}

function Get-IdentityDisplayName {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $displayName = Get-AdoPropertyValue -InputObject $Value -Name 'displayName'
    if (-not [string]::IsNullOrWhiteSpace([string]$displayName)) { return [string]$displayName }
    [string]$Value
}

function ConvertTo-AdoCsvValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $displayName = Get-AdoPropertyValue -InputObject $Value -Name 'displayName'
    if (-not [string]::IsNullOrWhiteSpace([string]$displayName)) { return [string]$displayName }
    if ($Value -is [datetime]) { return $Value.ToString('o') }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) { return (($Value | ForEach-Object { ConvertTo-AdoCsvValue -Value $_ }) -join '; ') }
    [string]$Value
}

function Get-UniqueCsvColumnName {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]]$UsedNames
    )
    $baseName = if ([string]::IsNullOrWhiteSpace($Name)) { 'Field' } else { $Name }
    $candidate = $baseName
    $suffix = 2
    while (-not $UsedNames.Add($candidate)) {
        $candidate = '{0} {1}' -f $baseName, $suffix
        $suffix++
    }
    $candidate
}

function Get-QueryFieldColumns {
    param([Parameter(Mandatory)][psobject]$WiqlResult)
    $columns = [Collections.Generic.List[object]]::new()
    $seenFields = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $usedNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$usedNames.Add('QueryId')
    [void]$usedNames.Add('QueryName')
    [void]$usedNames.Add('Discussions')

    foreach ($column in @(Get-AdoPropertyValue -InputObject $WiqlResult -Name 'columns')) {
        $referenceName = [string](Get-AdoPropertyValue -InputObject $column -Name 'referenceName')
        if ([string]::IsNullOrWhiteSpace($referenceName) -or -not $seenFields.Add($referenceName)) { continue }
        $displayName = [string](Get-AdoPropertyValue -InputObject $column -Name 'name')
        $csvName = Get-UniqueCsvColumnName -Name $(if ([string]::IsNullOrWhiteSpace($displayName)) { $referenceName } else { $displayName }) -UsedNames $usedNames
        $columns.Add([pscustomobject]@{ ReferenceName = $referenceName; CsvName = $csvName })
    }

    if (-not $seenFields.Contains('System.Id')) {
        $csvName = Get-UniqueCsvColumnName -Name 'ID' -UsedNames $usedNames
        $columns.Insert(0, [pscustomobject]@{ ReferenceName = 'System.Id'; CsvName = $csvName })
    }

    $columns
}

function Resolve-DiscussionExportPat {
    param([SecureString]$PatValue)
    if ($null -eq $PatValue) {
        $PatValue = Read-AdoInput -Prompt (Get-AdoPrompt -Name Pat) -AsSecureString
    }
    if ($null -eq $PatValue -or [string]::IsNullOrWhiteSpace((ConvertFrom-AdoSecureString -SecureString $PatValue))) {
        throw 'A non-empty PAT is required.'
    }
    $PatValue
}

function Get-WorkItemIdsFromWiqlResult {
    param([Parameter(Mandatory)][psobject]$WiqlResult)
    $ids = [Collections.Generic.List[int]]::new()
    $seen = [Collections.Generic.HashSet[int]]::new()

    foreach ($workItem in @(Get-AdoPropertyValue -InputObject $WiqlResult -Name 'workItems')) {
        $workItemId = Get-AdoPropertyValue -InputObject $workItem -Name 'id'
        if ($null -ne $workItemId -and $seen.Add([int]$workItemId)) { $ids.Add([int]$workItemId) }
    }

    foreach ($relation in @(Get-AdoPropertyValue -InputObject $WiqlResult -Name 'workItemRelations')) {
        $endpoints = @(
            (Get-AdoPropertyValue -InputObject $relation -Name 'source'),
            (Get-AdoPropertyValue -InputObject $relation -Name 'target')
        )
        foreach ($endpoint in $endpoints) {
            $endpointId = Get-AdoPropertyValue -InputObject $endpoint -Name 'id'
            if ($null -ne $endpointId -and $seen.Add([int]$endpointId)) { $ids.Add([int]$endpointId) }
        }
    }

    $ids
}

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
            $statusCode = Get-AdoExceptionStatusCode -ErrorRecord $_
            $isTransient = $statusCode -eq 0 -or $statusCode -in 408, 429, 500, 502, 503, 504

            if (-not $isTransient -or $attempt -eq $MaxAttempts) {
                if ($statusCode -eq 401) {
                    throw "Azure DevOps returned 401 Unauthorized for $Method $Uri. Re-enter a valid PAT for this organization with Work Items Read scope."
                }
                if ($statusCode -eq 403) {
                    throw "Azure DevOps returned 403 Forbidden for $Method $Uri. The PAT identity can authenticate but does not have permission to read this project, query, work items, or comments."
                }
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
    $ProjectUrl = Read-AdoInput -Prompt 'Project URL'
}
if ([string]::IsNullOrWhiteSpace($QueryUrl)) {
    $QueryUrl = Read-AdoInput -Prompt 'Query URL'
}

$projectContext = ConvertFrom-AdoProjectUrl -Url $ProjectUrl -Role Default
$queryContext = ConvertFrom-AdoQueryUrl -Url $QueryUrl
if ($projectContext.Org -ne $queryContext.Org -or $projectContext.Project -ne $queryContext.Project) {
    throw "ProjectUrl must identify the same organization and project as QueryUrl. ProjectUrl resolved to '$($projectContext.Org)/$($projectContext.Project)' but QueryUrl resolved to '$($queryContext.Org)/$($queryContext.Project)'."
}

$projectApiBase = 'https://dev.azure.com/{0}/{1}' -f (UrlEnc $projectContext.Org), (UrlEnc $projectContext.Project)
$resolvedPat = Resolve-DiscussionExportPat -PatValue $Pat
$patPlain = ConvertFrom-AdoSecureString -SecureString $resolvedPat

# Encode PAT for Authorization header
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$patPlain"))
$patPlain = $null
$headers = @{ Authorization = "Basic $auth" }

Write-Host "Reading saved query '$($queryContext.QueryId)' from '$ProjectUrl'..."
$query = Invoke-AdoRestMethod -Uri "$projectApiBase/_apis/wit/queries/$($queryContext.QueryId)?`$expand=wiql&api-version=7.1" -Headers $headers -Method Get
$queryName = [string](Get-AdoPropertyValue -InputObject $query -Name 'name')
$queryWiql = [string](Get-AdoPropertyValue -InputObject $query -Name 'wiql')
if ([string]::IsNullOrWhiteSpace($queryWiql)) { throw "Saved query '$($queryContext.QueryId)' does not contain WIQL." }

# Output CSV. Each run creates a fresh file so old query schemas cannot collide with new query columns.
$runTimestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outFile = Join-Path $PSScriptRoot ("AdoWorkItemDiscussions-{0}-{1}.csv" -f $queryContext.QueryId, $runTimestamp)

Write-Host "Executing saved query '$queryName'..."

# 1. Execute the saved query WIQL and collect the work item IDs it returns.
$wiqlResult = Invoke-AdoRestMethod -Uri "$projectApiBase/_apis/wit/wiql?api-version=7.1" `
    -Method Post -Headers $headers -ContentType 'application/json' -Body (@{ query = $queryWiql } | ConvertTo-Json)
$workItemIds = Get-WorkItemIdsFromWiqlResult -WiqlResult $wiqlResult
$queryFieldColumns = Get-QueryFieldColumns -WiqlResult $wiqlResult
$queryFieldReferences = @($queryFieldColumns | ForEach-Object { $_.ReferenceName })
$workItemFieldsQuery = if ($queryFieldReferences.Count -gt 0) { '&fields={0}' -f (($queryFieldReferences | ForEach-Object { UrlEnc $_ }) -join ',') } else { '' }

Write-Host "Found $($workItemIds.Count) work items."

# 2. Loop through each Work Item
foreach ($id in $workItemIds) {
    Write-Host "Processing Work Item $id..."

    # Get Work Item fields
    $wi = Invoke-AdoRestMethod -Uri "$projectApiBase/_apis/wit/workitems/${id}?api-version=7.1$workItemFieldsQuery" `
        -Headers $headers -Method Get

    $fields = Get-AdoPropertyValue -InputObject $wi -Name 'fields'

    # Get Comments (Discussions)
    $comments = [System.Collections.Generic.List[object]]::new()
    $continuationToken = $null
    do {
        $commentsUri = "$projectApiBase/_apis/wit/workItems/${id}/comments?api-version=7.1-preview.4&`$top=200"
        if ($continuationToken) {
            $commentsUri += "&continuationToken=$([Uri]::EscapeDataString($continuationToken))"
        }

        $commentsResult = Invoke-AdoRestMethod -Uri $commentsUri -Headers $headers -Method Get
        foreach ($comment in @(Get-AdoPropertyValue -InputObject $commentsResult -Name 'comments')) {
            $comments.Add($comment)
        }
        $continuationToken = Get-AdoPropertyValue -InputObject $commentsResult -Name 'continuationToken'
    } while ($continuationToken)

    $discussionText = ($comments | ForEach-Object {
        $createdBy = Get-IdentityDisplayName -Value (Get-AdoPropertyValue -InputObject $_ -Name 'createdBy')
        "[$(Get-AdoPropertyValue -InputObject $_ -Name 'createdDate')] $createdBy`: $(Get-AdoPropertyValue -InputObject $_ -Name 'text')"
    }) -join "`n"

    # Export each completed work item immediately so interrupted runs still retain completed rows.
    $output = [ordered]@{
        QueryId   = $queryContext.QueryId
        QueryName = $queryName
    }
    foreach ($column in $queryFieldColumns) {
        $fieldValue = if ($column.ReferenceName -eq 'System.Id') { $id } else { Get-AdoFieldValue -Fields $fields -ReferenceName $column.ReferenceName }
        $output[$column.CsvName] = ConvertTo-AdoCsvValue -Value $fieldValue
    }
    $output.Discussions = $discussionText
    $outputRow = [PSCustomObject]$output
    Export-AdoWorkItem -InputObject $outputRow -Path $outFile
}

Write-Host "Done! Exported to $outFile"
Complete-AdoScriptRun -Outcome succeeded -Operation 'extract-discussions' -Target $outFile
