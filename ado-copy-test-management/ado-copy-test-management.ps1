<#
.SYNOPSIS
Copies Azure DevOps Test Plans, Test Suites, and Test Cases between projects.

.DESCRIPTION
Reads Test Management plans and suite trees from a source Azure DevOps project,
creates equivalent target plans and suites, creates target Test Case work items,
copies configured Work Item Tracking fields without converting rich-text values,
and adds each mapped Test Case to the mapped target suite.

HTML fidelity depends on copying the stored WIT field values exactly. By default
the script includes System.Description and Microsoft.VSTS.TCM.Steps, which are
the common rich-text fields that make a Test Case look different when formatting
is lost. Add custom rich-text fields through -AdditionalFieldReferenceNames.

The script is additive and resumable through -StatePath. It does not delete,
overwrite unrelated target artifacts, migrate history, attachments, identities,
test runs/results, shared steps as reusable shared-step artifacts, or source
configuration IDs.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$SourceProjectUrl,
    [string]$TargetProjectUrl,
    [string]$SourceOrg,
    [string]$SourceProject,
    [string]$TargetOrg,
    [string]$TargetProject,
    [int[]]$SourcePlanIds,
    [SecureString]$SourcePat,
    [SecureString]$TargetPat,
    [string]$StatePath,
    [string]$LogPath,
    [string[]]$AdditionalFieldReferenceNames = @(),
    [switch]$PreserveClassificationPaths,
    [switch]$SkipNotifications,
    [switch]$DoNotConvertDynamicSuitesToStatic,
    [switch]$CopyStandaloneTestCasesWhenSuitesUnavailable,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty in parameter defaults for a [CmdletBinding()] script
# started with powershell.exe -File, so this default is resolved here instead.if ([string]::IsNullOrWhiteSpace($StatePath)) { $StatePath = Join-Path $PSScriptRoot 'ado-copy-test-management.state.json' }

$commonModulePath = Join-Path $PSScriptRoot 'AdoUtils.Common.psm1'
if (-not (Test-Path -LiteralPath $commonModulePath)) {
    $commonModulePath = Join-Path $PSScriptRoot '..\AdoUtils.Common.psm1'
}
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive

function UrlEnc([string]$Value) { [uri]::EscapeDataString($Value) }

function Write-Log {
    param([Parameter(Mandatory)][string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($Level -eq 'WARN') { Write-Warning $Message } elseif ($Level -eq 'ERROR') { Write-Host "ERROR: $Message" } else { Write-Host $Message }
    if (-not [string]::IsNullOrWhiteSpace($script:ResolvedLogPath)) {
        Add-Content -LiteralPath $script:ResolvedLogPath -Value $line -Encoding utf8 -WhatIf:$false
    }
}

trap {
    $message = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
    Write-Log -Level 'ERROR' -Message $message
    Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'copy-test-management'
    throw
}

function Get-AdoHeaders {
    param([SecureString]$Pat, [Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Role)
    $resolvedPat = Resolve-AdoPat -Pat $Pat -Role $Role
    return New-AdoAuthorizationHeaders -Pat $resolvedPat
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
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [object]$Body = $null,
        [string]$ContentType = 'application/json',
        [switch]$AllowNotFound
    )
    Write-Log "ADO $Method $Uri"
    $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers }
    if ($null -ne $Body) {
        $params.ContentType = $ContentType
        $params.Body = if ($Body -is [string]) {
            $Body
        } elseif ($ContentType -eq 'application/json-patch+json') {
            ConvertTo-Json -InputObject @($Body) -Depth 100
        } else {
            ConvertTo-Json -InputObject $Body -Depth 100
        }
    }
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try { return Invoke-RestMethod @params }
        catch {
            $status = Get-ExceptionStatusCode -ErrorRecord $_
            if ($AllowNotFound -and $status -eq 404) { return $null }
            $detail = Get-ExceptionDetail -ErrorRecord $_
            $retryable = $status -eq 408 -or $status -eq 429 -or ($status -ge 500 -and $status -lt 600)
            if (-not $retryable -or $attempt -eq $maxAttempts) {
                if ($status -eq 401 -or $status -eq 403) {
                    $detail = "$detail`nAzure DevOps rejected this request. Source requires Test Management Read and Work Items Read. Target requires Test Management Read & Write and Work Items Read & Write."
                }
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

function New-MigrationState {
    [pscustomobject]@{
        plans = @{}
        suites = @{}
        cases = @{}
        suiteCases = @{}
    }
}

function Read-MigrationState {
    param([string]$Path)
    $state = New-MigrationState
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $state }
    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $state }
    $json = $raw | ConvertFrom-Json
    foreach ($bucket in @('plans','suites','cases','suiteCases')) {
        if ($json.PSObject.Properties.Name -contains $bucket) {
            foreach ($prop in $json.$bucket.PSObject.Properties) {
                $state.$bucket[$prop.Name] = $prop.Value
            }
        }
    }
    return $state
}

function Write-MigrationState {
    param([object]$State, [string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $WhatIfPreference) { return }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporaryPath = "$Path.tmp"
    $State | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-FieldValue {
    param([object]$WorkItem, [string]$ReferenceName)
    if ($null -eq $WorkItem.fields) { return $null }
    if ($WorkItem.fields.PSObject.Properties.Name -notcontains $ReferenceName) { return $null }
    return $WorkItem.fields.$ReferenceName
}

function Test-HasProperty {
    param([object]$Value, [string]$Name)
    return $null -ne $Value -and $Value.PSObject.Properties.Name -contains $Name
}

function Get-ObjectPropertyValue {
    param([object]$Value, [string]$Name)
    if (-not (Test-HasProperty -Value $Value -Name $Name)) { return $null }
    return $Value.PSObject.Properties[$Name].Value
}

function Add-JsonPatchField {
    param([Collections.Generic.List[object]]$Patch, [string]$Field, [AllowNull()][object]$Value)
    if ($null -eq $Value) { return }
    $escapedField = $Field.Replace('~', '~0').Replace('/', '~1')
    $Patch.Add([ordered]@{ op = 'add'; path = "/fields/$escapedField"; value = $Value })
}

function Convert-ClassificationPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    if ($PreserveClassificationPaths) { return $Path }
    $escapedSource = [regex]::Escape($script:SourceProjectName)
    if ($Path -match "^$escapedSource(?:\\|$)") {
        return ($Path -replace "^$escapedSource", $script:TargetProjectName)
    }
    return $Path
}

function ConvertTo-ComparableProjectName {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    $normalized = ([string]$Value).Trim().ToLowerInvariant()
    $normalized = $normalized -replace '\s+project$', ''
    return ($normalized -replace '[^a-z0-9]', '')
}

function Get-OrganizationProjects {
    param([string]$BaseUrl, [hashtable]$Headers)
    $projects = [Collections.Generic.List[object]]::new()
    $continuationToken = $null
    do {
        $uri = "$BaseUrl/_apis/projects?`$top=100&api-version=7.1"
        if (-not [string]::IsNullOrWhiteSpace([string]$continuationToken)) {
            $uri += "&continuationToken=$([uri]::EscapeDataString([string]$continuationToken))"
        }
        $response = Invoke-Ado -Method GET -Uri $uri -Headers $Headers
        foreach ($project in @($response.value)) { $projects.Add($project) }
        $continuationToken = if (Test-HasProperty $response 'continuationToken') { $response.continuationToken } else { $null }
    } while (-not [string]::IsNullOrWhiteSpace([string]$continuationToken))
    return $projects.ToArray()
}

function Get-ProjectReference {
    param([string]$BaseUrl, [string]$Project, [hashtable]$Headers)
    $uri = "$BaseUrl/_apis/projects/$(UrlEnc $Project)?api-version=7.1"
    return Invoke-Ado -Method GET -Uri $uri -Headers $Headers -AllowNotFound
}

function Resolve-ExistingProjectReference {
    param(
        [string]$BaseUrl,
        [string]$Project,
        [hashtable]$Headers,
        [Parameter(Mandatory)][ValidateSet('Source','Target')][string]$Role,
        [switch]$AllowUnresolved
    )
    $direct = Get-ProjectReference -BaseUrl $BaseUrl -Project $Project -Headers $Headers
    if ($null -ne $direct) {
        return [pscustomobject]@{ Name = [string]$direct.name; Id = [string]$direct.id; Resolved = $true; CandidateText = '' }
    }

    $projects = @(Get-OrganizationProjects -BaseUrl $BaseUrl -Headers $Headers)
    if ($projects.Count -eq 0) {
        if ($AllowUnresolved) {
            Write-Log "$Role project '$Project' was not visible in the Core project list. Continuing with the project name from the URL." -Level WARN
            return [pscustomobject]@{ Name = $Project; Id = $Project; Resolved = $false; CandidateText = '' }
        }
        return [pscustomobject]@{ Name = $Project; Id = $Project; Resolved = $false; CandidateText = '' }
    }
    $exact = @($projects | Where-Object { [string]$_.name -ieq $Project })
    if ($exact.Count -eq 1) { return [pscustomobject]@{ Name = [string]$exact[0].name; Id = [string]$exact[0].id; Resolved = $true; CandidateText = '' } }

    $requestedComparable = ConvertTo-ComparableProjectName $Project
    $normalized = @($projects | Where-Object { (ConvertTo-ComparableProjectName ([string]$_.name)) -eq $requestedComparable })
    if ($normalized.Count -eq 1) {
        Write-Log "$Role project '$Project' resolved to accessible project '$($normalized[0].name)'." -Level WARN
        return [pscustomobject]@{ Name = [string]$normalized[0].name; Id = [string]$normalized[0].id; Resolved = $true; CandidateText = '' }
    }

    $tokens = @($Project -split '[\s\-_]+' | Where-Object { $_.Length -ge 3 })
    $candidates = @($projects | Where-Object {
        $name = [string]$_.name
        @($tokens | Where-Object { $name -like "*$_*" }).Count -gt 0
    } | Select-Object -First 20)
    $candidateText = if ($candidates.Count -gt 0) {
        ($candidates | ForEach-Object { "'$($_.name)'" }) -join ', '
    } else {
        (@($projects | Select-Object -First 20 | ForEach-Object { "'$($_.name)'" }) -join ', ')
    }
    if ($AllowUnresolved) {
        Write-Log "$Role project '$Project' was not found in $BaseUrl Core project metadata. Continuing with the project name from the URL. Accessible project candidates: $candidateText" -Level WARN
        return [pscustomobject]@{ Name = $Project; Id = $Project; Resolved = $false; CandidateText = $candidateText }
    }
    throw "$Role project '$Project' was not found in $BaseUrl. Accessible project candidates: $candidateText"
}

function Get-TestPlans {
    param([string]$BaseUrl, [string]$Project, [hashtable]$Headers, [int[]]$PlanIds)
    $requestedPlanIds = @($PlanIds | Where-Object { $null -ne $_ })
    if ($requestedPlanIds.Count -gt 0) {
        $plans = @()
        foreach ($planId in $requestedPlanIds) {
            $uri = "$BaseUrl/$(UrlEnc $Project)/_apis/testplan/plans/$planId`?api-version=7.1"
            $plans += @(Invoke-Ado -Method GET -Uri $uri -Headers $Headers)
        }
        return $plans
    }
    $listUri = "$BaseUrl/$(UrlEnc $Project)/_apis/testplan/plans?includePlanDetails=True&api-version=7.1"
    return @(Invoke-AdoPagedGet -Uri $listUri -Headers $Headers)
}

function Test-IsMissingTestLicenseError {
    param([object]$ErrorRecord)
    $text = ''
    if ($null -ne $ErrorRecord) { $text = [string]$ErrorRecord }
    if ($null -ne $ErrorRecord.Exception) { $text = "$text`n$($ErrorRecord.Exception.Message)" }
    if ($null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) { $text = "$text`n$($ErrorRecord.ErrorDetails.Message)" }
    return $text -match 'TF400409|MissingLicenseException|Web-based Test Execution'
}

function Test-IsTestPlanProjectVisibilityError {
    param([object]$ErrorRecord)
    $text = ''
    if ($null -ne $ErrorRecord) { $text = [string]$ErrorRecord }
    if ($null -ne $ErrorRecord.Exception) { $text = "$text`n$($ErrorRecord.Exception.Message)" }
    if ($null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) { $text = "$text`n$($ErrorRecord.ErrorDetails.Message)" }
    return $text -match 'TF200016|ProjectDoesNotExist|ProjectDoesNotExistWithNameException'
}

function Test-ShouldUseSourceWitFallback {
    param([object]$ErrorRecord)
    return (Test-IsMissingTestLicenseError -ErrorRecord $ErrorRecord) -or (Test-IsTestPlanProjectVisibilityError -ErrorRecord $ErrorRecord)
}

function Test-IsTestPlanWriteUnauthorized {
    param([object]$ErrorRecord)
    $text = ''
    if ($null -ne $ErrorRecord) { $text = [string]$ErrorRecord }
    if ($null -ne $ErrorRecord.Exception) { $text = "$text`n$($ErrorRecord.Exception.Message)" }
    if ($null -ne $ErrorRecord.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($ErrorRecord.ErrorDetails.Message)) { $text = "$text`n$($ErrorRecord.ErrorDetails.Message)" }
    return $text -match 'UnauthorizedAccessException|not authorized to access this API|ADO POST failed \(403\)'
}

function ConvertTo-SourcePlanFromWorkItem {
    param([object]$WorkItem)
    [pscustomobject]@{
        id = [int]$WorkItem.id
        name = [string](Get-FieldValue -WorkItem $WorkItem -ReferenceName 'System.Title')
        areaPath = [string](Get-FieldValue -WorkItem $WorkItem -ReferenceName 'System.AreaPath')
        iteration = [string](Get-FieldValue -WorkItem $WorkItem -ReferenceName 'System.IterationPath')
        description = [string](Get-FieldValue -WorkItem $WorkItem -ReferenceName 'System.Description')
        state = [string](Get-FieldValue -WorkItem $WorkItem -ReferenceName 'System.State')
        rootSuite = [pscustomobject]@{ id = 0; name = [string](Get-FieldValue -WorkItem $WorkItem -ReferenceName 'System.Title') }
        sourceDiscovery = 'wit'
        SourceSuiteRoots = @()
        SourceSuiteCasesBySuiteId = @{}
    }
}

function ConvertTo-SourceSuiteFromWorkItem {
    param([object]$WorkItem, [int]$ParentSuiteId)
    [pscustomobject]@{
        id = [int]$WorkItem.id
        name = [string](Get-FieldValue -WorkItem $WorkItem -ReferenceName 'System.Title')
        suiteType = 'staticTestSuite'
        parentSuite = [pscustomobject]@{ id = $ParentSuiteId }
        inheritDefaultConfigurations = $true
    }
}

function Get-RelatedWorkItemIds {
    param([object]$WorkItem)
    $ids = [Collections.Generic.List[int]]::new()
    if ($null -eq $WorkItem -or -not (Test-HasProperty $WorkItem 'relations')) { return @() }
    foreach ($relation in @($WorkItem.relations)) {
        if ($null -eq $relation -or -not (Test-HasProperty $relation 'url')) { continue }
        if ([string]$relation.url -match '/workItems/(\d+)(?:\?|$)') { $ids.Add([int]$Matches[1]) }
    }
    return $ids.ToArray()
}

function Add-SourceSuiteChildren {
    param(
        [object]$Suite,
        [hashtable]$SuitesById,
        [hashtable]$CasesById,
        [Collections.Generic.HashSet[int]]$VisitedSuites,
        [hashtable]$SuiteCasesBySuiteId
    )
    if ($null -eq $Suite -or -not $VisitedSuites.Add([int]$Suite.id)) { return }
    $childSuites = [Collections.Generic.List[object]]::new()
    $caseIds = [Collections.Generic.List[int]]::new()
    foreach ($relatedId in @(Get-RelatedWorkItemIds -WorkItem $Suite)) {
        $key = [string]$relatedId
        if ($SuitesById.ContainsKey($key) -and -not $VisitedSuites.Contains($relatedId)) {
            $childSuite = ConvertTo-SourceSuiteFromWorkItem -WorkItem $SuitesById[$key] -ParentSuiteId ([int]$Suite.id)
            Add-SourceSuiteChildren -Suite $childSuite -SuitesById $SuitesById -CasesById $CasesById -VisitedSuites $VisitedSuites -SuiteCasesBySuiteId $SuiteCasesBySuiteId
            $childSuites.Add($childSuite)
        } elseif ($CasesById.ContainsKey($key)) {
            $caseIds.Add($relatedId)
        }
    }
    if ($caseIds.Count -gt 0) {
        $SuiteCasesBySuiteId[[string]$Suite.id] = @($caseIds.ToArray() | Select-Object -Unique | ForEach-Object { [pscustomobject]@{ workItem = [pscustomobject]@{ id = [int]$_ }; pointAssignments = @() } })
    }
    if ($childSuites.Count -gt 0) {
        $Suite | Add-Member -NotePropertyName children -NotePropertyValue @($childSuites.ToArray()) -Force
    }
}

function Get-TestPlansFromWorkItems {
    param([string]$BaseUrl, [string]$Project, [hashtable]$Headers, [int[]]$PlanIds)
    Write-Log 'Source Test Plan API is unavailable because of Test Plans licensing or service-specific project visibility. Falling back to Work Item Tracking discovery.' -Level WARN
    $wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.WorkItemType] IN ('Test Plan', 'Test Suite', 'Test Case') ORDER BY [System.Id]"
    $wiqlUri = "$BaseUrl/$(UrlEnc $Project)/_apis/wit/wiql?api-version=7.1"
    $queryResult = Invoke-Ado -Method POST -Uri $wiqlUri -Headers $Headers -Body @{ query = $wiql }
    $ids = @($queryResult.workItems | ForEach-Object { [int]$_.id })
    $workItems = @(Get-WorkItems -Ids $ids -BaseUrl $BaseUrl -Project $Project -Headers $Headers)
    $plansById = @{}
    $suitesById = @{}
    $casesById = @{}
    foreach ($workItem in $workItems) {
        $type = [string](Get-FieldValue -WorkItem $workItem -ReferenceName 'System.WorkItemType')
        if ($type -eq 'Test Plan') { $plansById[[string]$workItem.id] = $workItem }
        elseif ($type -eq 'Test Suite') { $suitesById[[string]$workItem.id] = $workItem }
        elseif ($type -eq 'Test Case') { $casesById[[string]$workItem.id] = $workItem }
    }
    $requestedPlanIds = @($PlanIds | Where-Object { $null -ne $_ })
    $sourcePlanItems = if ($requestedPlanIds.Count -gt 0) {
        @($requestedPlanIds | ForEach-Object { if ($plansById.ContainsKey([string]$_)) { $plansById[[string]$_] } else { throw "Source Test Plan work item #$_ was not returned by Work Item Tracking discovery." } })
    } else {
        @($plansById.Values)
    }
    $sourcePlans = [Collections.Generic.List[object]]::new()
    foreach ($planWorkItem in $sourcePlanItems) {
        $sourcePlan = ConvertTo-SourcePlanFromWorkItem -WorkItem $planWorkItem
        $suiteCasesBySuiteId = @{}
        $visitedSuites = [Collections.Generic.HashSet[int]]::new()
        $rootSuite = [pscustomobject]@{
            id = 0
            name = [string]$sourcePlan.name
            suiteType = 'staticTestSuite'
            parentSuite = [pscustomobject]@{ id = 0 }
            inheritDefaultConfigurations = $true
        }
        $topSuites = [Collections.Generic.List[object]]::new()
        $rootCaseIds = [Collections.Generic.List[int]]::new()
        foreach ($relatedId in @(Get-RelatedWorkItemIds -WorkItem $planWorkItem)) {
            $key = [string]$relatedId
            if ($suitesById.ContainsKey($key)) {
                $suite = ConvertTo-SourceSuiteFromWorkItem -WorkItem $suitesById[$key] -ParentSuiteId 0
                Add-SourceSuiteChildren -Suite $suite -SuitesById $suitesById -CasesById $casesById -VisitedSuites $visitedSuites -SuiteCasesBySuiteId $suiteCasesBySuiteId
                $topSuites.Add($suite)
            } elseif ($casesById.ContainsKey($key)) {
                $rootCaseIds.Add($relatedId)
            }
        }
        if ($topSuites.Count -gt 0) { $rootSuite | Add-Member -NotePropertyName children -NotePropertyValue @($topSuites.ToArray()) -Force }
        if ($rootCaseIds.Count -gt 0) {
            $suiteCasesBySuiteId['0'] = @($rootCaseIds.ToArray() | Select-Object -Unique | ForEach-Object { [pscustomobject]@{ workItem = [pscustomobject]@{ id = [int]$_ }; pointAssignments = @() } })
        }
        $sourcePlan.SourceSuiteRoots = @($rootSuite)
        $sourcePlan.SourceSuiteCasesBySuiteId = $suiteCasesBySuiteId
        $sourcePlans.Add($sourcePlan)
        Write-Log "Discovered Test Plan work item #$($sourcePlan.id) '$($sourcePlan.name)' with $($topSuites.Count) top-level suite link(s) by WIT fallback."
    }
    return $sourcePlans.ToArray()
}

function Get-TestCaseIdsFromWorkItems {
    param([string]$BaseUrl, [string]$Project, [hashtable]$Headers)
    $wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.WorkItemType] = 'Test Case' ORDER BY [System.Id]"
    $wiqlUri = "$BaseUrl/$(UrlEnc $Project)/_apis/wit/wiql?api-version=7.1"
    $queryResult = Invoke-Ado -Method POST -Uri $wiqlUri -Headers $Headers -Body @{ query = $wiql }
    return @($queryResult.workItems | ForEach-Object { [int]$_.id })
}

function Test-SourcePlansHaveSuiteCases {
    param([object[]]$Plans)
    foreach ($plan in @($Plans)) {
        $suiteCasesBySuiteId = Get-ObjectPropertyValue -Value $plan -Name 'SourceSuiteCasesBySuiteId'
        if ($null -eq $suiteCasesBySuiteId) { return $true }
        foreach ($key in @($suiteCasesBySuiteId.Keys)) {
            if (@($suiteCasesBySuiteId[$key]).Count -gt 0) { return $true }
        }
    }
    return $false
}

function Get-TestSuitesTree {
    param([string]$BaseUrl, [string]$Project, [int]$PlanId, [hashtable]$Headers)
    $uri = "$BaseUrl/$(UrlEnc $Project)/_apis/testplan/Plans/$PlanId/suites?asTreeView=True&api-version=7.1"
    $response = Invoke-Ado -Method GET -Uri $uri -Headers $Headers
    if (Test-HasProperty $response 'value') { return @($response.value) }
    return @($response)
}

function Add-SuiteToList {
    param([object]$Suite, [int]$Depth, [Collections.Generic.List[object]]$List)
    if ($null -eq $Suite -or -not (Test-HasProperty $Suite 'id')) { return }
    $List.Add([pscustomobject]@{ Suite = $Suite; Depth = $Depth })
    foreach ($childName in @('children', 'Children')) {
        if (Test-HasProperty $Suite $childName) {
            foreach ($child in @($Suite.$childName)) { Add-SuiteToList -Suite $child -Depth ($Depth + 1) -List $List }
        }
    }
}

function Get-WorkItems {
    param([int[]]$Ids, [string]$BaseUrl, [string]$Project, [hashtable]$Headers)
    $items = @()
    if ($Ids.Count -eq 0) { return $items }
    for ($i = 0; $i -lt $Ids.Count; $i += 200) {
        $last = [Math]::Min($i + 199, $Ids.Count - 1)
        $chunk = @($Ids[$i..$last])
        $uri = "$BaseUrl/$(UrlEnc $Project)/_apis/wit/workitems?ids=$($chunk -join ',')&`$expand=all&api-version=7.1"
        $result = Invoke-Ado -Method GET -Uri $uri -Headers $Headers
        $items += @($result.value)
    }
    return $items
}

function Get-ProjectFields {
    param([string]$BaseUrl, [string]$Project, [hashtable]$Headers)
    $uri = "$BaseUrl/$(UrlEnc $Project)/_apis/wit/fields?api-version=7.1"
    $response = Invoke-Ado -Method GET -Uri $uri -Headers $Headers
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($field in @($response.value)) { [void]$set.Add([string]$field.referenceName) }
    return $set
}

function New-TestPlan {
    param([object]$SourcePlan, [string]$BaseUrl, [string]$Project, [hashtable]$Headers)
    $body = [ordered]@{ name = [string]$SourcePlan.name }
    $areaPath = Get-ObjectPropertyValue -Value $SourcePlan -Name 'areaPath'
    if (-not [string]::IsNullOrWhiteSpace([string]$areaPath)) { $body.areaPath = Convert-ClassificationPath ([string]$areaPath) }
    $iteration = Get-ObjectPropertyValue -Value $SourcePlan -Name 'iteration'
    if (-not [string]::IsNullOrWhiteSpace([string]$iteration)) { $body.iteration = Convert-ClassificationPath ([string]$iteration) }
    $description = Get-ObjectPropertyValue -Value $SourcePlan -Name 'description'
    if ($null -ne $description) { $body.description = [string]$description }
    $state = Get-ObjectPropertyValue -Value $SourcePlan -Name 'state'
    if (-not [string]::IsNullOrWhiteSpace([string]$state)) { $body.state = [string]$state }
    foreach ($name in @('startDate','endDate','testOutcomeSettings')) {
        $value = Get-ObjectPropertyValue -Value $SourcePlan -Name $name
        if ($null -ne $value) { $body[$name] = $value }
    }
    $uri = "$BaseUrl/$(UrlEnc $Project)/_apis/testplan/plans?api-version=7.1"
    return Invoke-Ado -Method POST -Uri $uri -Headers $Headers -Body $body
}

function New-TestPlanWorkItem {
    param([object]$SourcePlan, [Collections.Generic.HashSet[string]]$TargetFields, [string]$BaseUrl, [string]$Project, [hashtable]$Headers)
    $patch = [Collections.Generic.List[object]]::new()
    Add-JsonPatchField -Patch $patch -Field 'System.Title' -Value ([string]$SourcePlan.name)
    if ($TargetFields.Contains('System.Description')) {
        $description = Get-ObjectPropertyValue -Value $SourcePlan -Name 'description'
        if ($null -ne $description) { Add-JsonPatchField -Patch $patch -Field 'System.Description' -Value ([string]$description) }
    }
    $uri = "$BaseUrl/$(UrlEnc $Project)/_apis/wit/workitems/`$Test%20Plan?api-version=7.1"
    if ($SkipNotifications) { $uri += '&suppressNotifications=true' }
    $created = Invoke-Ado -Method POST -Uri $uri -Headers $Headers -Body $patch.ToArray() -ContentType 'application/json-patch+json'
    return [pscustomobject]@{ id = [int]$created.id; rootSuite = [pscustomobject]@{ id = 0 }; sourceCreation = 'wit' }
}

function New-TestSuite {
    param([object]$SourceSuite, [int]$TargetPlanId, [int]$TargetParentSuiteId, [string]$BaseUrl, [string]$Project, [hashtable]$Headers)
    $sourceSuiteType = if (Test-HasProperty $SourceSuite 'suiteType') { [string]$SourceSuite.suiteType } else { 'staticTestSuite' }
    $targetSuiteType = $sourceSuiteType
    if ($sourceSuiteType -ne 'staticTestSuite') {
        if ($DoNotConvertDynamicSuitesToStatic) { throw "Suite '$($SourceSuite.name)' is '$sourceSuiteType'. Re-run without -DoNotConvertDynamicSuitesToStatic to create a static copy of its visible contents." }
        Write-Log "Converting source $sourceSuiteType suite '$($SourceSuite.name)' to a static target suite so copied cases remain visible." -Level WARN
        $targetSuiteType = 'staticTestSuite'
    }
    $body = [ordered]@{
        suiteType = $targetSuiteType
        name = [string]$SourceSuite.name
        parentSuite = @{ id = $TargetParentSuiteId }
    }
    if (Test-HasProperty $SourceSuite 'inheritDefaultConfigurations') { $body.inheritDefaultConfigurations = [bool]$SourceSuite.inheritDefaultConfigurations }
    $uri = "$BaseUrl/$(UrlEnc $Project)/_apis/testplan/Plans/$TargetPlanId/suites?api-version=7.1"
    return Invoke-Ado -Method POST -Uri $uri -Headers $Headers -Body $body
}

function Update-WorkItemFields {
    param([int]$WorkItemId, [object]$SourceWorkItem, [string[]]$Fields, [Collections.Generic.HashSet[string]]$TargetFields, [string]$BaseUrl, [string]$Project, [hashtable]$Headers)
    $failures = [Collections.Generic.List[string]]::new()
    foreach ($field in $Fields) {
        if (-not $TargetFields.Contains($field)) {
            Write-Log "Target field '$field' is absent; skipping for work item #$WorkItemId." -Level WARN
            continue
        }
        $value = Get-FieldValue -WorkItem $SourceWorkItem -ReferenceName $field
        if ($null -eq $value) { continue }
        if ($field -in @('System.AreaPath','System.IterationPath')) { $value = Convert-ClassificationPath ([string]$value) }
        $patch = [Collections.Generic.List[object]]::new()
        Add-JsonPatchField -Patch $patch -Field $field -Value $value
        $uri = "$BaseUrl/$(UrlEnc $Project)/_apis/wit/workitems/$WorkItemId`?api-version=7.1"
        if ($SkipNotifications) { $uri += '&suppressNotifications=true' }
        try { Invoke-Ado -Method PATCH -Uri $uri -Headers $Headers -Body $patch.ToArray() -ContentType 'application/json-patch+json' | Out-Null }
        catch {
            $failures.Add($field)
            Write-Log "Could not copy field '$field' to work item #$WorkItemId`: $($_.Exception.Message)" -Level WARN
        }
    }
    return $failures.ToArray()
}

function New-TestCaseWorkItem {
    param(
        [object]$SourceWorkItem,
        [string[]]$Fields,
        [Collections.Generic.HashSet[string]]$TargetFields,
        [string]$BaseUrl,
        [string]$Project,
        [hashtable]$Headers,
        [switch]$UseTargetDefaultClassificationPaths
    )
    $title = Get-FieldValue -WorkItem $SourceWorkItem -ReferenceName 'System.Title'
    if ([string]::IsNullOrWhiteSpace([string]$title)) { $title = "Copied Test Case $($SourceWorkItem.id)" }
    $patch = [Collections.Generic.List[object]]::new()
    Add-JsonPatchField -Patch $patch -Field 'System.Title' -Value $title
    if (-not $UseTargetDefaultClassificationPaths) {
        foreach ($field in @('System.AreaPath','System.IterationPath')) {
            if ($TargetFields.Contains($field)) {
                $value = Get-FieldValue -WorkItem $SourceWorkItem -ReferenceName $field
                if ($null -ne $value) { Add-JsonPatchField -Patch $patch -Field $field -Value (Convert-ClassificationPath ([string]$value)) }
            }
        }
    }
    $uri = "$BaseUrl/$(UrlEnc $Project)/_apis/wit/workitems/`$Test%20Case?api-version=7.1"
    if ($SkipNotifications) { $uri += '&suppressNotifications=true' }
    $created = Invoke-Ado -Method POST -Uri $uri -Headers $Headers -Body $patch.ToArray() -ContentType 'application/json-patch+json'
    $fieldsToPatch = @($Fields | Where-Object { $_ -notin @('System.Title','System.AreaPath','System.IterationPath') })
    $fieldFailures = Update-WorkItemFields -WorkItemId ([int]$created.id) -SourceWorkItem $SourceWorkItem -Fields $fieldsToPatch -TargetFields $TargetFields -BaseUrl $BaseUrl -Project $Project -Headers $Headers
    return [pscustomobject]@{ WorkItem = $created; FieldFailures = $fieldFailures }
}

function Add-TestCaseToSuite {
    param([int]$PlanId, [int]$SuiteId, [int]$TestCaseId, [object[]]$PointAssignments, [string]$BaseUrl, [string]$Project, [hashtable]$Headers)
    $bodyItem = [ordered]@{ workItem = @{ id = $TestCaseId } }
    if ($null -ne $PointAssignments -and $PointAssignments.Count -gt 0) {
        $bodyItem.pointAssignments = @($PointAssignments | Where-Object { Test-HasProperty $_ 'configurationId' } | ForEach-Object { @{ configurationId = [int]$_.configurationId } })
    }
    $uri = "$BaseUrl/$(UrlEnc $Project)/_apis/testplan/Plans/$PlanId/Suites/$SuiteId/TestCase?api-version=7.1"
    return Invoke-Ado -Method POST -Uri $uri -Headers $Headers -Body @($bodyItem)
}

$script:ResolvedLogPath = $LogPath
if ([string]::IsNullOrWhiteSpace($script:ResolvedLogPath)) {
    $script:ResolvedLogPath = Join-Path $PSScriptRoot ("ado-copy-test-management.{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

$sourceEndpoint = Resolve-AdoProjectEndpoint -ProjectUrl $SourceProjectUrl -Organization $SourceOrg -Project $SourceProject -Role Source
$SourceOrg = $sourceEndpoint.Org
$script:SourceProjectName = $sourceEndpoint.Project
$sourceBase = "https://dev.azure.com/$SourceOrg"
$sourceHeaders = Get-AdoHeaders -Pat $SourcePat -Role Source

$targetEndpoint = Resolve-AdoProjectEndpoint -ProjectUrl $TargetProjectUrl -Organization $TargetOrg -Project $TargetProject -Role Target
$TargetOrg = $targetEndpoint.Org
$script:TargetProjectName = $targetEndpoint.Project
$targetBase = "https://dev.azure.com/$TargetOrg"
$targetHeaders = Get-AdoHeaders -Pat $TargetPat -Role Target

$sourceProjectReference = Resolve-ExistingProjectReference -BaseUrl $sourceBase -Project $script:SourceProjectName -Headers $sourceHeaders -Role Source -AllowUnresolved
$script:SourceProjectName = $sourceProjectReference.Name
$sourceProjectApi = $sourceProjectReference.Id
$sourceProjectResolved = [bool]$sourceProjectReference.Resolved
$sourceProjectCandidateText = if (Test-HasProperty $sourceProjectReference 'CandidateText') { [string]$sourceProjectReference.CandidateText } else { '' }

$targetProjectReference = Resolve-ExistingProjectReference -BaseUrl $targetBase -Project $script:TargetProjectName -Headers $targetHeaders -Role Target
$script:TargetProjectName = $targetProjectReference.Name
$targetProjectApi = $targetProjectReference.Id
$targetProjectRoute = $script:TargetProjectName

$defaultFields = @(
    'System.Title',
    'System.Description',
    'System.Tags',
    'System.AreaPath',
    'System.IterationPath',
    'Microsoft.VSTS.Common.Priority',
    'Microsoft.VSTS.Common.Activity',
    'Microsoft.VSTS.TCM.Steps',
    'Microsoft.VSTS.TCM.LocalDataSource',
    'Microsoft.VSTS.TCM.Parameters',
    'Microsoft.VSTS.TCM.AutomationStatus'
)
$copyFields = @($defaultFields + $AdditionalFieldReferenceNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
$state = Read-MigrationState -Path $StatePath
$targetFields = Get-ProjectFields -BaseUrl $targetBase -Project $targetProjectApi -Headers $targetHeaders
try {
    $plans = @(Get-TestPlans -BaseUrl $sourceBase -Project $sourceProjectApi -Headers $sourceHeaders -PlanIds $SourcePlanIds)
} catch {
    if (-not (Test-ShouldUseSourceWitFallback -ErrorRecord $_)) { throw }
    try {
        $plans = @(Get-TestPlansFromWorkItems -BaseUrl $sourceBase -Project $sourceProjectApi -Headers $sourceHeaders -PlanIds $SourcePlanIds)
    } catch {
        if ((-not $sourceProjectResolved) -and (Test-IsTestPlanProjectVisibilityError -ErrorRecord $_)) {
            $candidateSuffix = if ([string]::IsNullOrWhiteSpace($sourceProjectCandidateText)) { '' } else { " Accessible project candidates for this PAT: $sourceProjectCandidateText." }
            throw "Source project '$($script:SourceProjectName)' is not visible to Azure DevOps REST in $sourceBase. The browser may keep an invalid or stale project path in the address bar while rendering a different project in the page header or breadcrumb.$candidateSuffix"
        }
        throw
    }
}
$stats = [ordered]@{ plansCreated = 0; suitesCreated = 0; testCasesCreated = 0; suiteCaseLinksCreated = 0; warnings = 0 }

Write-Log "Planning copy from $SourceOrg/$($script:SourceProjectName) to $TargetOrg/$($script:TargetProjectName)."
Write-Log "Loaded $($plans.Count) source test plan(s)."

foreach ($sourcePlan in $plans) {
    $sourcePlanId = [int]$sourcePlan.id
    $targetPlanId = $null
    $targetRootSuiteId = $null
    if ($state.plans.ContainsKey([string]$sourcePlanId)) {
        $targetPlanId = [int]$state.plans[[string]$sourcePlanId].targetPlanId
        $targetRootSuiteId = [int]$state.plans[[string]$sourcePlanId].targetRootSuiteId
        Write-Log "Reusing state mapping for plan #$sourcePlanId -> #$targetPlanId."
    } elseif ($PSCmdlet.ShouldProcess("target project '$($script:TargetProjectName)'", "create test plan '$($sourcePlan.name)'")) {
        try {
            $createdPlan = New-TestPlan -SourcePlan $sourcePlan -BaseUrl $targetBase -Project $targetProjectRoute -Headers $targetHeaders
        } catch {
            if (-not (Test-IsTestPlanWriteUnauthorized -ErrorRecord $_)) { throw }
            $suiteRootsForFallback = if (Test-HasProperty $sourcePlan 'SourceSuiteRoots') { @($sourcePlan.SourceSuiteRoots) } else { @() }
            $fallbackSuiteEntries = [Collections.Generic.List[object]]::new()
            foreach ($suiteRootForFallback in $suiteRootsForFallback) { Add-SuiteToList -Suite $suiteRootForFallback -Depth 0 -List $fallbackSuiteEntries }
            if ($fallbackSuiteEntries.Count -gt 1) {
                throw "Target Test Plan API rejected plan creation, and WIT fallback cannot create suite hierarchy for '$($sourcePlan.name)'. Grant target Test Management Read & write, then rerun."
            }
            Write-Log "Target Test Plan API rejected plan creation. Creating Test Plan '$($sourcePlan.name)' as a Work Item Tracking Test Plan instead." -Level WARN
            $createdPlan = New-TestPlanWorkItem -SourcePlan $sourcePlan -TargetFields $targetFields -BaseUrl $targetBase -Project $targetProjectApi -Headers $targetHeaders
            $stats.warnings++
        }
        $targetPlanId = [int]$createdPlan.id
        $targetRootSuiteId = if (Test-HasProperty $createdPlan 'rootSuite' -and $null -ne $createdPlan.rootSuite -and (Test-HasProperty $createdPlan.rootSuite 'id')) { [int]$createdPlan.rootSuite.id } else { 0 }
        $state.plans[[string]$sourcePlanId] = [pscustomobject]@{ targetPlanId = $targetPlanId; targetRootSuiteId = $targetRootSuiteId; name = [string]$sourcePlan.name }
        Write-MigrationState -State $state -Path $StatePath
        $stats.plansCreated++
        Write-Log "Created plan '$($sourcePlan.name)' #$sourcePlanId -> #$targetPlanId."
    } else {
        Write-Log "Preview: would create plan '$($sourcePlan.name)' #$sourcePlanId."
        continue
    }

    $suiteRoots = if (Test-HasProperty $sourcePlan 'SourceSuiteRoots') { @($sourcePlan.SourceSuiteRoots) } else { @(Get-TestSuitesTree -BaseUrl $sourceBase -Project $sourceProjectApi -PlanId $sourcePlanId -Headers $sourceHeaders) }
    $flatSuites = [Collections.Generic.List[object]]::new()
    foreach ($suiteRoot in $suiteRoots) { Add-SuiteToList -Suite $suiteRoot -Depth 0 -List $flatSuites }
    foreach ($suiteEntry in @($flatSuites | Sort-Object Depth)) {
        $suite = $suiteEntry.Suite
        $sourceSuiteId = [int]$suite.id
        $sourceSuiteKey = "$sourcePlanId/$sourceSuiteId"
        if ($state.suites.ContainsKey($sourceSuiteKey)) { continue }
        if ($sourceSuiteId -eq [int]$sourcePlan.rootSuite.id -or [int]$suiteEntry.Depth -eq 0) {
            $state.suites[$sourceSuiteKey] = [pscustomobject]@{ targetPlanId = $targetPlanId; targetSuiteId = $targetRootSuiteId; name = [string]$suite.name }
            Write-MigrationState -State $state -Path $StatePath
            continue
        }
        $sourceParentId = [int]$suite.parentSuite.id
        $parentKey = "$sourcePlanId/$sourceParentId"
        if (-not $state.suites.ContainsKey($parentKey)) { throw "Parent suite mapping is missing for source suite #$sourceSuiteId." }
        $targetParentSuiteId = [int]$state.suites[$parentKey].targetSuiteId
        if ($PSCmdlet.ShouldProcess("target plan #$targetPlanId", "create suite '$($suite.name)'")) {
            try {
                $createdSuite = New-TestSuite -SourceSuite $suite -TargetPlanId $targetPlanId -TargetParentSuiteId $targetParentSuiteId -BaseUrl $targetBase -Project $targetProjectRoute -Headers $targetHeaders
                $state.suites[$sourceSuiteKey] = [pscustomobject]@{ targetPlanId = $targetPlanId; targetSuiteId = [int]$createdSuite.id; name = [string]$suite.name }
                Write-MigrationState -State $state -Path $StatePath
                $stats.suitesCreated++
                Write-Log "Created suite '$($suite.name)' #$sourceSuiteId -> #$($createdSuite.id)."
            } catch {
                $stats.warnings++
                Write-Log "Skipped suite #$sourceSuiteId '$($suite.name)': $($_.Exception.Message)" -Level WARN
                continue
            }
        } else {
            Write-Log "Preview: would create suite '$($suite.name)' under target suite #$targetParentSuiteId."
            continue
        }
    }

    foreach ($suiteEntry in @($flatSuites | Sort-Object Depth)) {
        $sourceSuiteId = [int]$suiteEntry.Suite.id
        $sourceSuiteKey = "$sourcePlanId/$sourceSuiteId"
        if (-not $state.suites.ContainsKey($sourceSuiteKey)) { continue }
        $targetSuiteId = [int]$state.suites[$sourceSuiteKey].targetSuiteId
        $sourceSuiteCasesBySuiteId = Get-ObjectPropertyValue -Value $sourcePlan -Name 'SourceSuiteCasesBySuiteId'
        $suiteCases = if ($null -ne $sourceSuiteCasesBySuiteId) {
            if ($sourceSuiteCasesBySuiteId.ContainsKey([string]$sourceSuiteId)) {
                @($sourceSuiteCasesBySuiteId[[string]$sourceSuiteId])
            } else {
                @()
            }
        } else {
            $testCaseUri = "$sourceBase/$(UrlEnc $sourceProjectApi)/_apis/testplan/Plans/$sourcePlanId/Suites/$sourceSuiteId/TestCase?expand=true&api-version=7.1"
            @(Invoke-AdoPagedGet -Uri $testCaseUri -Headers $sourceHeaders)
        }
        foreach ($suiteCase in $suiteCases) {
            if (-not (Test-HasProperty $suiteCase 'workItem') -or -not (Test-HasProperty $suiteCase.workItem 'id')) { continue }
            $sourceCaseId = [int]$suiteCase.workItem.id
            $targetCaseId = $null
            if ($state.cases.ContainsKey([string]$sourceCaseId)) {
                $targetCaseId = [int]$state.cases[[string]$sourceCaseId].targetCaseId
            } elseif ($PSCmdlet.ShouldProcess("target project '$($script:TargetProjectName)'", "create Test Case from source #$sourceCaseId")) {
                $sourceWorkItem = @(Get-WorkItems -Ids @($sourceCaseId) -BaseUrl $sourceBase -Project $sourceProjectApi -Headers $sourceHeaders)[0]
                $createdCaseResult = New-TestCaseWorkItem -SourceWorkItem $sourceWorkItem -Fields $copyFields -TargetFields $targetFields -BaseUrl $targetBase -Project $targetProjectApi -Headers $targetHeaders
                $targetCaseId = [int]$createdCaseResult.WorkItem.id
                $state.cases[[string]$sourceCaseId] = [pscustomobject]@{ targetCaseId = $targetCaseId; title = [string](Get-FieldValue -WorkItem $sourceWorkItem -ReferenceName 'System.Title') }
                Write-MigrationState -State $state -Path $StatePath
                $stats.testCasesCreated++
                $fieldFailureCount = @($createdCaseResult.FieldFailures).Count
                if ($fieldFailureCount -gt 0) { $stats.warnings += $fieldFailureCount }
                Write-Log "Created Test Case #$sourceCaseId -> #$targetCaseId."
            } else {
                Write-Log "Preview: would create Test Case from source #$sourceCaseId."
                continue
            }

            $suiteCaseKey = "$sourcePlanId/$sourceSuiteId/$sourceCaseId"
            if ($state.suiteCases.ContainsKey($suiteCaseKey)) { continue }
            if ($PSCmdlet.ShouldProcess("target suite #$targetSuiteId", "add Test Case #$targetCaseId")) {
                $pointAssignments = if (Test-HasProperty $suiteCase 'pointAssignments') { @($suiteCase.pointAssignments) } else { @() }
                try {
                    Add-TestCaseToSuite -PlanId $targetPlanId -SuiteId $targetSuiteId -TestCaseId $targetCaseId -PointAssignments $pointAssignments -BaseUrl $targetBase -Project $targetProjectRoute -Headers $targetHeaders | Out-Null
                } catch {
                    Write-Log "Could not add Test Case #$targetCaseId with source point assignments. Retrying with target suite defaults." -Level WARN
                    Add-TestCaseToSuite -PlanId $targetPlanId -SuiteId $targetSuiteId -TestCaseId $targetCaseId -PointAssignments @() -BaseUrl $targetBase -Project $targetProjectRoute -Headers $targetHeaders | Out-Null
                }
                $state.suiteCases[$suiteCaseKey] = [pscustomobject]@{ targetPlanId = $targetPlanId; targetSuiteId = $targetSuiteId; targetCaseId = $targetCaseId }
                Write-MigrationState -State $state -Path $StatePath
                $stats.suiteCaseLinksCreated++
                Write-Log "Added Test Case #$targetCaseId to target suite #$targetSuiteId."
            } else {
                Write-Log "Preview: would add Test Case #$targetCaseId to target suite #$targetSuiteId."
            }
        }
    }
}

if ($CopyStandaloneTestCasesWhenSuitesUnavailable -and -not (Test-SourcePlansHaveSuiteCases -Plans $plans)) {
    $standaloneCaseIds = @(Get-TestCaseIdsFromWorkItems -BaseUrl $sourceBase -Project $sourceProjectApi -Headers $sourceHeaders)
    Write-Log "Suite membership is unavailable; copying $($standaloneCaseIds.Count) source Test Case work item(s) as standalone target Test Cases."
    foreach ($sourceCaseId in $standaloneCaseIds) {
        $targetCaseId = $null
        if ($state.cases.ContainsKey([string]$sourceCaseId)) {
            $targetCaseId = [int]$state.cases[[string]$sourceCaseId].targetCaseId
            Write-Log "Reusing state mapping for Test Case #$sourceCaseId -> #$targetCaseId."
            continue
        }
        if ($PSCmdlet.ShouldProcess("target project '$($script:TargetProjectName)'", "create standalone Test Case from source #$sourceCaseId")) {
            $sourceWorkItem = @(Get-WorkItems -Ids @($sourceCaseId) -BaseUrl $sourceBase -Project $sourceProjectApi -Headers $sourceHeaders)[0]
            $createdCaseResult = New-TestCaseWorkItem -SourceWorkItem $sourceWorkItem -Fields $copyFields -TargetFields $targetFields -BaseUrl $targetBase -Project $targetProjectApi -Headers $targetHeaders -UseTargetDefaultClassificationPaths
            $targetCaseId = [int]$createdCaseResult.WorkItem.id
            $state.cases[[string]$sourceCaseId] = [pscustomobject]@{ targetCaseId = $targetCaseId; title = [string](Get-FieldValue -WorkItem $sourceWorkItem -ReferenceName 'System.Title') }
            Write-MigrationState -State $state -Path $StatePath
            $stats.testCasesCreated++
            $fieldFailureCount = @($createdCaseResult.FieldFailures).Count
            if ($fieldFailureCount -gt 0) { $stats.warnings += $fieldFailureCount }
            Write-Log "Created standalone Test Case #$sourceCaseId -> #$targetCaseId."
        } else {
            Write-Log "Preview: would create standalone Test Case from source #$sourceCaseId."
        }
    }
} elseif ((-not $CopyStandaloneTestCasesWhenSuitesUnavailable) -and -not (Test-SourcePlansHaveSuiteCases -Plans $plans)) {
    Write-Log "Source has no suite-case membership visible through available APIs. Re-run with -CopyStandaloneTestCasesWhenSuitesUnavailable to copy visible Test Case work items without suite links." -Level WARN
    $stats.warnings++
}

$summary = [pscustomobject]$stats
$summary | ConvertTo-Json -Depth 10
$outcome = if ($WhatIfPreference) { 'preview' } elseif ($stats.warnings -gt 0) { 'partial' } else { 'succeeded' }
$message = "Plans created: $($stats.plansCreated); suites created: $($stats.suitesCreated); test cases created: $($stats.testCasesCreated); suite-case links created: $($stats.suiteCaseLinksCreated); warnings: $($stats.warnings)."
Complete-AdoScriptRun -Outcome $outcome -ErrorRecord $null -Operation 'copy-test-management' -Message $message
