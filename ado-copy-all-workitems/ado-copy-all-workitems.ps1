<#
.SYNOPSIS
    Copies every work item in a source project to a target project.

.DESCRIPTION
    Project-scoped counterpart to ado-copy-query-workitems, which copies only the
    items returned by one saved query. This script discovers every work item in
    the source project with WIQL, so it needs no saved query and therefore no
    write access to the source.

    Rich-text (HTML) fields are copied verbatim. No HTML parsing, rewriting, or
    sanitising happens, so source formatting is preserved exactly.

    Classification paths are rebased from the source project root onto the target
    project root, which assumes Area and Iteration Paths have already been
    migrated. Items are created first and parent/child links are recreated in a
    second pass, because a parent may be created after its child.

    Progress is written to a state file after every successful create, so a rerun
    resumes rather than duplicating.

.PARAMETER CopyIdentityFields
    Also copy identity-valued fields such as Assigned To. Off by default: a source
    identity that does not exist in the target organization causes the create to
    fail, and most target projects have different membership.

.PARAMETER PreserveClassificationPaths
    Send Area and Iteration Paths exactly as they appear in the source instead of
    rebasing them onto the target project root.

.NOTES
    Does not copy history, revisions, attachments, comments, or links other than
    parent/child. Requires source Work Items Read and target Work Items Read &
    Write.
#>
[CmdletBinding()]
param(
    [string]$SourceProjectUrl,
    [string]$TargetProjectUrl,
    [string]$SourceOrganization,
    [string]$SourceProject,
    [string]$TargetOrganization,
    [string]$TargetProject,
    [SecureString]$SourcePat,
    [SecureString]$TargetPat,
    [string]$StatePath,
    [switch]$CopyIdentityFields,
    [switch]$PreserveClassificationPaths,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'copy-all-workitems'; throw }

# Fields Azure DevOps computes or owns. Sending any of these is either rejected or
# silently ignored, so they never belong in a create payload.
$script:ReadOnlyFields = [Collections.Generic.HashSet[string]]::new(
    [string[]]@(
        'System.Id', 'System.Rev', 'System.WorkItemType', 'System.TeamProject'
        'System.AreaId', 'System.NodeName', 'System.IterationId'
        'System.CreatedDate', 'System.CreatedBy', 'System.ChangedDate', 'System.ChangedBy'
        'System.AuthorizedDate', 'System.AuthorizedAs', 'System.RevisedDate'
        'System.Watermark', 'System.CommentCount', 'System.PersonId', 'System.IsDeleted'
        'System.StateChangeDate', 'System.BoardColumn', 'System.BoardColumnDone', 'System.BoardLane'
        'System.ExternalLinkCount', 'System.RelatedLinkCount', 'System.HyperLinkCount'
        'System.AttachedFileCount', 'System.RemoteLinkCount', 'System.CommentVersionRef'
        'System.Parent'
        'Microsoft.VSTS.Common.StateChangeDate', 'Microsoft.VSTS.Common.ActivatedDate'
        'Microsoft.VSTS.Common.ActivatedBy', 'Microsoft.VSTS.Common.ResolvedDate'
        'Microsoft.VSTS.Common.ResolvedBy', 'Microsoft.VSTS.Common.ClosedDate'
        'Microsoft.VSTS.Common.ClosedBy'
    ),
    [StringComparer]::OrdinalIgnoreCase)

function Get-ResponseStatusCode {
    <#
        AdoUtils.Common.psm1 defines an equivalent, but it is absent from that
        module's Export-ModuleMember list and so cannot be called from here.
    #>
    param([AllowNull()][object]$ErrorRecord)
    if ($null -eq $ErrorRecord) { return $null }
    try { if ($null -ne $ErrorRecord.Exception.Response.StatusCode) { return [int]$ErrorRecord.Exception.Response.StatusCode } } catch { }
    try { if ($null -ne $ErrorRecord.Exception.StatusCode) { return [int]$ErrorRecord.Exception.StatusCode } } catch { }
    $null
}

function New-AdoHeaders {
    <#
        Content-Type is deliberately NOT set here. It is passed to Invoke-RestMethod
        via -ContentType instead, so the charset can be attached; see Invoke-AdoJson.
    #>
    param([Parameter(Mandatory)][string]$PlainPat)
    @{
        Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $PlainPat))
        Accept        = 'application/json'
    }
}

function Invoke-AdoJson {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [string]$Body,
        # charset=utf-8 is mandatory, not decorative. Without it Windows PowerShell 5.1
        # and PowerShell before 7.4 encode a string -Body as ASCII/ISO-8859-1, which
        # mangles curly quotes, en dashes and accented characters. Work item titles and
        # descriptions are full of them, and the corrupted body can be malformed enough
        # that Azure DevOps answers "You must pass a valid patch document".
        [string]$ContentType = 'application/json; charset=utf-8'
    )
    # Invoke-RestMethod deliberately. Under Windows PowerShell 5.1 a plain
    # Invoke-WebRequest hands the response to the Internet Explorer DOM parser, which
    # blocks forever in the windowless process the launcher starts. Invoke-RestMethod
    # never parses HTML and behaves identically in both editions.
    $arguments = @{
        Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = 120
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $arguments['Body'] = $Body
        $arguments['ContentType'] = $ContentType
    }

    try { Invoke-RestMethod @arguments }
    catch {
        # A bare "(404) Not Found" gives the reader nothing to act on. Azure DevOps
        # returns an explanatory body - most usefully naming the work item type or
        # field the target process is missing - so surface it.
        $detail = ''
        try { $detail = [string]$_.ErrorDetails.Message } catch { }
        if ([string]::IsNullOrWhiteSpace($detail)) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = [IO.StreamReader]::new($stream)
                    $detail = $reader.ReadToEnd()
                    $reader.Dispose()
                }
            } catch { }
        }
        if ($detail -match '"message"\s*:\s*"([^"]+)"') { $detail = $Matches[1] }
        if ($detail.Length -gt 300) { $detail = $detail.Substring(0, 300) + '...' }

        $status = Get-ResponseStatusCode $_
        $statusText = if ($null -ne $status) { $status } else { 'no status' }
        throw ("($statusText) " + $(if ($detail) { $detail } else { [string]$_.Exception.Message }))
    }
}

function Get-SourceWorkItemIds {
    <#
        WIQL caps a single result set at 20,000 ids, so page with an id watermark
        rather than assuming one call returns the whole project.
    #>
    param(
        [Parameter(Mandatory)][string]$OrganizationUrl,
        [Parameter(Mandatory)][string]$Project,
        [Parameter(Mandatory)][hashtable]$Headers
    )

    $encodedProject = [Uri]::EscapeDataString($Project)
    $uri = "$OrganizationUrl/$encodedProject/_apis/wit/wiql?api-version=7.1&`$top=20000"
    $all = [Collections.Generic.List[int]]::new()
    $watermark = 0

    while ($true) {
        $wiql = "SELECT [System.Id] FROM WorkItems " +
                "WHERE [System.TeamProject] = @project AND [System.Id] > $watermark " +
                "ORDER BY [System.Id]"
        $body = @{ query = $wiql } | ConvertTo-Json -Compress
        $response = Invoke-AdoJson -Method Post -Uri $uri -Headers $Headers -Body $body

        $items = @()
        $itemsProperty = $response.PSObject.Properties['workItems']
        if ($null -ne $itemsProperty -and $null -ne $itemsProperty.Value) { $items = @($itemsProperty.Value) }
        if ($items.Count -eq 0) { break }

        foreach ($item in $items) { $all.Add([int]$item.id) }
        $watermark = [int]$items[-1].id
        Write-Host "  discovered $($all.Count) work item(s)..."

        if ($items.Count -lt 20000) { break }
    }

    , $all.ToArray()
}

function Get-SourceWorkItemBatch {
    param(
        [Parameter(Mandatory)][string]$OrganizationUrl,
        [Parameter(Mandatory)][int[]]$Ids,
        [Parameter(Mandatory)][hashtable]$Headers
    )
    $body = @{ ids = $Ids; '$expand' = 'All' } | ConvertTo-Json -Compress
    $response = Invoke-AdoJson -Method Post -Headers $Headers -Body $body `
        -Uri "$OrganizationUrl/_apis/wit/workitemsbatch?api-version=7.1"
    @($response.value)
}

function Convert-ClassificationPath {
    <# Rebase "SourceProject\A\B" onto the target project root. #>
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$SourceProjectName,
        [Parameter(Mandatory)][string]$TargetProjectName
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { return $TargetProjectName }
    if ($Path -eq $SourceProjectName) { return $TargetProjectName }

    $prefix = "$SourceProjectName\"
    if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return "$TargetProjectName\" + $Path.Substring($prefix.Length)
    }
    $Path
}

function Test-IsIdentityValue {
    <# Identity fields deserialise as objects carrying uniqueName/displayName. #>
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string] -or $Value -is [ValueType]) { return $false }
    $null -ne $Value.PSObject.Properties['uniqueName'] -or $null -ne $Value.PSObject.Properties['displayName']
}

function New-FieldPatch {
    param(
        [Parameter(Mandatory)]$WorkItem,
        [Parameter(Mandatory)][string]$SourceProjectName,
        [Parameter(Mandatory)][string]$TargetProjectName,
        [switch]$IncludeIdentities,
        [switch]$KeepSourcePaths,
        [switch]$OmitState,
        [switch]$ResetClassification
    )

    $operations = [Collections.Generic.List[object]]::new()
    $skippedIdentities = [Collections.Generic.List[string]]::new()

    foreach ($field in $WorkItem.fields.PSObject.Properties) {
        $name = $field.Name
        if ($script:ReadOnlyFields.Contains($name)) { continue }

        # WEF_<guid>_* fields are per-board artefacts Azure DevOps generates for Kanban
        # state (ExtensionMarker, Kanban.Column, Kanban.Lane). The GUID identifies a
        # board in the SOURCE project, so the target has no such field and rejects the
        # whole work item with TF51535. They carry no content worth migrating.
        if ($name -like 'WEF_*') { continue }

        if ($OmitState -and ($name -eq 'System.State' -or $name -eq 'System.Reason')) { continue }

        $value = $field.Value
        if ($null -eq $value) { continue }

        if (Test-IsIdentityValue -Value $value) {
            if (-not $IncludeIdentities) { $skippedIdentities.Add($name); continue }
            $value = $value.uniqueName
        }

        if ($name -eq 'System.AreaPath' -or $name -eq 'System.IterationPath') {
            if ($ResetClassification) {
                $value = $TargetProjectName
            } elseif (-not $KeepSourcePaths) {
                $value = Convert-ClassificationPath -Path ([string]$value) `
                    -SourceProjectName $SourceProjectName -TargetProjectName $TargetProjectName
            }
        }

        $operations.Add([ordered]@{
            op    = 'add'
            path  = "/fields/$name"
            value = $value
        })
    }

    [pscustomobject]@{
        Operations        = $operations.ToArray()
        SkippedIdentities = $skippedIdentities.ToArray()
    }
}

function ConvertTo-PatchBody {
    <#
        A single operation must still serialise as a JSON array, and an empty set must
        not serialise to "null" - Azure DevOps answers that with "You must pass a valid
        patch document", which reads as a transport fault rather than "there was
        nothing to send".
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Operations)
    if ($Operations.Count -eq 0) { throw 'No copyable fields remained for this work item.' }

    $json = ConvertTo-Json -InputObject $Operations -Depth 6

    # Wrap only when ConvertTo-Json did not already produce an array. Because the
    # parameter is typed [object[]] it normally does, even for one element - wrapping
    # unconditionally yielded [[{...}]], which Azure DevOps rejects with "You must
    # pass a valid patch document" for fields and "At least one operation is required
    # for Apply" for links.
    if (-not $json.TrimStart().StartsWith('[')) { $json = "[$json]" }
    $json
}

function Save-State {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][hashtable]$Map)
    $ordered = [ordered]@{}
    foreach ($key in ($Map.Keys | Sort-Object { [int]$_ })) { $ordered["$key"] = $Map[$key] }
    ($ordered | ConvertTo-Json -Depth 3) | Set-Content -Path $Path -Encoding UTF8
}

# --- Inputs ------------------------------------------------------------------

$source = Resolve-AdoProjectEndpoint -ProjectUrl $SourceProjectUrl `
    -Organization $SourceOrganization -Project $SourceProject -Role Source
$target = Resolve-AdoProjectEndpoint -ProjectUrl $TargetProjectUrl `
    -Organization $TargetOrganization -Project $TargetProject -Role Target

if ($source.Org -eq $target.Org -and $source.Project -eq $target.Project) {
    throw 'Source and target are the same project.'
}

$sourceUrl = "https://dev.azure.com/$($source.Org)"
$targetUrl = "https://dev.azure.com/$($target.Org)"

$sourcePatSecure = Resolve-AdoPat -Pat $SourcePat -Role Source
$targetPatSecure = Resolve-AdoPat -Pat $TargetPat -Role Target
$sourcePlainPat = ConvertFrom-AdoSecureString $sourcePatSecure
$targetPlainPat = ConvertFrom-AdoSecureString $targetPatSecure

if ([string]::IsNullOrWhiteSpace($StatePath)) {
    $StatePath = Join-Path $PSScriptRoot 'ado-copy-all-workitems.state.json'
}

try {
    $sourceHeaders = New-AdoHeaders -PlainPat $sourcePlainPat
    $patchHeaders  = New-AdoHeaders -PlainPat $targetPlainPat
$patchContentType = 'application/json-patch+json; charset=utf-8'

    # Resume map: source id -> target id.
    $map = @{}
    if (Test-Path $StatePath) {
        $existing = Get-Content $StatePath -Raw | ConvertFrom-Json
        foreach ($property in $existing.PSObject.Properties) { $map[$property.Name] = [int]$property.Value }
        Write-Host "Resuming: $($map.Count) work item(s) already copied."
    }

    Write-Host "Discovering work items in '$($source.Org)/$($source.Project)'..."
    $ids = Get-SourceWorkItemIds -OrganizationUrl $sourceUrl -Project $source.Project -Headers $sourceHeaders
    Write-Host "Source work items: $($ids.Count)"

    if ($ids.Count -eq 0) {
        Write-Host 'Nothing to copy.'
        Complete-AdoScriptRun -Outcome succeeded -Operation 'copy-all-workitems' -Message 'No source work items.'
        return
    }

    $created            = 0
    $skipped            = 0
    $skippedUnsupported = 0
    $degraded           = [Collections.Generic.List[string]]::new()
    $failures           = [Collections.Generic.List[object]]::new()
    $identityFieldNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $unsupportedTypes   = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $sourceRelations    = @{}

    # --- Pass 1: create ------------------------------------------------------

    for ($offset = 0; $offset -lt $ids.Count; $offset += 200) {
        $batchIds = @($ids[$offset..([Math]::Min($offset + 199, $ids.Count - 1))])
        $batch = Get-SourceWorkItemBatch -OrganizationUrl $sourceUrl -Ids $batchIds -Headers $sourceHeaders

        foreach ($item in $batch) {
            $sourceId = [string]$item.id

            $relationsProperty = $item.PSObject.Properties['relations']
            if ($null -ne $relationsProperty -and $null -ne $relationsProperty.Value) {
                $sourceRelations[$sourceId] = @($relationsProperty.Value)
            }

            if ($map.ContainsKey($sourceId)) { $skipped++; continue }

            $type = [string]$item.fields.'System.WorkItemType'
            $createUri = "$targetUrl/$([Uri]::EscapeDataString($target.Project))/_apis/wit/workitems/" +
                         "`$$([Uri]::EscapeDataString($type))?api-version=7.1"

            $patch = New-FieldPatch -WorkItem $item -SourceProjectName $source.Project `
                -TargetProjectName $target.Project -IncludeIdentities:$CopyIdentityFields `
                -KeepSourcePaths:$PreserveClassificationPaths
            foreach ($name in $patch.SkippedIdentities) { [void]$identityFieldNames.Add($name) }

            # A work item type the target process does not define can never be created.
            # Once the first item of that type has proved it, skip the rest without
            # calling the API: a source project with ten missing types would otherwise
            # spend hundreds of round trips collecting identical 404s.
            if ($unsupportedTypes.Contains($type)) {
                $skippedUnsupported++
                continue
            }

            $newItem = $null
            try {
                $newItem = Invoke-AdoJson -Method Post -Uri $createUri -Headers $patchHeaders -ContentType $patchContentType `
                    -Body (ConvertTo-PatchBody -Operations $patch.Operations)
            } catch {
                # 404 on create means the work item type itself is absent from the
                # target process. Reducing the field set cannot help, so do not retry.
                if ([string]$_.Exception.Message -match '^\(404\)') {
                    [void]$unsupportedTypes.Add($type)
                    $skippedUnsupported++
                    Write-AdoRunLog -Level warning -Operation 'create-work-item' -Outcome skipped `
                        -Target $sourceId -Message "Work item type '$type' does not exist in the target project."
                    continue
                }
                # Drop only what the target actually rejected. An earlier version
                # discarded the state AND the classification paths on any failure,
                # so a work item refused solely for an unmapped state also lost its
                # Area and Iteration Path - real data thrown away for no reason. The
                # error text says which one is at fault, so reduce that first and
                # fall back to dropping both only if the targeted retry also fails.
                $reason = [string]$_.Exception.Message

                $stateAtFault = $reason -match "field 'State'|field 'Reason'|not in the list of supported values|TF237124"
                $classAtFault = $reason -match 'TF51011|[Aa]rea ?[Pp]ath|[Ii]teration ?[Pp]ath|classification'
                if (-not $stateAtFault -and -not $classAtFault) {
                    # Cause unclear: reduce both rather than guess wrong.
                    $stateAtFault = $true
                    $classAtFault = $true
                }

                $newItem = $null
                $dropped = $null

                foreach ($plan in @(
                    @{ OmitState = $stateAtFault; ResetClass = $classAtFault },
                    @{ OmitState = $true;         ResetClass = $true }
                )) {
                    # The second plan is the catch-all; skip it when it is identical.
                    if ($null -ne $dropped) { break }
                    if ($newItem) { break }

                    $retry = New-FieldPatch -WorkItem $item -SourceProjectName $source.Project `
                        -TargetProjectName $target.Project -IncludeIdentities:$CopyIdentityFields `
                        -OmitState:$plan.OmitState -ResetClassification:$plan.ResetClass

                    try {
                        $newItem = Invoke-AdoJson -Method Post -Uri $createUri -Headers $patchHeaders -ContentType $patchContentType `
                            -Body (ConvertTo-PatchBody -Operations $retry.Operations)

                        $lost = @()
                        if ($plan.OmitState)  { $lost += 'original state' }
                        if ($plan.ResetClass) { $lost += 'area/iteration path' }
                        $dropped = $lost -join ' and '
                    } catch {
                        $reason = [string]$_.Exception.Message
                    }
                }

                if ($newItem) {
                    $degraded.Add("$sourceId ($type): created without $dropped.")
                    Write-AdoRunLog -Level warning -Operation 'create-work-item' -Outcome degraded `
                        -Target $sourceId -Message "Retried without $dropped. First error: $reason"
                } else {
                    $failures.Add([pscustomobject]@{
                        SourceId = $sourceId; Type = $type; Error = $reason
                    })
                    Write-AdoRunLog -Level error -Operation 'create-work-item' -Outcome failed `
                        -Target $sourceId -Message $reason
                    continue
                }
            }

            $map[$sourceId] = [int]$newItem.id
            $created++
            Save-State -Path $StatePath -Map $map

            if ($created % 25 -eq 0) { Write-Host "  created $created of $($ids.Count)..." }
        }
    }

    Write-Host "Created $created work item(s); skipped $skipped already recorded."
    if ($skippedUnsupported -gt 0) {
        Write-Host "Skipped $skippedUnsupported work item(s) whose type does not exist in the target."
    }

    # --- Pass 2: parent/child links ------------------------------------------
    # Deferred because a parent can be created after its child.

    $linked = 0
    $linksAlreadyPresent = 0
    $linkFailures = 0

    foreach ($sourceId in $sourceRelations.Keys) {
        if (-not $map.ContainsKey($sourceId)) { continue }

        foreach ($relation in $sourceRelations[$sourceId]) {
            if ($relation.rel -ne 'System.LinkTypes.Hierarchy-Reverse') { continue }
            if ($relation.url -notmatch '/(\d+)$') { continue }

            $sourceParentId = $Matches[1]
            if (-not $map.ContainsKey($sourceParentId)) { continue }

            $childTargetId  = $map[$sourceId]
            $parentTargetId = $map[$sourceParentId]

            $linkOperations = @(
                [ordered]@{
                    op    = 'add'
                    path  = '/relations/-'
                    value = [ordered]@{
                        rel = 'System.LinkTypes.Hierarchy-Reverse'
                        url = "$targetUrl/_apis/wit/workItems/$parentTargetId"
                    }
                }
            )

            try {
                Invoke-AdoJson -Method Patch -Headers $patchHeaders -ContentType $patchContentType `
                    -Body (ConvertTo-PatchBody -Operations $linkOperations) `
                    -Uri "$targetUrl/_apis/wit/workitems/${childTargetId}?api-version=7.1" | Out-Null
                $linked++
            } catch {
                $linkError = [string]$_.Exception.Message

                # A rerun resumes from the state file and re-walks every relation, so
                # the links it created last time are all still there. Azure DevOps
                # rejects a duplicate relation, which is the expected answer here, not
                # a failure: without this the second run of a completed migration would
                # report every single link as broken.
                if ($linkError -match 'already exists|VS402313|RelationAlreadyExists') {
                    $linksAlreadyPresent++
                    continue
                }

                $linkFailures++
                Write-AdoRunLog -Level error -Operation 'link-work-item' -Outcome failed `
                    -Target "$sourceId -> $sourceParentId" -Message $linkError `
                    -StatusCode (Get-ResponseStatusCode $_)
            }
        }
    }

    Write-Host "Recreated $linked parent/child link(s)."
    if ($linksAlreadyPresent -gt 0) { Write-Host "$linksAlreadyPresent link(s) were already present and left as they are." }

    # --- Summary -------------------------------------------------------------

    if ($identityFieldNames.Count -gt 0) {
        Write-Host ''
        Write-Host "Identity fields were not copied: $(($identityFieldNames | Sort-Object) -join ', ')"
        Write-Host 'Use -CopyIdentityFields if the same identities exist in the target organization.'
    }

    if ($degraded.Count -gt 0) {
        Write-Host ''
        Write-Host "$($degraded.Count) work item(s) were created with reduced fidelity:"
        $degraded | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" }
        if ($degraded.Count -gt 20) { Write-Host "  ... and $($degraded.Count - 20) more; see the error log." }
    }

    Write-Host ''
    Write-Host "State file: $StatePath"

    if ($unsupportedTypes.Count -gt 0) {
        Write-Host ''
        Write-Host "These work item types do not exist in the target project, so $skippedUnsupported item(s) using them were not copied:"
        ($unsupportedTypes | Sort-Object) | ForEach-Object { Write-Host "  $_" }
        Write-Host 'Migrate the target process first (see ado-migrate-workitemtype), then rerun to copy these items.'
    }

    # A work item type the target process does not define is a prerequisite gap, not a
    # failure this script can recover from: rerunning changes nothing until the process
    # is migrated. Treating it as a failure would also stop the surrounding sequence
    # dead, so a target using a different process could never reach the query,
    # dashboard, or wiki steps. It is reported loudly instead. Genuine failures - an
    # item or link the target rejected for any other reason - still fail the run.
    if ($failures.Count -gt 0 -or $linkFailures -gt 0) {
        $failurePath = [IO.Path]::ChangeExtension($StatePath, '.failures.json')
        $failures | ConvertTo-Json -Depth 4 | Set-Content -Path $failurePath -Encoding UTF8

        $parts = @()
        if ($failures.Count -gt 0) { $parts += "$($failures.Count) work item(s) failed" }
        if ($linkFailures -gt 0)   { $parts += "$linkFailures link(s) failed" }
        if ($unsupportedTypes.Count -gt 0) {
            $parts += "$skippedUnsupported item(s) were also skipped because their type is missing from the target"
        }

        $message = "Copied $created work item(s). " + ($parts -join '; ') + ". Details: $failurePath"
        Complete-AdoScriptRun -Outcome partial -Operation 'copy-all-workitems' -Message $message
        throw $message
    }

    if ($unsupportedTypes.Count -gt 0) {
        Complete-AdoScriptRun -Outcome partial -Operation 'copy-all-workitems' `
            -Message ("Copied $created work item(s) and $linked link(s). $skippedUnsupported item(s) skipped: " +
                      "the target process does not define $(($unsupportedTypes | Sort-Object) -join ', ').")
        return
    }

    Complete-AdoScriptRun -Outcome succeeded -Operation 'copy-all-workitems' `
        -Message "Created $created work item(s) and $linked link(s)."
}
finally {
    if ($sourcePlainPat) { $sourcePlainPat = $null }
    if ($targetPlainPat) { $targetPlainPat = $null }
}
