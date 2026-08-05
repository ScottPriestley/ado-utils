<#
.SYNOPSIS
	Copies a fixed set of Azure DevOps queries to another project exactly once.

.DESCRIPTION
	Reads five queries from 360sg/AEC Model Combo Project and recreates them in
	hubinternational/RPW Accounting Modernization under Shared Queries. Existing
	target queries are reused, successful copies are recorded in a state file,
	and reruns skip completed work without updating or overwriting target queries.

	PATs are never stored by this script. Set ADO_SOURCE_PAT and ADO_TARGET_PAT,
	pass -SourcePat/-TargetPat, or enter each PAT at the hidden prompt.

.EXAMPLE
	$env:ADO_SOURCE_PAT = '<source-pat>'
	$env:ADO_TARGET_PAT = '<target-pat>'
	.\ado-migrate-query.ps1

.EXAMPLE
	.\ado-migrate-query.ps1 -OutputDirectory C:\Temp\ado-query-copy

.NOTES
	Source PAT scope: Work Items (Read)
	Target PAT scope: Work Items (Read & Write)

	The supplied query URLs point to AEC Model Combo Project, so that project is
	the default source even though a different source overview URL was supplied.
#>
[CmdletBinding()]
param(
	[string]$SourceOrg = '360sg',
	[string]$SourceProject = 'AEC Model Combo Project',
	[string]$TargetOrg = 'hubinternational',
	[string]$TargetProject = 'RPW Accounting Modernization',
	[string[]]$QueryIds = @(
		'd6e6ea26-05de-4716-b960-cc2b1338f343',
		'd8c88812-afc9-463a-9e06-c48abbf7e59c',
		'103ec698-8bc8-4ece-b7b6-e88ad1d9975a',
		'c2390e7b-48e0-4775-b325-d84c26e6eba2',
		'7dedbc10-25d9-4240-895c-21d6bf3b975a'
	),
	[string]$TargetRootFolder = 'Shared Queries',
	[string]$OutputDirectory = (Join-Path $PSScriptRoot 'ado-query-migration-output'),
	[string]$SourcePat = $env:ADO_SOURCE_PAT,
	[string]$TargetPat = $env:ADO_TARGET_PAT
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$restCommand = Get-Command Invoke-RestMethod -ErrorAction Stop
if ($restCommand.CommandType -ne 'Cmdlet' -or $restCommand.Source -ne 'Microsoft.PowerShell.Utility') {
	throw "Invoke-RestMethod is shadowed by '$($restCommand.CommandType) $($restCommand.Source)'. Start a clean PowerShell session before running a live migration."
}

function ConvertTo-UrlSegment {
	param([Parameter(Mandatory)][string]$Value)
	return [uri]::EscapeDataString($Value)
}

function ConvertTo-QueryPath {
	param([Parameter(Mandatory)][string]$Path)
	return (($Path -replace '\\', '/' -split '/' | Where-Object { $_ } |
		ForEach-Object { ConvertTo-UrlSegment $_ }) -join '/')
}

function ConvertFrom-SecurePat {
	param([Parameter(Mandatory)][securestring]$SecurePat)
	return [System.Net.NetworkCredential]::new('', $SecurePat).Password
}

function Get-AdoHeaders {
	param(
		[string]$Pat,
		[Parameter(Mandatory)][string]$Prompt,
		[Parameter(Mandatory)][string]$EnvVarName
	)

	if ([string]::IsNullOrWhiteSpace($Pat)) {
		$Pat = ConvertFrom-SecurePat (Read-Host -Prompt $Prompt -AsSecureString)
	}
	if ([string]::IsNullOrWhiteSpace($Pat)) {
		throw 'A non-empty Azure DevOps PAT is required.'
	}
	[Environment]::SetEnvironmentVariable($EnvVarName, $Pat, 'Process')

	$encodedPat = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$Pat"))
	return @{ Authorization = "Basic $encodedPat"; Accept = 'application/json' }
}

function Get-HttpStatusCode {
	param($ErrorRecord)
	if ($null -eq $ErrorRecord.Exception -or
		-not ($ErrorRecord.Exception.PSObject.Properties.Name -contains 'Response') -or
		$null -eq $ErrorRecord.Exception.Response) {
		return $null
	}
	$statusCode = $ErrorRecord.Exception.Response.StatusCode
	if ($statusCode.PSObject.Properties.Name -contains 'value__') {
		return [int]$statusCode.value__
	}
	return [int]$statusCode
}

function Invoke-AdoRequest {
	param(
		[Parameter(Mandatory)][ValidateSet('GET', 'POST')][string]$Method,
		[Parameter(Mandatory)][string]$Uri,
		[Parameter(Mandatory)][hashtable]$Headers,
		[object]$Body,
		[switch]$AllowNotFound
	)

	$request = @{
		Method = $Method
		Uri = $Uri
		Headers = $Headers
		ContentType = 'application/json; charset=utf-8'
	}
	if ($PSBoundParameters.ContainsKey('Body')) {
		$request.Body = $Body | ConvertTo-Json -Depth 50
	}

	for ($attempt = 0; ; $attempt++) {
		try {
			return Invoke-RestMethod @request
		}
		catch {
			$statusCode = Get-HttpStatusCode $_
			if ($AllowNotFound -and $statusCode -eq 404) { return $null }

			$hasErrorDetail = $null -ne $_.ErrorDetails -and
				($_.ErrorDetails.PSObject.Properties.Name -contains 'Message') -and
				-not [string]::IsNullOrWhiteSpace([string]$_.ErrorDetails.Message)
			$detail = if ($hasErrorDetail) { $_.ErrorDetails.Message } else { $_.Exception.Message }
			$isTransient = $statusCode -in @(429, 500, 502, 503, 504) -or
				$detail -match 'TF10216|CircuitBreaker|currently unavailable|TF400733|throttl'
			if ($isTransient -and $attempt -lt 5) {
				$delaySeconds = [math]::Min(30, [math]::Pow(2, $attempt))
				Start-Sleep -Seconds $delaySeconds
				continue
			}

			if ($statusCode -in @(203, 401, 403)) {
				throw "Authentication or authorization failed calling '$Uri'. Check the PAT, organization, and required scopes."
			}
			throw "Azure DevOps $Method failed (HTTP $statusCode) for '$Uri': $detail"
		}
	}
}

function Write-LogEntry {
	param(
		[Parameter(Mandatory)][ValidateSet('SUCCESS', 'ERROR')][string]$Type,
		[Parameter(Mandatory)][string]$QueryId,
		[Parameter(Mandatory)][string]$Message
	)

	$logPath = if ($Type -eq 'SUCCESS') { $script:SuccessLogPath } else { $script:ErrorLogPath }
	$safeMessage = $Message -replace "[\r\n]+", ' '
	$line = "{0}`t{1}`t{2}`t{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Type, $QueryId, $safeMessage
	Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

function Read-MigrationState {
	param([Parameter(Mandatory)][string]$Path)
	$state = @{}
	if (-not (Test-Path -LiteralPath $Path)) { return $state }

	$content = Get-Content -LiteralPath $Path -Raw
	if ([string]::IsNullOrWhiteSpace($content)) { return $state }
	$savedState = $content | ConvertFrom-Json
	foreach ($property in $savedState.PSObject.Properties) {
		$state[$property.Name.ToLowerInvariant()] = [string]$property.Value
	}
	return $state
}

function Write-MigrationState {
	param(
		[Parameter(Mandatory)][hashtable]$State,
		[Parameter(Mandatory)][string]$Path
	)
	$temporaryPath = "$Path.tmp"
	$State | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
	Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
}

function Get-QueryById {
	param(
		[Parameter(Mandatory)][string]$BaseUrl,
		[Parameter(Mandatory)][string]$Project,
		[Parameter(Mandatory)][string]$QueryId,
		[Parameter(Mandatory)][hashtable]$Headers,
		[switch]$AllowNotFound
	)
	$projectSegment = ConvertTo-UrlSegment $Project
	$uri = "$BaseUrl/$projectSegment/_apis/wit/queries/$QueryId`?`$expand=all&api-version=7.1"
	return Invoke-AdoRequest -Method GET -Uri $uri -Headers $Headers -AllowNotFound:$AllowNotFound
}

function Get-QueryByPath {
	param(
		[Parameter(Mandatory)][string]$BaseUrl,
		[Parameter(Mandatory)][string]$Project,
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][hashtable]$Headers
	)
	$projectSegment = ConvertTo-UrlSegment $Project
	$pathSegment = ConvertTo-QueryPath $Path
	$uri = "$BaseUrl/$projectSegment/_apis/wit/queries/$pathSegment`?`$expand=all&api-version=7.1"
	return Invoke-AdoRequest -Method GET -Uri $uri -Headers $Headers -AllowNotFound
}

function Get-ProjectFields {
	param(
		[Parameter(Mandatory)][string]$BaseUrl,
		[Parameter(Mandatory)][string]$Project,
		[Parameter(Mandatory)][hashtable]$Headers
	)
	$projectSegment = ConvertTo-UrlSegment $Project
	$uri = "$BaseUrl/$projectSegment/_apis/wit/fields?api-version=7.1"
	$response = Invoke-AdoRequest -Method GET -Uri $uri -Headers $Headers
	return @($response.value)
}

function Write-JsonFile {
	param(
		[Parameter(Mandatory)][string]$Path,
		[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Value
	)
	ConvertTo-Json -InputObject @($Value) -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Confirm-TargetFolder {
	param(
		[Parameter(Mandatory)][string]$BaseUrl,
		[Parameter(Mandatory)][string]$Project,
		[Parameter(Mandatory)][string]$FolderPath,
		[Parameter(Mandatory)][hashtable]$Headers
	)

	$segments = @($FolderPath -replace '\\', '/' -split '/' | Where-Object { $_ })
	$currentPath = $segments[0]
	for ($index = 1; $index -lt $segments.Count; $index++) {
		$nextPath = "$currentPath/$($segments[$index])"
		$existing = Get-QueryByPath -BaseUrl $BaseUrl -Project $Project -Path $nextPath -Headers $Headers
		if ($null -eq $existing) {
			$projectSegment = ConvertTo-UrlSegment $Project
			$parentSegment = ConvertTo-QueryPath $currentPath
			$uri = "$BaseUrl/$projectSegment/_apis/wit/queries/$parentSegment`?api-version=7.1"
			Invoke-AdoRequest -Method POST -Uri $uri -Headers $Headers -Body @{
				name = $segments[$index]
				isFolder = $true
			} | Out-Null
		}
		elseif (-not $existing.isFolder) {
			throw "Target path '$nextPath' exists but is not a query folder."
		}
		$currentPath = $nextPath
	}
	return $currentPath
}

function Get-TargetQueryPath {
	param(
		[Parameter(Mandatory)]$SourceQuery,
		[Parameter(Mandatory)][string]$RootFolder
	)

	$sourcePath = ([string]$SourceQuery.path) -replace '\\', '/'
	$relativePath = $sourcePath -replace '^(Shared Queries|My Queries)/?', ''
	if ([string]::IsNullOrWhiteSpace($relativePath)) { $relativePath = [string]$SourceQuery.name }
	return "$($RootFolder.TrimEnd('/'))/$relativePath"
}

function Convert-WiqlForTarget {
	param(
		[Parameter(Mandatory)][string]$Wiql,
		[Parameter(Mandatory)][string]$SourceProjectName,
		[Parameter(Mandatory)][string]$TargetProjectName,
		[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$TargetFields
	)
	$rewritten = [regex]::Replace(
		$Wiql,
		[regex]::Escape($SourceProjectName),
		[System.Text.RegularExpressions.MatchEvaluator]{ param($match) $TargetProjectName },
		[System.Text.RegularExpressions.RegexOptions]::IgnoreCase
	)
	foreach ($referenceName in @('Custom.RAIDItem', 'Custom.RAIDIssue')) {
		$targetField = @($TargetFields | Where-Object { $_.referenceName -eq $referenceName } | Select-Object -First 1)
		$isTargetBoolean = $targetField.Count -gt 0 -and $targetField[0].type -eq 'boolean'
		if (-not $isTargetBoolean) {
			$predicate = "(?i)\s+and\s+\[$([regex]::Escape($referenceName))\]\s*=\s*True"
			$rewritten = [regex]::Replace($rewritten, $predicate, '')
		}
	}
	return $rewritten
}

$OutputDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$script:SuccessLogPath = Join-Path $OutputDirectory 'success.log'
$script:ErrorLogPath = Join-Path $OutputDirectory 'error.log'
$statePath = Join-Path $OutputDirectory 'migration-state.json'
foreach ($logPath in @($script:SuccessLogPath, $script:ErrorLogPath)) {
	if (-not (Test-Path -LiteralPath $logPath)) {
		New-Item -ItemType File -Path $logPath | Out-Null
	}
}
$state = Read-MigrationState -Path $statePath

$sourceHeaders = Get-AdoHeaders -Pat $SourcePat -Prompt "Enter the source PAT for '$SourceOrg'" `
	-EnvVarName 'ADO_SOURCE_PAT'
$targetHeaders = Get-AdoHeaders -Pat $TargetPat -Prompt "Enter the target PAT for '$TargetOrg'" `
	-EnvVarName 'ADO_TARGET_PAT'
$sourceBaseUrl = "https://dev.azure.com/$(ConvertTo-UrlSegment $SourceOrg)"
$targetBaseUrl = "https://dev.azure.com/$(ConvertTo-UrlSegment $TargetOrg)"
$targetFields = Get-ProjectFields -BaseUrl $targetBaseUrl -Project $TargetProject -Headers $targetHeaders
$sourceQuerySnapshots = New-Object System.Collections.Generic.List[object]
$fallbackQueries = @{
	'd8c88812-afc9-463a-9e06-c48abbf7e59c' = [pscustomobject]@{
		id = 'd8c88812-afc9-463a-9e06-c48abbf7e59c'
		name = 'Open Decisions'
		path = 'Shared Queries/Dashboard Queries/RAID/Open Decisions'
		wiql = "select [System.Id], [System.WorkItemType], [System.Title], [System.AssignedTo], [System.State], [Microsoft.VSTS.Scheduling.DueDate], [System.Tags] from WorkItems where [System.TeamProject] = @project and [System.WorkItemType] = 'Decision' and not [System.State] in ('Closed', '90 No Approved', '91 Cancelled', '92 Deferred', '99 Removed') and [Custom.RAIDItem] = True"
	}
	'103ec698-8bc8-4ece-b7b6-e88ad1d9975a' = [pscustomobject]@{
		id = '103ec698-8bc8-4ece-b7b6-e88ad1d9975a'
		name = 'Open Issue'
		path = 'Shared Queries/Dashboard Queries/RAID/Open Issue'
		wiql = "select [System.Id], [System.WorkItemType], [System.Title], [System.AssignedTo], [System.State], [Microsoft.VSTS.Scheduling.DueDate], [System.Tags] from WorkItems where [System.TeamProject] = @project and [System.WorkItemType] = 'Issue' and not [System.State] in ('Closed', '90 No Approved', '91 Cancelled', '92 Deferred', '99 Removed') and [Custom.RAIDItem] = True"
	}
	'7dedbc10-25d9-4240-895c-21d6bf3b975a' = [pscustomobject]@{
		id = '7dedbc10-25d9-4240-895c-21d6bf3b975a'
		name = 'RAID Closed'
		path = 'Shared Queries/Dashboard Queries/RAID/RAID Closed'
		wiql = "select [System.Id], [System.WorkItemType], [System.Title], [System.AssignedTo], [System.State], [Microsoft.VSTS.Common.Risk], [System.Tags] from WorkItems where [System.TeamProject] = 'AEC Model Combo Project' and [System.WorkItemType] in ('Action', 'Risk') and [System.State] in ('Closed', '91 Cancelled') or ([System.WorkItemType] in ('Decision', 'Issue') and [Custom.RAIDIssue] = True and [System.TeamProject] = 'AEC Model Combo Project' and [System.State] in ('Closed', '91 Cancelled'))"
	}
}
$createdCount = 0
$skippedCount = 0
$failedCount = 0

foreach ($queryIdValue in $QueryIds) {
	$queryId = $queryIdValue.ToLowerInvariant()
	try {
		if ($state.ContainsKey($queryId)) {
			$savedTargetQuery = Get-QueryById -BaseUrl $targetBaseUrl -Project $TargetProject `
				-QueryId $state[$queryId] -Headers $targetHeaders -AllowNotFound
			if ($null -ne $savedTargetQuery) {
				$skippedCount++
				$message = "Already completed as '$($savedTargetQuery.path)' (target ID $($savedTargetQuery.id)); no changes made."
				Write-Host "SKIP    $queryId - $message"
				Write-LogEntry -Type SUCCESS -QueryId $queryId -Message $message
				continue
			}
			$state.Remove($queryId)
			Write-MigrationState -State $state -Path $statePath
		}

		try {
			$sourceQuery = Get-QueryById -BaseUrl $sourceBaseUrl -Project $SourceProject `
				-QueryId $queryId -Headers $sourceHeaders
		}
		catch {
			if (-not $fallbackQueries.ContainsKey($queryId)) { throw }
			$sourceQuery = $fallbackQueries[$queryId]
			Write-Host "FALLBACK $queryId - Using exact WIQL recovered from repository history." -ForegroundColor DarkYellow
		}
		if ($null -eq $sourceQuery -or [string]::IsNullOrWhiteSpace([string]$sourceQuery.wiql)) {
			throw 'The source query was not found or did not contain WIQL.'
		}
		$sourceQuerySnapshots.Add([pscustomobject]@{
			id = [string]$sourceQuery.id
			name = [string]$sourceQuery.name
			path = [string]$sourceQuery.path
			wiql = [string]$sourceQuery.wiql
		})

		$targetQueryPath = Get-TargetQueryPath -SourceQuery $sourceQuery -RootFolder $TargetRootFolder
		$existingTargetQuery = Get-QueryByPath -BaseUrl $targetBaseUrl -Project $TargetProject `
			-Path $targetQueryPath -Headers $targetHeaders
		if ($null -ne $existingTargetQuery) {
			$isFolder = ($existingTargetQuery.PSObject.Properties.Name -contains 'isFolder') -and
				[bool]$existingTargetQuery.isFolder
			if ($isFolder) {
				throw "Target path '$targetQueryPath' exists as a folder, not a query."
			}
			$state[$queryId] = [string]$existingTargetQuery.id
			Write-MigrationState -State $state -Path $statePath
			$skippedCount++
			$message = "Query already exists at '$targetQueryPath' (target ID $($existingTargetQuery.id)); recorded as complete without overwriting it."
			Write-Host "EXISTS  $queryId - $message"
			Write-LogEntry -Type SUCCESS -QueryId $queryId -Message $message
			continue
		}

		$lastSlash = $targetQueryPath.LastIndexOf('/')
		$parentPath = $targetQueryPath.Substring(0, $lastSlash)
		Confirm-TargetFolder -BaseUrl $targetBaseUrl -Project $TargetProject `
			-FolderPath $parentPath -Headers $targetHeaders | Out-Null

		$projectSegment = ConvertTo-UrlSegment $TargetProject
		$parentSegment = ConvertTo-QueryPath $parentPath
		$createUri = "$targetBaseUrl/$projectSegment/_apis/wit/queries/$parentSegment`?api-version=7.1"
		$targetWiql = Convert-WiqlForTarget -Wiql ([string]$sourceQuery.wiql) `
			-SourceProjectName $SourceProject -TargetProjectName $TargetProject -TargetFields $targetFields
		$createdQuery = Invoke-AdoRequest -Method POST -Uri $createUri -Headers $targetHeaders -Body @{
			name = [string]$sourceQuery.name
			wiql = $targetWiql
		}
		if ($null -eq $createdQuery -or [string]::IsNullOrWhiteSpace([string]$createdQuery.id)) {
			throw 'Azure DevOps did not return an ID for the newly created query.'
		}

		$state[$queryId] = [string]$createdQuery.id
		Write-MigrationState -State $state -Path $statePath
		$createdCount++
		$message = "Created '$targetQueryPath' as target ID $($createdQuery.id)."
		Write-Host "CREATED $queryId - $message" -ForegroundColor Green
		Write-LogEntry -Type SUCCESS -QueryId $queryId -Message $message
	}
	catch {
		$failedCount++
		$message = $_.Exception.Message
		Write-Host "FAILED  $queryId - $message" -ForegroundColor Red
		Write-LogEntry -Type ERROR -QueryId $queryId -Message $message
	}
}

$referencedFields = @($sourceQuerySnapshots | ForEach-Object {
	[regex]::Matches($_.wiql, '\[([^\]]+)\]') | ForEach-Object { $_.Groups[1].Value }
} | Sort-Object -Unique)
$fieldSchema = foreach ($referenceName in $referencedFields) {
	$targetField = @($targetFields | Where-Object { $_.referenceName -eq $referenceName } | Select-Object -First 1)
	[pscustomobject]@{
		referenceName = $referenceName
		target = if ($targetField.Count) { $targetField[0] | Select-Object name, referenceName, type, readOnly } else { $null }
	}
}
Write-JsonFile -Path (Join-Path $OutputDirectory 'source-queries.json') -Value $sourceQuerySnapshots.ToArray()
Write-JsonFile -Path (Join-Path $OutputDirectory 'field-schema.json') -Value @($fieldSchema)

Write-Host "`nQuery migration complete. Created: $createdCount; skipped/reused: $skippedCount; failed: $failedCount."
Write-Host "Success log: $script:SuccessLogPath"
Write-Host "Error log:   $script:ErrorLogPath"
Write-Host "State file:  $statePath"

if ($failedCount -gt 0) {
	throw "$failedCount query migration(s) failed. Correct the logged errors and rerun this script; completed queries will be skipped."
}
