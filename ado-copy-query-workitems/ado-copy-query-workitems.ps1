param(
    [string]$SourceQueryUrl,
    [string]$TargetProjectUrl,
    [string]$QueryFolder = 'Shared Queries',
    [SecureString]$SourcePat,
    [SecureString]$TargetPat,
    [string]$StatePath,
    [string]$LogPath,
    [switch]$PreserveClassificationPaths,
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

function Write-RunLog([string]$Level, [string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not [string]::IsNullOrWhiteSpace($script:LogPath)) {
        $parent = Split-Path -Parent $script:LogPath
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Add-Content -LiteralPath $script:LogPath -Value $line -Encoding utf8
    }
}

function Write-Info([string]$Message) {
    Write-Host $Message
    Write-RunLog -Level 'INFO' -Message $Message
}

function Write-Warn([string]$Message) {
    Write-Warning $Message
    Write-RunLog -Level 'WARN' -Message $Message
}


trap {
    $message = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
    Write-RunLog -Level 'ERROR' -Message $message
    Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'copy-query-workitems'
    throw
}

function ConvertTo-AdoOrganizationName([string]$Value) {
    if ($Value -match '^https://dev\.azure\.com/([^/]+)/?') { return $Matches[1] }
    if ($Value -match '^https://([^.]+)\.visualstudio\.com/?') { return $Matches[1] }
    return $Value.Trim('/')
}

function ConvertFrom-SecureStringToPlainText([securestring]$SecureString) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Get-AuthHeader([ValidateSet('Source','Target')][string]$Role, [SecureString]$PatValue) {
    $resolvedPat = Resolve-AdoPat -Pat $PatValue -Role $Role
    return New-AdoAuthorizationHeaders -Pat $resolvedPat
}

function ConvertFrom-AdoQueryUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -notmatch '^https?://') {
        throw 'Source Query URL must be an absolute Azure DevOps query URL.'
    }
    $uri = [uri]$Url
    $segments = @($uri.AbsolutePath.Trim('/') -split '/')
    if ($segments.Count -lt 5 -or $segments[2] -ne '_queries' -or $segments[3] -ne 'query') {
        throw 'Source Query URL must look like https://dev.azure.com/{org}/{project}/_queries/query/{queryId}/'
    }
    return [pscustomobject]@{
        Org = [uri]::UnescapeDataString($segments[0])
        Project = [uri]::UnescapeDataString($segments[1])
        QueryId = [uri]::UnescapeDataString($segments[4])
    }
}

function ConvertFrom-AdoProjectUrl([string]$Url) {
    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -notmatch '^https?://') {
        throw 'Target Project URL must be an absolute Azure DevOps project URL.'
    }
    $uri = [uri]$Url
    $segments = @($uri.AbsolutePath.Trim('/') -split '/')
    if ($segments.Count -lt 2) {
        throw 'Target Project URL must look like https://dev.azure.com/{org}/{project}'
    }
    return [pscustomobject]@{
        Org = [uri]::UnescapeDataString($segments[0])
        Project = [uri]::UnescapeDataString($segments[1])
    }
}

function New-MigrationState {
    return [pscustomobject]@{
        created = @{}
        relations = @{}
    }
}

function Read-MigrationState([string]$Path) {
    $state = New-MigrationState
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $state }

    $raw = Get-Content -Raw -LiteralPath $Path
    if ([string]::IsNullOrWhiteSpace($raw)) { return $state }

    $json = $raw | ConvertFrom-Json
    if ($json.PSObject.Properties.Name -contains 'created') {
        foreach ($prop in $json.created.PSObject.Properties) { $state.created[$prop.Name] = [int]$prop.Value }
    }
    if ($json.PSObject.Properties.Name -contains 'relations') {
        foreach ($prop in $json.relations.PSObject.Properties) { $state.relations[$prop.Name] = [bool]$prop.Value }
    }
    return $state
}

function Write-MigrationState([object]$State, [string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $State | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}
function Invoke-Ado {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][hashtable]$Headers,
        [object]$Body = $null,
        [string]$ContentType = 'application/json; charset=utf-8',
        [switch]$AllowNotFound
    )

    $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers }
    if ($null -ne $Body) {
        $params.ContentType = $ContentType
        $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 100 }
    }

    try { return Invoke-RestMethod @params }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'n/a' }
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }

        if ($AllowNotFound -and $status -eq 404) { return $null }
        if ($status -eq 401 -or $status -eq 403) {
            $detail = "$detail`nAzure DevOps rejected this request. Confirm the PAT belongs to the organization being accessed. Source requires Work Items Read; target requires Work Items Read & Write."
        }

        throw "ADO $Method failed ($status): $Uri`n$detail"
    }
}

function Get-QueryPathParts([string]$Path, [string]$ProjectName, [string]$DefaultFolder, [string]$QueryName) {
    $parts = @($Path -split '/|\\' | Where-Object { $_ })
    if ($parts.Count -gt 0 -and $parts[0] -eq $ProjectName) {
        $parts = if ($parts.Count -gt 1) { @($parts[1..($parts.Count - 1)]) } else { @() }
    }
    if ($parts.Count -gt 0 -and $parts[0] -eq 'My Queries') { $parts[0] = 'Shared Queries' }
    if ($parts.Count -eq 0) { $parts = @($DefaultFolder, $QueryName) }
    return @($parts)
}

function Resolve-AdoQueryFolder {
    param([string[]]$FolderParts, [string]$Base, [string]$Project, [hashtable]$Headers)

    $current = ''
    foreach ($part in $FolderParts) {
        $parentPath = if ($current) { $current } else { '' }
        $pathForGet = if ($current) { "$current/$part" } else { $part }
        $getUri = "$Base/$(UrlEnc $Project)/_apis/wit/queries/$(UrlEnc $pathForGet)?api-version=7.1-preview.2"
        $existingFolder = Invoke-Ado -Method GET -Uri $getUri -Headers $Headers -AllowNotFound
        if ($null -eq $existingFolder) {
            $createUri = if ($parentPath) {
                "$Base/$(UrlEnc $Project)/_apis/wit/queries/$(UrlEnc $parentPath)?api-version=7.1-preview.2"
            }
            else {
                "$Base/$(UrlEnc $Project)/_apis/wit/queries?api-version=7.1-preview.2"
            }
            Invoke-Ado -Method POST -Uri $createUri -Headers $Headers -Body @{ name = $part; isFolder = $true } | Out-Null
        }
        $current = $pathForGet
    }
    return $current
}

function Set-Query {
    param([string[]]$QueryParts, [string]$Wiql, [string]$Base, [string]$Project, [hashtable]$Headers, [string]$DefaultFolder)

    $queryName = $QueryParts[-1]
    $folderParts = if ($QueryParts.Count -gt 1) { @($QueryParts[0..($QueryParts.Count - 2)]) } else { @($DefaultFolder) }
    $folderPath = Resolve-AdoQueryFolder -FolderParts $folderParts -Base $Base -Project $Project -Headers $Headers
    $queryPath = "$folderPath/$queryName"
    $getUri = "$Base/$(UrlEnc $Project)/_apis/wit/queries/$(UrlEnc $queryPath)?`$expand=wiql&api-version=7.1-preview.2"
    $body = @{ name = $queryName; wiql = $Wiql; isFolder = $false }

    $existing = Invoke-Ado -Method GET -Uri $getUri -Headers $Headers -AllowNotFound
    if ($null -ne $existing) {
        if ([string]$existing.name -ceq $queryName -and [string]$existing.wiql -ceq $Wiql) {
            return $existing
        }
        $patchUri = "$Base/$(UrlEnc $Project)/_apis/wit/queries/$($existing.id)?api-version=7.1-preview.2"
        return Invoke-Ado -Method PATCH -Uri $patchUri -Headers $Headers -Body $body
    }

    $postUri = "$Base/$(UrlEnc $Project)/_apis/wit/queries/$(UrlEnc $folderPath)?api-version=7.1-preview.2"
    return Invoke-Ado -Method POST -Uri $postUri -Headers $Headers -Body $body
}

function Convert-WiqlForTarget([string]$Wiql, [string]$SourceProject, [string]$TargetProject) {
    $escapedSource = [regex]::Escape($SourceProject)
    $rewritten = $Wiql -replace "(?i)\[System\.TeamProject\]\s*=\s*'?$escapedSource'?", '[System.TeamProject] = @project'
    $rewritten = $rewritten -replace [regex]::Escape("$SourceProject\"), "$TargetProject\"
    $rewritten = $rewritten -replace [regex]::Escape("'$SourceProject'"), "'$TargetProject'"
    return $rewritten
}

function Get-WorkItems {
    param([int[]]$Ids, [string]$Base, [string]$Project, [hashtable]$Headers)

    $items = @()
    if ($Ids.Count -eq 0) { return $items }

    for ($i = 0; $i -lt $Ids.Count; $i += 200) {
        $last = [Math]::Min($i + 199, $Ids.Count - 1)
        $chunk = @($Ids[$i..$last])
        $idText = ($chunk -join ',')
        $uri = "$Base/$(UrlEnc $Project)/_apis/wit/workitems?ids=$idText&`$expand=relations&api-version=7.1"
        $result = Invoke-Ado -Method GET -Uri $uri -Headers $Headers
        $items += @($result.value)
    }
    return $items
}

function Get-QueryIdsFromResult {
    param([object]$QueryResult)

    if ($null -eq $QueryResult) { return @() }
    $items = @()
    $isRelationResult = $false

    foreach ($propName in @('workItems', 'workItemRelations', 'results')) {
        if ($QueryResult.PSObject.Properties.Name -contains $propName) {
            $items = @($QueryResult.$propName)
            $isRelationResult = $propName -eq 'workItemRelations'
            break
        }
    }

    $ids = New-Object System.Collections.Generic.List[int]
    $seenIds = New-Object System.Collections.Generic.HashSet[int]
    foreach ($item in $items) {
        if ($null -eq $item) { continue }
        $candidateIds = @()
        if ($item.PSObject.Properties.Name -contains 'id') {
            $candidateIds = @([int]$item.id)
        }
        elseif ($item.PSObject.Properties.Name -contains 'workItemId') {
            $candidateIds = @([int]$item.workItemId)
        }
        elseif ($isRelationResult) {
            foreach ($endpoint in @('source', 'target')) {
                if ($item.PSObject.Properties.Name -contains $endpoint -and
                    $null -ne $item.$endpoint -and
                    $item.$endpoint.PSObject.Properties.Name -contains 'id') {
                    $candidateIds += [int]$item.$endpoint.id
                }
            }
        }

        foreach ($candidateId in $candidateIds) {
            if ($seenIds.Add($candidateId)) { $ids.Add($candidateId) }
        }
    }
    return $ids.ToArray()
}

function Get-QueryRelationsFromResult {
    param([object]$QueryResult)

    if ($null -eq $QueryResult -or -not ($QueryResult.PSObject.Properties.Name -contains 'workItemRelations')) { return @() }

    $relations = New-Object System.Collections.Generic.List[object]
    $seenRelations = New-Object System.Collections.Generic.HashSet[string]
    foreach ($item in @($QueryResult.workItemRelations)) {
        if ($null -eq $item -or
            -not ($item.PSObject.Properties.Name -contains 'source') -or
            -not ($item.PSObject.Properties.Name -contains 'target') -or
            -not ($item.PSObject.Properties.Name -contains 'rel') -or
            $null -eq $item.source -or
            $null -eq $item.target -or
            [string]::IsNullOrWhiteSpace([string]$item.rel)) {
            continue
        }

        $sourceId = [int]$item.source.id
        $targetId = [int]$item.target.id
        $key = "$sourceId|$targetId|$($item.rel)"
        if ($seenRelations.Add($key)) {
            $relations.Add([pscustomobject]@{ sourceId = $sourceId; targetId = $targetId; rel = [string]$item.rel })
        }
    }
    return $relations.ToArray()
}

function Get-TargetFieldRefs {
    param([string]$Base, [string]$Project, [string]$WorkItemType, [hashtable]$Headers)

    $fieldsUri = "$Base/$(UrlEnc $Project)/_apis/wit/fields?api-version=7.1"
    $fields = Invoke-Ado -Method GET -Uri $fieldsUri -Headers $Headers
    $writableFields = @{}
    foreach ($field in @($fields.value)) {
        if (-not $field.readOnly) { $writableFields[$field.referenceName] = $field }
    }

    $typeFieldsUri = "$Base/$(UrlEnc $Project)/_apis/wit/workitemtypes/$(UrlEnc $WorkItemType)/fields?api-version=7.1"
    $typeFields = Invoke-Ado -Method GET -Uri $typeFieldsUri -Headers $Headers
    if (-not ($typeFields.PSObject.Properties.Name -contains 'value')) {
        throw "Azure DevOps did not return fields for target work item type '$WorkItemType'."
    }

    $set = @{}
    foreach ($field in @($typeFields.value)) {
        if ($writableFields.ContainsKey($field.referenceName)) { $set[$field.referenceName] = $writableFields[$field.referenceName] }
    }
    return $set
}

function New-PatchOp([string]$Path, [object]$Value) { return @{ op = 'add'; path = $Path; value = $Value } }

function ConvertTo-JsonPatchBody([object[]]$Operations) {
    return ConvertTo-Json -InputObject @($Operations) -Depth 100
}
function Get-SourceWorkItemUrl([object]$WorkItem) {
    if ($null -eq $WorkItem -or -not ($WorkItem.PSObject.Properties.Name -contains '_links')) { return $null }
    if ($null -eq $WorkItem._links -or -not ($WorkItem._links.PSObject.Properties.Name -contains 'html')) { return $null }
    if ($null -eq $WorkItem._links.html -or -not ($WorkItem._links.html.PSObject.Properties.Name -contains 'href')) { return $null }
    return $WorkItem._links.html.href
}
function Get-CreatePatch {
    param([object]$WorkItem, [hashtable]$TargetFieldRefs, [string]$SourceProject, [string]$TargetProject, [bool]$PreserveClassificationPaths)

    $blocked = @(
        'System.Id', 'System.Rev', 'System.TeamProject', 'System.NodeName', 'System.AreaId', 'System.IterationId',
        'System.WorkItemType', 'System.CreatedDate', 'System.CreatedBy', 'System.ChangedDate', 'System.ChangedBy',
        'System.AuthorizedDate', 'System.AuthorizedAs', 'System.Watermark', 'System.CommentCount',
        'System.RemoteLinkCount', 'System.ExternalLinkCount', 'System.RelatedLinkCount', 'System.HyperLinkCount',
        'System.AttachedFileCount', 'System.BoardColumn', 'System.BoardColumnDone', 'System.BoardLane',
        'System.State', 'System.Reason',
        'Microsoft.VSTS.Common.StateChangeDate'
    )
    $blockedSet = @{}
    foreach ($name in $blocked) { $blockedSet[$name] = $true }

    $patch = New-Object System.Collections.Generic.List[object]
    foreach ($prop in $WorkItem.fields.PSObject.Properties) {
        $name = $prop.Name
        $value = $prop.Value
        if ($blockedSet.ContainsKey($name)) { continue }
        if (-not $PreserveClassificationPaths -and $name -in @('System.AreaPath', 'System.IterationPath')) { continue }
        if (-not $TargetFieldRefs.ContainsKey($name)) { continue }
        if ($null -eq $value) { continue }

        $targetField = $TargetFieldRefs[$name]
        if ($targetField.type -eq 'identity' -and $value -isnot [string]) {
            if ($value.PSObject.Properties.Name -contains 'uniqueName' -and $value.uniqueName) { $value = $value.uniqueName }
            elseif ($value.PSObject.Properties.Name -contains 'displayName' -and $value.displayName) { $value = $value.displayName }
        }
        if ($name -in @('System.AreaPath', 'System.IterationPath') -and $value -is [string]) {
            $value = $value -replace "^$([regex]::Escape($SourceProject))(\\|$)", "$TargetProject`$1"
        }
        $patch.Add((New-PatchOp -Path "/fields/$name" -Value $value))
    }

    if (-not ($patch | Where-Object { $_.path -eq '/fields/System.Title' })) {
        $title = if ($WorkItem.fields.'System.Title') { $WorkItem.fields.'System.Title' } else { "Copied work item $($WorkItem.id)" }
        $patch.Insert(0, (New-PatchOp -Path '/fields/System.Title' -Value $title))
    }

    $sourceLink = Get-SourceWorkItemUrl -WorkItem $WorkItem
    if ($sourceLink) {
        $patch.Add(@{
            op = 'add'
            path = '/relations/-'
            value = @{ rel = 'Hyperlink'; url = $sourceLink; attributes = @{ comment = "Copied from source work item $($WorkItem.id)" } }
        })
    }
    return $patch.ToArray()
}

function New-TargetWorkItem {
    param([object]$WorkItem, [hashtable]$TargetFieldRefs, [string]$SourceProject, [string]$TargetProject, [string]$Base, [hashtable]$Headers, [bool]$PreserveClassificationPaths)

    $type = $WorkItem.fields.'System.WorkItemType'
    $uri = "$Base/$(UrlEnc $TargetProject)/_apis/wit/workitems/`$$(UrlEnc $type)?api-version=7.1"
    $patch = Get-CreatePatch -WorkItem $WorkItem -TargetFieldRefs $TargetFieldRefs -SourceProject $SourceProject -TargetProject $TargetProject -PreserveClassificationPaths $PreserveClassificationPaths
    try {
        return Invoke-Ado -Method POST -Uri $uri -Headers $Headers -Body (ConvertTo-JsonPatchBody -Operations $patch) -ContentType 'application/json-patch+json; charset=utf-8'
    }
    catch {
        $fullCopyError = $_.Exception.Message
        $minimal = New-Object System.Collections.Generic.List[object]
        $minimal.Add((New-PatchOp -Path '/fields/System.Title' -Value $WorkItem.fields.'System.Title'))
        $sourceLink = Get-SourceWorkItemUrl -WorkItem $WorkItem
        if ($sourceLink) {
            $minimal.Add((New-PatchOp -Path '/relations/-' -Value @{ rel = 'Hyperlink'; url = $sourceLink; attributes = @{ comment = "Copied from source work item $($WorkItem.id); full field copy failed." } }))
        }
        $result = Invoke-Ado -Method POST -Uri $uri -Headers $Headers -Body (ConvertTo-JsonPatchBody -Operations ($minimal.ToArray())) -ContentType 'application/json-patch+json; charset=utf-8'
        $result | Add-Member -NotePropertyName copyWarning -NotePropertyValue $fullCopyError
        return $result
    }
}

function Update-TargetWorkItem {
    param([int]$TargetId, [object]$SourceWorkItem, [hashtable]$TargetFieldRefs, [string]$SourceProject, [string]$TargetProject, [string]$Base, [string]$Project, [hashtable]$Headers, [bool]$PreserveClassificationPaths)

    $uri = "$Base/$(UrlEnc $Project)/_apis/wit/workitems/${TargetId}?api-version=7.1"
    $patch = Get-CreatePatch -WorkItem $SourceWorkItem -TargetFieldRefs $TargetFieldRefs -SourceProject $SourceProject -TargetProject $TargetProject -PreserveClassificationPaths $PreserveClassificationPaths
    $fieldPatch = @($patch | Where-Object { $_.path -like '/fields/*' })
    if ($fieldPatch.Count -eq 0) { return }
    Invoke-Ado -Method PATCH -Uri $uri -Headers $Headers -Body (ConvertTo-JsonPatchBody -Operations $fieldPatch) -ContentType 'application/json-patch+json; charset=utf-8' | Out-Null
}

function New-TargetWorkItemRelation {
    param([int]$SourceId, [int]$TargetId, [string]$RelationType, [string]$Base, [string]$Project, [hashtable]$Headers)

    $uri = "$Base/$(UrlEnc $Project)/_apis/wit/workitems/${SourceId}?api-version=7.1"
    $targetUrl = "$Base/$(UrlEnc $Project)/_apis/wit/workItems/$TargetId"
    $patch = @(
        (New-PatchOp -Path '/relations/-' -Value @{ rel = $RelationType; url = $targetUrl; attributes = @{ comment = 'Copied from source query relationship' } })
    )
    Invoke-Ado -Method PATCH -Uri $uri -Headers $Headers -Body (ConvertTo-JsonPatchBody -Operations $patch) -ContentType 'application/json-patch+json; charset=utf-8' | Out-Null
}

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $PSScriptRoot ('ado-copy-query-workitems-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$script:LogPath = $LogPath
Write-RunLog -Level 'INFO' -Message '=== ADO query/work item copy started ==='
Write-RunLog -Level 'INFO' -Message ('LogPath: {0}' -f $LogPath)

if ([string]::IsNullOrWhiteSpace($SourceQueryUrl)) {
    $SourceQueryUrl = Read-AdoInput -Prompt 'Source Query URL'
}
$source = ConvertFrom-AdoQueryUrl -Url $SourceQueryUrl

$SourceOrg = $source.Org
$SourceProject = $source.Project
$SourceQueryId = $source.QueryId

$sourceOrgName = ConvertTo-AdoOrganizationName $SourceOrg
$sourceBase = "https://dev.azure.com/$(UrlEnc $sourceOrgName)"

Write-Info "Source: $SourceOrg / $SourceProject / query $SourceQueryId"
$sourceHeaders = Get-AuthHeader -Role Source -PatValue $SourcePat

if ([string]::IsNullOrWhiteSpace($TargetProjectUrl)) {
    $TargetProjectUrl = Read-AdoInput -Prompt 'Target Project URL'
}
$target = ConvertFrom-AdoProjectUrl -Url $TargetProjectUrl

$TargetOrg = $target.Org
$TargetProject = $target.Project

$targetOrgName = ConvertTo-AdoOrganizationName $TargetOrg
$targetBase = "https://dev.azure.com/$(UrlEnc $targetOrgName)"

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $PSScriptRoot 'ado-copy-query-workitems.state.json'
}
Write-RunLog -Level 'INFO' -Message ('StatePath: {0}' -f $StatePath)
$migrationState = Read-MigrationState -Path $StatePath

Write-Info "Target: $TargetOrg / $TargetProject"
$targetHeaders = Get-AuthHeader -Role Target -PatValue $TargetPat

Write-Info 'Loading source query...'
$queryUri = "$sourceBase/$(UrlEnc $SourceProject)/_apis/wit/queries/${SourceQueryId}?`$expand=wiql&api-version=7.1-preview.2"
$query = Invoke-Ado -Method GET -Uri $queryUri -Headers $sourceHeaders
if ($null -eq $query -or -not ($query.PSObject.Properties.Name -contains 'wiql')) {
    throw "Azure DevOps did not return query metadata for source query '$SourceQueryId'. Check that the source PAT belongs to org '$SourceOrg', has Work Items Read, and can access project '$SourceProject'."
}
if (-not $query.wiql) { throw "Source query '$SourceQueryId' did not return WIQL." }
if (-not ($query.PSObject.Properties.Name -contains 'queryType')) {
    throw "Azure DevOps did not return queryType for source query '$SourceQueryId'."
}
if ($query.queryType -notin @('flat', 'tree', 'oneHop')) {
    throw "Source query '$SourceQueryId' is a '$($query.queryType)' query. Only flat, tree, and oneHop queries are supported."
}

$targetWiql = Convert-WiqlForTarget -Wiql $query.wiql -SourceProject $SourceProject -TargetProject $TargetProject
$parts = Get-QueryPathParts -Path $query.path -ProjectName $SourceProject -DefaultFolder $QueryFolder -QueryName $query.name

Write-Info "Creating/updating target query '$($parts -join '/')'..."
$createdQuery = Set-Query -QueryParts $parts -Wiql $targetWiql -Base $targetBase -Project $TargetProject -Headers $targetHeaders -DefaultFolder $QueryFolder

Write-Info 'Executing source query...'
$wiqlUri = "$sourceBase/$(UrlEnc $SourceProject)/_apis/wit/wiql?api-version=7.1"
$queryResult = Invoke-Ado -Method POST -Uri $wiqlUri -Headers $sourceHeaders -Body @{ query = $query.wiql } -ContentType 'application/json; charset=utf-8'
$ids = @(Get-QueryIdsFromResult -QueryResult $queryResult)
$sourceRelations = @(Get-QueryRelationsFromResult -QueryResult $queryResult)
if ($ids.Count -eq 0) { Write-Warn 'The source query returned no work items or the response shape was unexpected.' }
Write-Info "Source query returned $($ids.Count) work item(s)."

$created = @()
$reused = @()
$failed = @()
$targetIdsBySourceId = @{} 
foreach ($entry in $migrationState.created.GetEnumerator()) {
    $targetIdsBySourceId[[int]$entry.Key] = [int]$entry.Value
}
if ($ids.Count -gt 0) {
    $targetFieldRefsByType = @{}
    $items = Get-WorkItems -Ids $ids -Base $sourceBase -Project $SourceProject -Headers $sourceHeaders
    foreach ($item in $items) {
        $sourceItemId = [int]$item.id
        $workItemType = [string]$item.fields.'System.WorkItemType'
        if ($targetIdsBySourceId.ContainsKey($sourceItemId)) {
            $existingTargetId = $targetIdsBySourceId[$sourceItemId]
            try {
                if (-not $targetFieldRefsByType.ContainsKey($workItemType)) {
                    $targetFieldRefsByType[$workItemType] = Get-TargetFieldRefs -Base $targetBase -Project $TargetProject -WorkItemType $workItemType -Headers $targetHeaders
                }
                Update-TargetWorkItem -TargetId $existingTargetId -SourceWorkItem $item -TargetFieldRefs $targetFieldRefsByType[$workItemType] -SourceProject $SourceProject -TargetProject $TargetProject -Base $targetBase -Project $TargetProject -Headers $targetHeaders -PreserveClassificationPaths $PreserveClassificationPaths.IsPresent
                $reused += [pscustomobject]@{ sourceId = $sourceItemId; targetId = $existingTargetId; type = $workItemType; title = $item.fields.'System.Title'; updated = $true }
                Write-Info "  reused/updated #$sourceItemId -> #$existingTargetId"
            }
            catch {
                $reused += [pscustomobject]@{ sourceId = $sourceItemId; targetId = $existingTargetId; type = $workItemType; title = $item.fields.'System.Title'; updated = $false; warning = $_.Exception.Message }
                Write-Warn "  reused #$sourceItemId -> #$existingTargetId but update failed: $($_.Exception.Message)"
            }
            continue
        }
        try {
            $workItemType = [string]$item.fields.'System.WorkItemType'
            if (-not $targetFieldRefsByType.ContainsKey($workItemType)) {
                $targetFieldRefsByType[$workItemType] = Get-TargetFieldRefs -Base $targetBase -Project $TargetProject -WorkItemType $workItemType -Headers $targetHeaders
            }
            $targetFieldRefs = $targetFieldRefsByType[$workItemType]
            $newItem = New-TargetWorkItem -WorkItem $item -TargetFieldRefs $targetFieldRefs -SourceProject $SourceProject -TargetProject $TargetProject -Base $targetBase -Headers $targetHeaders -PreserveClassificationPaths $PreserveClassificationPaths.IsPresent
            $copyWarning = if ($newItem.PSObject.Properties.Name -contains 'copyWarning') { $newItem.copyWarning } else { $null }
            $targetIdsBySourceId[[int]$item.id] = [int]$newItem.id
            $migrationState.created[[string]$item.id] = [int]$newItem.id
            Write-MigrationState -State $migrationState -Path $StatePath
            $created += [pscustomobject]@{ sourceId = $item.id; targetId = $newItem.id; type = $workItemType; title = $item.fields.'System.Title'; partial = ($null -ne $copyWarning); warning = $copyWarning }
            if ($copyWarning) { Write-Warn "  copied #$($item.id) -> #$($newItem.id) with title only: $copyWarning" }
            else { Write-Info "  copied #$($item.id) -> #$($newItem.id)" }
        }
        catch {
            $failed += [pscustomobject]@{ sourceId = $item.id; type = $item.fields.'System.WorkItemType'; title = $item.fields.'System.Title'; error = $_.Exception.Message }
            Write-Warn "  failed #$($item.id): $($_.Exception.Message)"
        }
    }
}

$createdRelations = @()
$failedRelations = @()
foreach ($relation in $sourceRelations) {
    $relationKey = "$($relation.sourceId)|$($relation.targetId)|$($relation.rel)"
    if ($migrationState.relations.ContainsKey($relationKey)) {
        Write-Info "  reused relationship #$($relation.sourceId) -> #$($relation.targetId) ($($relation.rel))"
        continue
    }
    if (-not $targetIdsBySourceId.ContainsKey([int]$relation.sourceId) -or -not $targetIdsBySourceId.ContainsKey([int]$relation.targetId)) {
        $failedRelations += [pscustomobject]@{ sourceId = $relation.sourceId; targetId = $relation.targetId; rel = $relation.rel; error = 'One or both related work items were not copied.' }
        continue
    }

    $targetSourceId = $targetIdsBySourceId[[int]$relation.sourceId]
    $targetTargetId = $targetIdsBySourceId[[int]$relation.targetId]
    try {
        New-TargetWorkItemRelation -SourceId $targetSourceId -TargetId $targetTargetId -RelationType $relation.rel -Base $targetBase -Project $TargetProject -Headers $targetHeaders
        $createdRelations += [pscustomobject]@{ sourceId = $relation.sourceId; targetId = $relation.targetId; targetSourceId = $targetSourceId; targetTargetId = $targetTargetId; rel = $relation.rel }
        $migrationState.relations[$relationKey] = $true
        Write-MigrationState -State $migrationState -Path $StatePath
        Write-Info "  linked #$targetSourceId -> #$targetTargetId ($($relation.rel))"
    }
    catch {
        $failedRelations += [pscustomobject]@{ sourceId = $relation.sourceId; targetId = $relation.targetId; rel = $relation.rel; error = $_.Exception.Message }
        Write-Warn "  failed relationship #$($relation.sourceId) -> #$($relation.targetId): $($_.Exception.Message)"
    }
}

$summary = [pscustomobject]@{
    queryName = $query.name
    queryPath = ($parts -join '/')
    targetQueryId = $createdQuery.id
    sourceWorkItemCount = $ids.Count
    createdWorkItemCount = $created.Count
    reusedWorkItemCount = $reused.Count
    failedWorkItemCount = $failed.Count
    createdRelationCount = $createdRelations.Count
    failedRelationCount = $failedRelations.Count
    created = $created
    reused = $reused
    failed = $failed
    createdRelations = $createdRelations
    failedRelations = $failedRelations
}

$summaryJson = $summary | ConvertTo-Json -Depth 100
$summaryJson

$failureLogPath = [IO.Path]::ChangeExtension($LogPath, '.failures.json')
$reusedWarnings = @($reused | Where-Object { $_.PSObject.Properties.Name -contains 'updated' -and -not $_.updated })
$failureSummary = [pscustomobject]@{
    logPath = $LogPath
    statePath = $StatePath
    failedWorkItems = $failed
    failedRelations = $failedRelations
    reusedUpdateWarnings = $reusedWarnings
}
$failureSummary | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $failureLogPath -Encoding utf8
Write-RunLog -Level 'INFO' -Message ('FailureLogPath: {0}' -f $failureLogPath)
Write-RunLog -Level 'INFO' -Message ('Summary: createdWorkItems={0}, reusedWorkItems={1}, failedWorkItems={2}, createdRelations={3}, failedRelations={4}' -f $created.Count, $reused.Count, $failed.Count, $createdRelations.Count, $failedRelations.Count)
Write-RunLog -Level 'INFO' -Message '=== ADO query/work item copy finished ==='
Write-Info "Log written to: $LogPath"
Write-Info "Failure details written to: $failureLogPath"
if ($failed.Count -gt 0 -or $failedRelations.Count -gt 0) {
    throw "Material partial failure: $($failed.Count) work item operation(s) and $($failedRelations.Count) relation operation(s) failed."
}
Complete-AdoScriptRun -Outcome succeeded -Operation 'copy-query-workitems' -Message 'Query and work item copy completed.'











