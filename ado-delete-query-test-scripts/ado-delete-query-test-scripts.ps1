<#
.SYNOPSIS
Deletes Test Case, Test Suite, and Test Plan artifacts returned by one Azure DevOps query.

.DESCRIPTION
Executes one saved Azure DevOps query, collects only IDs returned by that query, selects only
Test Case/Test Suite/Test Plan work items, resolves Test Management API IDs, writes a manifest,
and deletes only those reviewed manifest entries when -Apply is supplied. Apply requires a flat
query by default and an explicit manifest path; the current query resolution must match the reviewed
manifest. Tree and oneHop queries require -AllowRelationshipResults because their responses contain
source and target relationship endpoints. Title-based Test Plan/Test Suite resolution is disabled
unless -AllowTitleResolution is supplied. Test Plan/Test Suite work items without corresponding
Test Management artifacts are reported as unresolved and are never sent to Work Item Tracking.

Test Plan and Test Suite deletes can cascade to child test artifacts in Azure DevOps. The script
logs this and requires an exact confirmation phrase before Apply.
#>
param(
    [string]$QueryUrl = 'https://dev.azure.com/spriestley/TestBed/_queries/query/8d85e2d9-900c-485f-9b10-58430e66f827/',
    [SecureString]$Pat,
    [switch]$PromptForPat,
    [string[]]$DeleteWorkItemTypes = @('Test Case', 'Test Suite', 'Test Plan'),
    [string]$RequiredWorkItemType = '',
    [string]$ManifestPath,
    [string]$LogPath,
    [switch]$ForceOverwriteManifest,
    [switch]$AllowTitleResolution,
    [switch]$AllowRelationshipResults,
    [switch]$Apply,
    [string]$ConfirmationText,
    [switch]$SkipNotifications,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$commonModulePath = Join-Path $PSScriptRoot 'AdoUtils.Common.psm1'
if (-not (Test-Path -LiteralPath $commonModulePath)) {
    $commonModulePath = Join-Path $PSScriptRoot '..\AdoUtils.Common.psm1'
}
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive

function UrlEnc([string]$Value) { [uri]::EscapeDataString($Value) }

function ConvertFrom-SecureStringToPlainText([securestring]$SecureString) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Level -eq 'WARN') { Write-Warning $Message } elseif ($Level -eq 'ERROR') { Write-Host "ERROR: $Message" } else { Write-Host $Message }
    Add-Content -LiteralPath $script:ResolvedLogPath -Value $line -Encoding utf8
}

function Get-AuthHeader([SecureString]$PatValue, [bool]$ForcePrompt) {
    if ($ForcePrompt) {
        if ($null -ne $PatValue) { Write-Log '-PromptForPat forces the secure prompt and ignores the supplied parameter.' -Level WARN }
        Write-Log '-PromptForPat bypasses ADO_PAT and requests a fresh hidden credential.'
        $resolvedPat = Read-AdoInput -Prompt (Get-AdoPrompt -Name Pat) -AsSecureString
        if ($null -eq $resolvedPat -or [string]::IsNullOrWhiteSpace((ConvertFrom-AdoSecureString -SecureString $resolvedPat))) {
            throw 'A non-empty ADO_PAT credential is required.'
        }
        return New-AdoAuthorizationHeaders -Pat $resolvedPat
    }
    $resolvedPat = Resolve-AdoPat -Pat $PatValue -Role Default
    return New-AdoAuthorizationHeaders -Pat $resolvedPat
}

function ConvertFrom-AdoQueryUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -notmatch '^https?://') { throw 'QueryUrl must be an absolute Azure DevOps query URL.' }
    $uri = [uri]$Url
    if ($uri.Host -ne 'dev.azure.com') { throw 'QueryUrl must point to dev.azure.com.' }
    $segments = @($uri.AbsolutePath.Trim('/') -split '/')
    if ($segments.Count -lt 5 -or $segments[2] -ne '_queries' -or $segments[3] -ne 'query') { throw 'QueryUrl must look like https://dev.azure.com/{org}/{project}/_queries/query/{queryId}/' }
    if ($segments[4] -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { throw 'QueryUrl must contain a valid saved-query GUID.' }
    return [pscustomobject]@{ Org = [uri]::UnescapeDataString($segments[0]); Project = [uri]::UnescapeDataString($segments[1]); QueryId = [uri]::UnescapeDataString($segments[4]) }
}

function Get-ExceptionStatusCode {
    param([object]$ErrorRecord)
    if ($null -eq $ErrorRecord -or $null -eq $ErrorRecord.Exception) { return 'n/a' }
    if ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'Response' -and $null -ne $ErrorRecord.Exception.Response) {
        return [int]$ErrorRecord.Exception.Response.StatusCode
    }
    return 'n/a'
}

function Get-ExceptionDetail {
    param([object]$ErrorRecord)
    if ($null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) {
        return $ErrorRecord.ErrorDetails.Message
    }
    if ($null -ne $ErrorRecord.Exception) { return $ErrorRecord.Exception.Message }
    return [string]$ErrorRecord
}

function Invoke-Ado {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [object]$Body = $null,
        [string]$ContentType = 'application/json'
    )
    Write-Log "ADO $Method $Uri"
    $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers }
    if ($null -ne $Body) {
        $params.ContentType = $ContentType
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 100 }
    }
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try { return Invoke-RestMethod @params }
        catch {
            $status = Get-ExceptionStatusCode -ErrorRecord $_
            $detail = Get-ExceptionDetail -ErrorRecord $_
            $retryable = $status -eq 408 -or $status -eq 429 -or ($status -ge 500 -and $status -lt 600)
            if (-not $retryable -or $attempt -eq $maxAttempts) {
                if ($status -eq 401 -or $status -eq 403) { $detail = "$detail`nAzure DevOps rejected this request. Retry with -PromptForPat or confirm the PAT has Test Management Read & Write access." }
                throw "ADO $Method failed ($status): $Uri`n$detail"
            }
            $delaySeconds = [Math]::Min(30, [Math]::Pow(2, $attempt - 1))
            Write-Log "ADO $Method returned retryable status $status (attempt $attempt/$maxAttempts). Retrying in $delaySeconds second(s)." -Level WARN
            Start-Sleep -Seconds $delaySeconds
        }
    }
}

function Invoke-AdoPagedGet {
    param([string]$Uri, [hashtable]$Headers)
    $items = @()
    $continuationToken = $null
    do {
        $pageUri = $Uri
        if ($continuationToken) { $pageUri = "$Uri&continuationToken=$([uri]::EscapeDataString($continuationToken))" }
        Write-Log "ADO GET $pageUri"
        $maxAttempts = 4
        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try { $response = Invoke-WebRequest -UseBasicParsing -Method GET -Uri $pageUri -Headers $Headers; break }
            catch {
                $status = Get-ExceptionStatusCode -ErrorRecord $_
                $detail = Get-ExceptionDetail -ErrorRecord $_
                $retryable = $status -eq 408 -or $status -eq 429 -or ($status -ge 500 -and $status -lt 600)
                if (-not $retryable -or $attempt -eq $maxAttempts) { throw "ADO GET failed ($status): $pageUri`n$detail" }
                $delaySeconds = [Math]::Min(30, [Math]::Pow(2, $attempt - 1))
                Write-Log "ADO GET returned retryable status $status (attempt $attempt/$maxAttempts). Retrying in $delaySeconds second(s)." -Level WARN
                Start-Sleep -Seconds $delaySeconds
            }
        }
        $body = $response.Content | ConvertFrom-Json
        $items += @($body.value)
        $continuationToken = $response.Headers['x-ms-continuationtoken']
        if ($continuationToken -is [array]) { $continuationToken = $continuationToken[0] }
    } while (-not [string]::IsNullOrWhiteSpace([string]$continuationToken))
    return $items
}

function Get-QueryResultIds([object]$QueryResult) {
    $ids = New-Object System.Collections.Generic.List[int]
    $seen = New-Object System.Collections.Generic.HashSet[int]
    if ($null -eq $QueryResult) { return @() }
    if ($QueryResult.PSObject.Properties.Name -contains 'workItems') {
        foreach ($item in @($QueryResult.workItems)) {
            if ($null -ne $item -and $item.PSObject.Properties.Name -contains 'id') { $id = [int]$item.id; if ($seen.Add($id)) { $ids.Add($id) } }
        }
    }
    if ($QueryResult.PSObject.Properties.Name -contains 'workItemRelations') {
        foreach ($relation in @($QueryResult.workItemRelations)) {
            foreach ($endpoint in @('source', 'target')) {
                if ($null -eq $relation -or -not ($relation.PSObject.Properties.Name -contains $endpoint)) { continue }
                $ref = $relation.$endpoint
                if ($null -ne $ref -and $ref.PSObject.Properties.Name -contains 'id') { $id = [int]$ref.id; if ($seen.Add($id)) { $ids.Add($id) } }
            }
        }
    }
    return $ids.ToArray()
}

function Get-WorkItems {
    param([int[]]$Ids, [string]$Base, [string]$Project, [hashtable]$Headers)
    $items = @()
    if ($Ids.Count -eq 0) { return $items }
    for ($i = 0; $i -lt $Ids.Count; $i += 200) {
        $last = [Math]::Min($i + 199, $Ids.Count - 1)
        $chunk = @($Ids[$i..$last])
        $uri = "$Base/$(UrlEnc $Project)/_apis/wit/workitems?ids=$($chunk -join ',')&api-version=7.1"
        $result = Invoke-Ado -Method GET -Uri $uri -Headers $Headers
        $items += @($result.value)
    }
    return $items
}

function Get-FieldValue([object]$WorkItem, [string]$ReferenceName) {
    if ($null -eq $WorkItem.fields) { return $null }
    if ($WorkItem.fields.PSObject.Properties.Name -notcontains $ReferenceName) { return $null }
    return $WorkItem.fields.$ReferenceName
}

function Add-SuiteToList {
    param([object]$Suite, [int]$PlanId, [System.Collections.Generic.List[object]]$List)
    if ($null -eq $Suite -or -not ($Suite.PSObject.Properties.Name -contains 'id')) { return }
    $List.Add([pscustomobject]@{ Suite = $Suite; PlanId = $PlanId })
    foreach ($childName in @('children', 'Children')) {
        if ($Suite.PSObject.Properties.Name -contains $childName) {
            foreach ($child in @($Suite.$childName)) { Add-SuiteToList -Suite $child -PlanId $PlanId -List $List }
        }
    }
}

function Resolve-TestPlanArtifact {
    param([object]$WorkItem, [object[]]$Plans, [bool]$AllowTitleMatch)
    $wiId = [int]$WorkItem.WorkItemId
    $title = [string]$WorkItem.Title
    $matches = @($Plans | Where-Object { [int]$_.id -eq $wiId })
    if ($matches.Count -eq 1) { return [pscustomobject]@{ Plan = $matches[0]; Match = 'plan id equals work item id' } }
    $matches = @($Plans | Where-Object { $null -ne $_.rootSuite -and [int]$_.rootSuite.id -eq $wiId })
    if ($matches.Count -eq 1) { return [pscustomobject]@{ Plan = $matches[0]; Match = 'root suite id equals work item id' } }
    if (-not $AllowTitleMatch) { throw "Test Plan work item #$wiId '$title' did not match a Test Management plan by ID. Re-run with -AllowTitleResolution only after reviewing the candidate mappings." }
    $matches = @($Plans | Where-Object { [string]$_.name -eq $title })
    if ($matches.Count -eq 1) { return [pscustomobject]@{ Plan = $matches[0]; Match = 'unique plan name equals work item title' } }
    $matches = @($Plans | Where-Object { ([string]$_.name).Trim().ToLowerInvariant() -eq $title.Trim().ToLowerInvariant() })
    if ($matches.Count -eq 1) { return [pscustomobject]@{ Plan = $matches[0]; Match = 'normalized unique plan name equals work item title' } }
    if ($matches.Count -gt 1) { throw "Test Plan work item #$wiId '$title' matched multiple Test Management plans by title. Refusing to guess." }
    $sample = (@($Plans | Select-Object -First 20 | ForEach-Object { "#$($_.id) '$($_.name)'" }) -join '; ')
    throw "Could not resolve Test Management plan ID for Test Plan work item #$wiId '$title'. Loaded $($Plans.Count) plan(s). First plans: $sample"
}

function Resolve-TestSuiteArtifact {
    param([object]$WorkItem, [object[]]$Suites, [bool]$AllowTitleMatch)
    $wiId = [int]$WorkItem.WorkItemId
    $title = [string]$WorkItem.Title
    $matches = @($Suites | Where-Object { [int]$_.Suite.id -eq $wiId })
    if ($matches.Count -eq 1) { return [pscustomobject]@{ Suite = $matches[0].Suite; PlanId = [int]$matches[0].PlanId; Match = 'suite id equals work item id' } }
    if (-not $AllowTitleMatch) { throw "Test Suite work item #$wiId '$title' did not match a Test Management suite by ID. Re-run with -AllowTitleResolution only after reviewing the candidate mappings." }
    $matches = @($Suites | Where-Object { [string]$_.Suite.name -eq $title })
    if ($matches.Count -eq 1) { return [pscustomobject]@{ Suite = $matches[0].Suite; PlanId = [int]$matches[0].PlanId; Match = 'unique suite name equals work item title' } }
    $matches = @($Suites | Where-Object { ([string]$_.Suite.name).Trim().ToLowerInvariant() -eq $title.Trim().ToLowerInvariant() })
    if ($matches.Count -eq 1) { return [pscustomobject]@{ Suite = $matches[0].Suite; PlanId = [int]$matches[0].PlanId; Match = 'normalized unique suite name equals work item title' } }
    if ($matches.Count -gt 1) { throw "Test Suite work item #$wiId '$title' matched multiple Test Management suites by title. Refusing to guess." }
    $sample = (@($Suites | Select-Object -First 20 | ForEach-Object { "plan #$($_.PlanId) suite #$($_.Suite.id) '$($_.Suite.name)'" }) -join '; ')
    throw "Could not resolve Test Management suite ID for Test Suite work item #$wiId '$title'. Loaded $($Suites.Count) suite(s). First suites: $sample"
}

function Get-ManifestFingerprint([object[]]$Entries) {
    $columns = @('DeleteOrder', 'WorkItemId', 'ApiArtifactId', 'WorkItemType', 'PlanId', 'SuiteId', 'IdResolution', 'Title', 'State', 'AreaPath', 'IterationPath', 'DeleteUri')
    $normalizedEntries = @(
        foreach ($entry in @($Entries | Sort-Object WorkItemId, ApiArtifactId)) {
            $row = [ordered]@{}
            foreach ($column in $columns) {
                $value = $entry.$column
                $row[$column] = if ($null -eq $value) { '' } else { [string]$value }
            }
            [pscustomobject]$row
        }
    )
    $canonical = @($normalizedEntries | ConvertTo-Csv -NoTypeInformation) -join "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

$safeDate = Get-Date -Format 'yyyyMMdd-HHmmss'
$supportedWorkItemTypes = @('Test Case', 'Test Suite', 'Test Plan')
$manifestPathWasProvided = -not [string]::IsNullOrWhiteSpace($ManifestPath)
if ([string]::IsNullOrWhiteSpace($ManifestPath)) { $ManifestPath = Join-Path $PSScriptRoot "ado-delete-query-test-artifacts.$safeDate.csv" }
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $PSScriptRoot "ado-delete-query-test-artifacts.$safeDate.log" }
if (-not [string]::IsNullOrWhiteSpace($RequiredWorkItemType)) { $DeleteWorkItemTypes = @($RequiredWorkItemType) }
if (@($DeleteWorkItemTypes | Where-Object { $_ -notin $supportedWorkItemTypes }).Count -gt 0) { throw "DeleteWorkItemTypes contains unsupported value(s). Supported values: $($supportedWorkItemTypes -join ', ')." }
if ($Apply.IsPresent -and -not $manifestPathWasProvided) { throw '-Apply requires -ManifestPath pointing to a previously reviewed preview manifest.' }
$manifestFullPath = [IO.Path]::GetFullPath($ManifestPath)
$logFullPath = [IO.Path]::GetFullPath($LogPath)
if ($manifestFullPath -eq $logFullPath) { throw 'ManifestPath and LogPath must be different files.' }
$script:ResolvedLogPath = $LogPath
$logParent = Split-Path -Parent $script:ResolvedLogPath
if (-not [string]::IsNullOrWhiteSpace($logParent) -and -not (Test-Path -LiteralPath $logParent)) { New-Item -ItemType Directory -Path $logParent -Force | Out-Null }
Set-Content -LiteralPath $script:ResolvedLogPath -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [INFO] Starting ADO query test artifact cleanup." -Encoding utf8

try {
    $target = ConvertFrom-AdoQueryUrl -Url $QueryUrl
    $base = "https://dev.azure.com/$(UrlEnc $target.Org)"
    Write-Log "Mode: $(if ($Apply.IsPresent) { 'Apply' } else { 'Preview' })"
    Write-Log "Query: $($target.Org) / $($target.Project) / $($target.QueryId)"
    Write-Log "Delete work item types: $($DeleteWorkItemTypes -join ', ')"
    Write-Log "Manifest path: $ManifestPath"
    Write-Log "Log path: $script:ResolvedLogPath"

    $headers = Get-AuthHeader -PatValue $Pat -ForcePrompt $PromptForPat.IsPresent

    Write-Log 'Loading query metadata...'
    $queryUri = "$base/$(UrlEnc $target.Project)/_apis/wit/queries/$($target.QueryId)?`$expand=wiql&api-version=7.1-preview.2"
    $query = Invoke-Ado -Method GET -Uri $queryUri -Headers $headers
    if ($null -eq $query -or -not ($query.PSObject.Properties.Name -contains 'wiql') -or [string]::IsNullOrWhiteSpace($query.wiql)) { throw "Azure DevOps did not return WIQL for query '$($target.QueryId)'." }
    if (-not ($query.PSObject.Properties.Name -contains 'queryType') -or $query.queryType -notin @('flat', 'tree', 'oneHop')) { throw "Query '$($target.QueryId)' has unsupported query type '$($query.queryType)'." }
    if ($query.queryType -ne 'flat') {
        if (-not $AllowRelationshipResults.IsPresent) { throw "Query '$($target.QueryId)' has query type '$($query.queryType)'. Re-run with -AllowRelationshipResults after reviewing the tree/relationship scope, or use a flat query." }
        Write-Log "Relationship query enabled: both source and target IDs returned by the $($query.queryType) query will be candidates for validation and manifest generation." -Level WARN
    }

    Write-Log "Loaded query '$($query.name)' with path '$($query.path)' and type '$($query.queryType)'."
    Write-Log 'Executing query...'
    $wiqlUri = "$base/$(UrlEnc $target.Project)/_apis/wit/wiql?api-version=7.1"
    $queryResult = Invoke-Ado -Method POST -Uri $wiqlUri -Headers $headers -Body @{ query = $query.wiql }
    $ids = @(Get-QueryResultIds -QueryResult $queryResult)
    Write-Log "Query returned $($ids.Count) unique work item ID(s): $($ids -join ', ')"
    if ($ids.Count -eq 0) { Write-Log 'Query returned 0 work items. Nothing to delete.'; return }

    Write-Log "Loading $($ids.Count) query-returned work item(s) for validation..."
    $items = @(Get-WorkItems -Ids $ids -Base $base -Project $target.Project -Headers $headers)
    $returnedIds = @($items | ForEach-Object { [int]$_.id })
    $missingIds = @($ids | Where-Object { $returnedIds -notcontains $_ })
    if ($missingIds.Count -gt 0) { throw "Azure DevOps did not return details for these query IDs: $($missingIds -join ', '). Refusing to delete." }

    $allReturnedItems = @(
        foreach ($item in $items) {
            [pscustomobject]@{
                WorkItemId = [int]$item.id
                WorkItemType = [string](Get-FieldValue -WorkItem $item -ReferenceName 'System.WorkItemType')
                Title = [string](Get-FieldValue -WorkItem $item -ReferenceName 'System.Title')
                State = [string](Get-FieldValue -WorkItem $item -ReferenceName 'System.State')
                AreaPath = [string](Get-FieldValue -WorkItem $item -ReferenceName 'System.AreaPath')
                IterationPath = [string](Get-FieldValue -WorkItem $item -ReferenceName 'System.IterationPath')
            }
        }
    ) | Sort-Object WorkItemId

    $excluded = @($allReturnedItems | Where-Object { $_.WorkItemType -notin $DeleteWorkItemTypes })
    $targetItems = @($allReturnedItems | Where-Object { $_.WorkItemType -in $DeleteWorkItemTypes })
    if ($excluded.Count -gt 0) { Write-Log "Excluded $($excluded.Count) query result item(s) not in delete types: $((@($excluded | ForEach-Object { "#$($_.WorkItemId) '$($_.Title)' is '$($_.WorkItemType)'" })) -join '; ')" }
    if ($targetItems.Count -eq 0) { Write-Log 'Query returned no selected test artifact types. Nothing to delete.'; return }

    $needsPlanResolution = @($targetItems | Where-Object { $_.WorkItemType -in @('Test Plan', 'Test Suite') }).Count -gt 0
    $allPlans = @()
    $resolvedPlans = @{}
    $allSuites = @()
    $unresolved = New-Object System.Collections.Generic.List[object]
    if ($needsPlanResolution) {
        Write-Log 'Loading Test Management plan list to resolve work item IDs to plan IDs...'
        $planUri = "$base/$(UrlEnc $target.Project)/_apis/testplan/plans?includePlanDetails=True&api-version=7.1"
        $allPlans = @(Invoke-AdoPagedGet -Uri $planUri -Headers $headers)
        Write-Log "Loaded $($allPlans.Count) Test Management plan(s)."
        if ($allPlans.Count -eq 0) { Write-Log 'No Test Management plans were returned. Test Plan/Test Suite work items without resolvable Test Management IDs will remain unresolved. Verify Basic + Test Plans access and Manage test plans/suites permissions, and confirm these are real Test Management artifacts.' -Level WARN }
    }
    foreach ($planWorkItem in @($targetItems | Where-Object { $_.WorkItemType -eq 'Test Plan' })) {
        try {
            $resolved = Resolve-TestPlanArtifact -WorkItem $planWorkItem -Plans $allPlans -AllowTitleMatch $AllowTitleResolution.IsPresent
            $resolvedPlans[[int]$planWorkItem.WorkItemId] = $resolved
            Write-Log "Resolved Test Plan work item #$($planWorkItem.WorkItemId) '$($planWorkItem.Title)' to planId #$($resolved.Plan.id) by $($resolved.Match)."
        } catch {
            $unresolved.Add([pscustomobject]@{ WorkItemId = $planWorkItem.WorkItemId; WorkItemType = $planWorkItem.WorkItemType; Title = $planWorkItem.Title; Reason = $_.Exception.Message })
            Write-Log "Unresolved Test Plan work item #$($planWorkItem.WorkItemId): $($_.Exception.Message)" -Level WARN
        }
    }
    if (@($targetItems | Where-Object { $_.WorkItemType -eq 'Test Suite' }).Count -gt 0) {
        $suiteList = New-Object System.Collections.Generic.List[object]
        $suitePlans = if ($resolvedPlans.Count -gt 0) { @($resolvedPlans.Values | ForEach-Object { $_.Plan }) } else { $allPlans }
        foreach ($suitePlan in $suitePlans) {
            $planId = [int]$suitePlan.id
            Write-Log "Loading suites for resolved Test Plan #$planId..."
            $suiteUri = "$base/$(UrlEnc $target.Project)/_apis/testplan/Plans/$planId/suites?asTreeView=True&api-version=7.1"
            $suiteResult = Invoke-Ado -Method GET -Uri $suiteUri -Headers $headers
            foreach ($suite in @($suiteResult.value)) { Add-SuiteToList -Suite $suite -PlanId $planId -List $suiteList }
        }
        $allSuites = @($suiteList.ToArray())
        Write-Log "Loaded $($allSuites.Count) suite(s) from resolved plan(s)."
    }

    $manifest = @(
        foreach ($entry in $targetItems) {
            $order = 99; $apiId = $entry.WorkItemId; $planId = $null; $suiteId = $null; $resolution = 'work item id'; $deleteUri = $null
            if ($entry.WorkItemType -eq 'Test Case') {
                $order = 10; $deleteUri = "$base/$(UrlEnc $target.Project)/_apis/test/testcases/$($entry.WorkItemId)?api-version=7.1"
            } elseif ($entry.WorkItemType -eq 'Test Suite') {
                try {
                    $resolvedSuite = Resolve-TestSuiteArtifact -WorkItem $entry -Suites $allSuites -AllowTitleMatch $AllowTitleResolution.IsPresent
                    $order = 20; $planId = [int]$resolvedSuite.PlanId; $suiteId = [int]$resolvedSuite.Suite.id; $apiId = $suiteId; $resolution = $resolvedSuite.Match
                    $deleteUri = "$base/$(UrlEnc $target.Project)/_apis/testplan/Plans/$planId/suites/${suiteId}?api-version=7.1"
                } catch {
                    $unresolved.Add([pscustomobject]@{ WorkItemId = $entry.WorkItemId; WorkItemType = $entry.WorkItemType; Title = $entry.Title; Reason = $_.Exception.Message })
                    Write-Log "Unresolved Test Suite work item #$($entry.WorkItemId): $($_.Exception.Message)" -Level WARN
                    continue
                }
            } elseif ($entry.WorkItemType -eq 'Test Plan') {
                if ($resolvedPlans.ContainsKey([int]$entry.WorkItemId)) {
                    $resolvedPlan = $resolvedPlans[[int]$entry.WorkItemId]
                    $order = 30; $planId = [int]$resolvedPlan.Plan.id; $apiId = $planId; $resolution = $resolvedPlan.Match
                    $deleteUri = "$base/$(UrlEnc $target.Project)/_apis/testplan/plans/${planId}?api-version=7.1"
                } else { continue }
            }
            [pscustomobject]@{ DeleteOrder = $order; WorkItemId = $entry.WorkItemId; ApiArtifactId = $apiId; WorkItemType = $entry.WorkItemType; PlanId = $planId; SuiteId = $suiteId; IdResolution = $resolution; Title = $entry.Title; State = $entry.State; AreaPath = $entry.AreaPath; IterationPath = $entry.IterationPath; DeleteUri = $deleteUri }
        }
    ) | Sort-Object DeleteOrder, WorkItemId
    $manifest = @($manifest | Where-Object { $null -ne $_ })

    if ($unresolved.Count -gt 0) {
        $unresolvedPath = [IO.Path]::ChangeExtension($ManifestPath, '.unresolved.csv')
        $unresolved | Export-Csv -LiteralPath $unresolvedPath -NoTypeInformation -Encoding utf8
        Write-Log "Unresolved query-returned artifact(s) written to: $unresolvedPath" -Level WARN
    }
    if ($manifest.Count -eq 0) {
        Write-Log 'No resolvable selected test artifacts remain in the delete manifest. Nothing to delete.'
        return
    }

    $duplicateGroups = @($manifest | Group-Object { "$($_.WorkItemType)|$($_.ApiArtifactId)|$($_.PlanId)|$($_.SuiteId)" } | Where-Object { $_.Count -gt 1 })
    if ($duplicateGroups.Count -gt 0) {
        Write-Log "Found $($duplicateGroups.Count) duplicate API artifact mapping(s); retaining one manifest entry per artifact." -Level WARN
        $manifest = @($manifest | Group-Object { "$($_.WorkItemType)|$($_.ApiArtifactId)|$($_.PlanId)|$($_.SuiteId)" } | ForEach-Object { $_.Group | Select-Object -First 1 }) | Sort-Object DeleteOrder, WorkItemId
    }

    $parent = Split-Path -Parent $ManifestPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (-not $Apply.IsPresent) {
        if ((Test-Path -LiteralPath $ManifestPath) -and -not $ForceOverwriteManifest.IsPresent) { throw "Manifest already exists: $ManifestPath. Use a new path or -ForceOverwriteManifest." }
        $manifest | Export-Csv -LiteralPath $ManifestPath -NoTypeInformation -Encoding utf8
    } else {
        if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Reviewed manifest was not found: $ManifestPath. Run a preview first." }
        $reviewedManifest = @(Import-Csv -LiteralPath $ManifestPath)
        $requiredManifestColumns = @('DeleteOrder', 'WorkItemId', 'ApiArtifactId', 'WorkItemType', 'PlanId', 'SuiteId', 'IdResolution', 'Title', 'State', 'AreaPath', 'IterationPath', 'DeleteUri')
        $actualManifestColumns = @($reviewedManifest | Select-Object -First 1 | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
        $missingManifestColumns = @($requiredManifestColumns | Where-Object { $_ -notin $actualManifestColumns })
        if ($missingManifestColumns.Count -gt 0) { throw "Manifest is missing required column(s): $($missingManifestColumns -join ', '). Generate a new preview manifest." }
        $reviewedFingerprint = Get-ManifestFingerprint -Entries $reviewedManifest
        $currentFingerprint = Get-ManifestFingerprint -Entries $manifest
        if ($reviewedFingerprint -ne $currentFingerprint) { throw "Reviewed manifest does not match the current query resolution. No artifacts were deleted. Generate and review a new preview manifest." }
        $manifest = $reviewedManifest
        Write-Log "Validated reviewed manifest fingerprint: $reviewedFingerprint"
    }
    Write-Log "Validated $($manifest.Count) query-returned test artifact(s) to delete."
    Write-Log "Manifest $(if ($Apply.IsPresent) { 'validated and used' } else { 'written' }): $ManifestPath"
    $manifest | Format-Table -AutoSize

    $cascading = @($manifest | Where-Object { $_.WorkItemType -in @('Test Plan', 'Test Suite') })
    if ($cascading.Count -gt 0) { Write-Log "Cascade warning: $($cascading.Count) Test Plan/Test Suite artifact(s) are in the manifest. Azure DevOps may delete child test artifacts under those containers." -Level WARN }
    if (-not $Apply.IsPresent) { Write-Log 'Preview only. Review the manifest before re-running with -Apply and the same -ManifestPath.'; return }

    $manifestFingerprint = Get-ManifestFingerprint -Entries $manifest
    $expectedConfirmation = "DELETE $($manifest.Count) QUERY TEST ARTIFACTS FROM QUERY $($target.QueryId) HASH $manifestFingerprint"
    if ([string]::IsNullOrWhiteSpace($ConfirmationText)) {
        Write-Host ''
        Write-Log 'This will delete the listed query-returned test artifacts through Azure DevOps Test Management APIs.'
        if ($cascading.Count -gt 0) { Write-Log 'Test Plan/Test Suite deletion may cascade to child test artifacts.' -Level WARN }
        Write-Log "Type this exact phrase to continue: $expectedConfirmation"
        $ConfirmationText = Read-AdoInput -Prompt 'Confirmation'
    }
    if ($ConfirmationText -ne $expectedConfirmation) { throw 'Confirmation phrase did not match. No artifacts were deleted.' }

    $results = New-Object System.Collections.Generic.List[object]
    $failures = New-Object System.Collections.Generic.List[object]
    $resultPath = [IO.Path]::ChangeExtension($ManifestPath, '.delete-results.csv')
    $priorResults = @()
    if (Test-Path -LiteralPath $resultPath) {
        $priorResults = @(Import-Csv -LiteralPath $resultPath | Where-Object { $_.Deleted -eq 'True' })
        if ($priorResults.Count -gt 0) { Write-Log "Found $($priorResults.Count) previously successful deletion(s); they will be skipped for resume." }
    }
    $priorKeys = @{}
    foreach ($prior in $priorResults) { $priorKeys["$($prior.WorkItemType)|$($prior.ApiArtifactId)"] = $true }
    foreach ($entry in $manifest) {
        $entryKey = "$($entry.WorkItemType)|$($entry.ApiArtifactId)"
        if ($priorKeys.ContainsKey($entryKey)) { continue }
        $deleteUri = [string]$entry.DeleteUri
        if ($SkipNotifications.IsPresent) { $deleteUri = "$deleteUri&skipNotifications=true" }
        try {
            Write-Log "Deleting $($entry.WorkItemType) workItem #$($entry.WorkItemId), API artifact #$($entry.ApiArtifactId): $($entry.Title)"
            Invoke-Ado -Method DELETE -Uri $deleteUri -Headers $headers | Out-Null
            $results.Add([pscustomobject]@{ WorkItemId = $entry.WorkItemId; ApiArtifactId = $entry.ApiArtifactId; WorkItemType = $entry.WorkItemType; Title = $entry.Title; Deleted = $true; Error = $null })
            Write-Log "Deleted $($entry.WorkItemType) workItem #$($entry.WorkItemId): $($entry.Title)"
        } catch {
            $failures.Add([pscustomobject]@{ WorkItemId = $entry.WorkItemId; ApiArtifactId = $entry.ApiArtifactId; WorkItemType = $entry.WorkItemType; Title = $entry.Title; Deleted = $false; Error = $_.Exception.Message })
            Write-Log "Failed to delete $($entry.WorkItemType) workItem #$($entry.WorkItemId): $($_.Exception.Message)" -Level WARN
        }
    }
    @($priorResults + $results + $failures) | Export-Csv -LiteralPath $resultPath -NoTypeInformation -Encoding utf8
    Write-Log "Delete results written to: $resultPath"
    if ($failures.Count -gt 0) { throw "$($failures.Count) artifact delete operation(s) failed. See $resultPath." }
    Write-Log "Deleted $($results.Count) query-returned test artifact(s), all from query $($target.QueryId)."
} catch {
    Write-Log $_.Exception.Message -Level ERROR
    Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'delete-query-test-artifacts'
    throw
} finally {
    Write-Log 'Finished ADO query test artifact cleanup.'
}
Complete-AdoScriptRun -Outcome $(if ($Apply) { 'succeeded' } else { 'preview' }) -Operation 'delete-query-test-artifacts'


