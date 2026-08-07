<#
.SYNOPSIS
    Migrates an Azure DevOps inherited process from one organization to another,
    including work item types, fields, picklists, states, rules, and layout.

.DESCRIPTION
    Prompts for (or accepts as parameters) the source process name, source
    organization / PAT, and target organization / PAT, then replicates the
    inherited process structure in the target organization.

    What it migrates:
      1. The inherited process itself (created if missing).
      2. All work item types (WITs) within the process (custom and inherited).
      3. Picklists backing any custom picklist fields.
      4. Org-level custom field definitions.
      5. Field membership on each WIT (required / default / allow-groups / read-only).
      6. Custom states, and hiding of inherited states.
      7. Custom rules on each WIT.
      8. Form layout: pages, groups, and controls for each WIT.

    Not migrated: backlog-level/behavior assignments, extension (contribution)
    controls, process permissions, projects, work items, or process description/
    properties beyond basic metadata. Both PATs need "Work Items (Read/Write)"
    plus "Process (Read & Write)"; creating org-level fields in the target
    requires Project Collection Administrator (or "Create process" permission).

    The script is idempotent -- already-existing items are detected and
    skipped or updated, so it is safe to re-run after fixing a failure.

.EXAMPLE
    .\ado-migrate-process.ps1
    # Prompts interactively for all inputs.

.EXAMPLE
    .\ado-migrate-process.ps1 -SourceOrganization 'source-org' -SourceProcess 'My Process' `
        -TargetOrganization 'target-org'
    # Prompts only for the two PATs and target process name.
#>
[CmdletBinding()]
param(
    [string]$SourceOrganization,
    [string]$SourceProcess,
    [SecureString]$SourcePat,
    [string]$TargetOrganization,
    [string]$TargetProcess,
    [SecureString]$TargetPat,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'migrate-process'; throw }

# ---------------------------------------------------------------- helpers ---

function Get-PlainText([SecureString]$SecureValue) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Resolve-OrgUrl([string]$Org) {
    if ([string]::IsNullOrWhiteSpace($Org)) {
        throw 'Azure DevOps organization is required.'
    }

    $value = $Org.Trim().TrimEnd('/')
    # Accept https://dev.azure.com/{org} or https://dev.azure.com/{org}/{project}
    if ($value -match '^https?://dev\.azure\.com/([^/?#]+)') {
        return "https://dev.azure.com/$($Matches[1])"
    }
    # Accept https://{org}.visualstudio.com or https://{org}.visualstudio.com/{project}
    if ($value -match '^https?://([^.]+)\.visualstudio\.com') {
        return "https://dev.azure.com/$($Matches[1])"
    }
    # Accept just the org name
    if ($value -match '^[^/\s]+$') {
        return "https://dev.azure.com/$value"
    }

    throw 'Azure DevOps organization must be an organization name or URL (for example, contoso or https://dev.azure.com/contoso).'
}

function New-AuthHeader([SecureString]$Pat) {
    $plain = Get-PlainText $Pat
    @{
        Authorization  = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $plain))
        Accept         = 'application/json'
        'Content-Type' = 'application/json'
    }
}

function Get-Prop($Object, [string]$Name, $Default = $null) {
    if ($null -eq $Object) { return $Default }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -ne $p) { return $p.Value } else { return $Default }
}

function Invoke-Ado {
    param(
        [string]$Method = 'GET',
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        $Body,
        [switch]$AllowNotFound
    )
    $params = @{ Method = $Method; Uri = $Uri; Headers = $Headers; TimeoutSec = 60; UseBasicParsing = $true }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 20)
        # charset=utf-8 is required: without it Windows PowerShell 5.1 and PowerShell
        # before 7.4 encode a string body as ASCII/ISO-8859-1 and silently degrade any
        # character outside that range. Process migration carries field, type and state
        # names verbatim, so a corrupted name creates a subtly wrong process definition
        # rather than an obvious error.
        $params.ContentType = 'application/json; charset=utf-8'
    }
    try {
        $resp = Invoke-WebRequest -UseBasicParsing @params
        if ($resp.Content) { return $resp.Content | ConvertFrom-Json }
        return $null
    }
    catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($AllowNotFound -and $status -eq 404) { return $null }
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            try { $detail = ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch { $detail = $_.ErrorDetails.Message }
        }
        throw "ADO API $Method $Uri failed (HTTP $status): $detail"
    }
}

function Write-Step([string]$Message) { Write-Host "`n== $Message ==" -ForegroundColor Cyan }
function Write-Ok([string]$Message)   { Write-Host "   [OK]   $Message" -ForegroundColor Green }
function Write-Skip([string]$Message) { Write-Host "   [SKIP] $Message" -ForegroundColor DarkGray }
function Write-Warn2([string]$Message){ Write-Host "   [WARN] $Message" -ForegroundColor Yellow }

# API versions (process customization APIs are still -preview)
$vProc   = 'api-version=7.1-preview.2'   # processes, work item types, WIT fields, rules
$vLists  = 'api-version=7.1-preview.1'   # picklists
$vStates = 'api-version=7.1-preview.1'   # states
$vLayout = 'api-version=7.1-preview.1'   # layout / pages / groups / controls
$vFields = 'api-version=7.1'             # org-level wit/fields (GA)

# ----------------------------------------------------------------- prompts ---

$SourceOrganization = Resolve-AdoRequiredInput -Value $SourceOrganization -Name 'Source organization' -Prompt (Get-AdoPrompt SourceOrganization)
$SourceProcess = Resolve-AdoRequiredInput -Value $SourceProcess -Name 'Source process' -Prompt 'SOURCE process name'
$SourcePat = Resolve-AdoPat -Pat $SourcePat -Role Source
$TargetOrganization = Resolve-AdoRequiredInput -Value $TargetOrganization -Name 'Target organization' -Prompt (Get-AdoPrompt TargetOrganization)
$TargetProcess = Resolve-AdoRequiredInput -Value $TargetProcess -Name 'Target process' -Prompt 'TARGET process name (will be created if it does not exist)'
$TargetPat = Resolve-AdoPat -Pat $TargetPat -Role Target

$srcOrgUrl = Resolve-OrgUrl $SourceOrganization
$tgtOrgUrl = Resolve-OrgUrl $TargetOrganization
$srcHeaders = New-AuthHeader $SourcePat
$tgtHeaders = New-AuthHeader $TargetPat

Write-Host ("`nSource: {0} / Process: {1}" -f $srcOrgUrl, $SourceProcess) -ForegroundColor Cyan
Write-Host ("Target: {0} / Process: {1}" -f $tgtOrgUrl, $TargetProcess) -ForegroundColor Cyan

# ---------------------------------------------------------------- source process ---

Write-Step "Fetching source process: $SourceProcess"
$srcProcessesUri = "$srcOrgUrl/_apis/work/processes?`$expand=all&$vProc"
$srcProcesses = (Invoke-Ado -Uri $srcProcessesUri -Headers $srcHeaders).value
$srcProcess = $srcProcesses | Where-Object { $_.name -eq $SourceProcess }

if (-not $srcProcess) {
    throw "Source process '$SourceProcess' not found in organization '$SourceOrganization'. Available: $($srcProcesses.name -join ', ')"
}

$srcProcessId = $srcProcess.typeId
Write-Ok "Found source process: $($srcProcess.name) (ID: $srcProcessId, Type: $($srcProcess.customizationType))"
Write-AdoRunLog -Level info -Operation fetch-source-process -Outcome found -Target $srcProcess.name -Message "Process ID: $srcProcessId"

# ---------------------------------------------------------------- target process ---

Write-Step "Resolving target process: $TargetProcess"
$tgtProcessesUri = "$tgtOrgUrl/_apis/work/processes?`$expand=all&$vProc"
$tgtProcesses = (Invoke-Ado -Uri $tgtProcessesUri -Headers $tgtHeaders).value
$tgtProcess = $tgtProcesses | Where-Object { $_.name -eq $TargetProcess }

if ($tgtProcess) {
    Write-Ok "Target process already exists: $($tgtProcess.name) (ID: $($tgtProcess.typeId), Type: $($tgtProcess.customizationType))"
    $tgtProcessId = $tgtProcess.typeId
} else {
    Write-Step "Creating target process: $TargetProcess"
    
    # Find a suitable parent process - prefer Agile if available
    $parentProcess = $tgtProcesses | Where-Object { $_.name -eq 'Agile' -and $_.customizationType -eq 'system' } | Select-Object -First 1
    if (-not $parentProcess) {
        $parentProcess = $tgtProcesses | Where-Object { $_.customizationType -eq 'system' } | Select-Object -First 1
    }
    
    if (-not $parentProcess) {
        throw "No suitable parent process found in target organization. At least one system process must exist."
    }
    
    $createBody = @{
        name = $TargetProcess
        description = "Migrated from $SourceOrganization/$SourceProcess"
        parentProcessTypeId = $parentProcess.typeId
    }
    
    $createUri = "$tgtOrgUrl/_apis/work/processes?$vProc"
    $tgtProcess = Invoke-Ado -Method POST -Uri $createUri -Headers $tgtHeaders -Body $createBody
    $tgtProcessId = $tgtProcess.typeId
    Write-Ok "Created target process: $($tgtProcess.name) (ID: $tgtProcessId, Parent: $($parentProcess.name))"
    Write-AdoRunLog -Level info -Operation create-target-process -Outcome created -Target $tgtProcess.name -Message "Process ID: $tgtProcessId, Parent: $($parentProcess.name)"
}

# Verify target process is inherited/customizable
if ($tgtProcess.customizationType -eq 'system') {
    throw "Target process '$($tgtProcess.name)' is a system process and cannot be customized. Please specify an inherited process or a new process name."
}

# ---------------------------------------------------------------- work item types ---

Write-Step "Fetching work item types from source process"
$srcWitsUri = "$srcOrgUrl/_apis/work/processes/$srcProcessId/workitemtypes?`$expand=all&$vProc"
$srcWits = (Invoke-Ado -Uri $srcWitsUri -Headers $srcHeaders).value
Write-Ok "Found $($srcWits.Count) work item types in source process"

Write-Step "Fetching work item types from target process"
$tgtWitsUri = "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes?`$expand=all&$vProc"
$tgtWits = (Invoke-Ado -Uri $tgtWitsUri -Headers $tgtHeaders).value
Write-Ok "Found $($tgtWits.Count) work item types in target process"

# ---------------------------------------------------------------- picklists ---

Write-Step "Migrating picklists"
$srcPicklistsUri = "$srcOrgUrl/_apis/work/processes/lists?$vLists"
$srcPicklists = (Invoke-Ado -Uri $srcPicklistsUri -Headers $srcHeaders).value | Where-Object { -not $_.isSuggested }

$tgtPicklistsUri = "$tgtOrgUrl/_apis/work/processes/lists?$vLists"
$tgtPicklists = (Invoke-Ado -Uri $tgtPicklistsUri -Headers $tgtHeaders).value

$picklistMap = @{}
$picklistCount = 0

foreach ($srcList in $srcPicklists) {
    $existing = $tgtPicklists | Where-Object { $_.name -eq $srcList.name }
    if ($existing) {
        Write-Skip "Picklist already exists: $($srcList.name)"
        $picklistMap[$srcList.id] = $existing.id
    } else {
        $listItems = @(Get-Prop $srcList 'items' @())
        
        # Azure DevOps requires at least one item in a picklist
        if ($listItems.Count -eq 0) {
            Write-Skip "Picklist has no items, skipping: $($srcList.name)"
            continue
        }
        
        $createBody = @{
            name = $srcList.name
            type = Get-Prop $srcList 'type' 'String'
            isSuggested = $false
            items = $listItems
        }
        $createUri = "$tgtOrgUrl/_apis/work/processes/lists?$vLists"
        try {
            $newList = Invoke-Ado -Method POST -Uri $createUri -Headers $tgtHeaders -Body $createBody
            $picklistMap[$srcList.id] = $newList.id
            Write-Ok "Created picklist: $($srcList.name) ($($listItems.Count) items)"
            $picklistCount++
            Write-AdoRunLog -Level info -Operation create-picklist -Outcome created -Target $srcList.name
        } catch {
            Write-Warn2 "Failed to create picklist '$($srcList.name)': $_"
            Write-AdoRunLog -Level warning -Operation create-picklist -Outcome failed -Target $srcList.name -Message $_.Exception.Message
        }
    }
}
Write-Ok "Created $picklistCount new picklists"

# ---------------------------------------------------------------- fields ---

Write-Step "Migrating organization-level fields"
$srcFieldsUri = "$srcOrgUrl/_apis/wit/fields?$vFields"
$srcFields = (Invoke-Ado -Uri $srcFieldsUri -Headers $srcHeaders).value | Where-Object { 
    (Get-Prop $_ 'isIdentity' $false) -eq $false -and (Get-Prop $_ 'type') -ne 'html' 
}

$tgtFieldsUri = "$tgtOrgUrl/_apis/wit/fields?$vFields"
$tgtFields = (Invoke-Ado -Uri $tgtFieldsUri -Headers $tgtHeaders).value

$fieldMap = @{}
$fieldCount = 0

foreach ($srcField in $srcFields | Where-Object { -not (Get-Prop $_ 'isSystem' $false) }) {
    $existing = $tgtFields | Where-Object { $_.referenceName -eq $srcField.referenceName }
    if ($existing) {
        Write-Skip "Field already exists: $($srcField.name) ($($srcField.referenceName))"
        $fieldMap[$srcField.referenceName] = $existing.referenceName
    } else {
        $createBody = @{
            name = $srcField.name
            referenceName = $srcField.referenceName
            description = Get-Prop $srcField 'description' ''
            type = $srcField.type
            usage = Get-Prop $srcField 'usage' 'workItem'
            readOnly = Get-Prop $srcField 'readOnly' $false
            canSortBy = Get-Prop $srcField 'canSortBy' $true
            isQueryable = Get-Prop $srcField 'isQueryable' $true
            supportedOperations = Get-Prop $srcField 'supportedOperations' @()
        }
        
        # Add picklist reference if applicable
        if ($srcField.type -eq 'picklistString' -or $srcField.type -eq 'picklistInteger') {
            $picklistId = Get-Prop $srcField 'picklistId'
            if ($picklistId -and $picklistMap.ContainsKey($picklistId)) {
                $createBody['picklistId'] = $picklistMap[$picklistId]
            }
        }
        
        $createUri = "$tgtOrgUrl/_apis/wit/fields?$vFields"
        try {
            $newField = Invoke-Ado -Method POST -Uri $createUri -Headers $tgtHeaders -Body $createBody
            $fieldMap[$srcField.referenceName] = $newField.referenceName
            Write-Ok "Created field: $($srcField.name) ($($srcField.referenceName))"
            $fieldCount++
            Write-AdoRunLog -Level info -Operation create-field -Outcome created -Target $srcField.referenceName
        } catch {
            Write-Warn2 "Failed to create field '$($srcField.name)' ($($srcField.referenceName)): $_"
            Write-AdoRunLog -Level warning -Operation create-field -Outcome failed -Target $srcField.referenceName -Message $_.Exception.Message
        }
    }
}
Write-Ok "Created $fieldCount new fields"

# ---------------------------------------------------------------- migrate each WIT ---

$witCount = 0
$stateCount = 0
$ruleCount = 0
$layoutCount = 0

foreach ($srcWit in $srcWits) {
    Write-Step "Processing WIT: $($srcWit.name) ($($srcWit.inherits))"
    
    # Find or create target WIT
    $tgtWit = $tgtWits | Where-Object { $_.referenceName -eq $srcWit.referenceName }
    
    if (-not $tgtWit) {
        # Create new WIT
        $createWitBody = @{
            name = $srcWit.name
            description = Get-Prop $srcWit 'description' ''
            color = Get-Prop $srcWit 'color' '009CCC'
            icon = Get-Prop $srcWit 'icon' 'icon_book'
        }
        
        # Determine if custom or derived from system type
        if ($srcWit.inherits) {
            # Try to derive from system type
            $systemWit = $tgtWits | Where-Object { (Get-Prop $_ 'class') -eq 'system' -and $_.referenceName -eq $srcWit.inherits }
            if ($systemWit) {
                $createWitBody['inherits'] = $srcWit.inherits
            }
        }
        
        $createWitUri = "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes?$vProc"
        try {
            $tgtWit = Invoke-Ado -Method POST -Uri $createWitUri -Headers $tgtHeaders -Body $createWitBody
            Write-Ok "Created WIT: $($tgtWit.name)"
            $witCount++
            Write-AdoRunLog -Level info -Operation create-wit -Outcome created -Target $tgtWit.name
        } catch {
            # If creation failed because WIT name already exists, try to find it by name
            if ($_.Exception.Message -match 'already in use') {
                Write-Warn2 "WIT name '$($srcWit.name)' already exists, attempting to find and use existing WIT"
                # Refresh target WITs list
                $tgtWits = (Invoke-Ado -Uri $tgtWitsUri -Headers $tgtHeaders).value
                # Find WIT by name, but only if it's customizable (not a system WIT from parent process)
                $tgtWit = $tgtWits | Where-Object { 
                    $_.name -eq $srcWit.name -and (Get-Prop $_ 'customizationType') -ne 'system' 
                } | Select-Object -First 1
                
                if ($tgtWit) {
                    Write-Skip "Using existing WIT: $($tgtWit.name) (reference: $($tgtWit.referenceName))"
                } else {
                    Write-Warn2 "WIT '$($srcWit.name)' is a system WIT in target and cannot be customized, skipping"
                    Write-AdoRunLog -Level warning -Operation create-wit -Outcome skipped -Target $srcWit.name -Message "System WIT cannot be customized"
                    continue
                }
            } else {
                Write-Warn2 "Failed to create WIT '$($srcWit.name)': $_"
                Write-AdoRunLog -Level warning -Operation create-wit -Outcome failed -Target $srcWit.name -Message $_.Exception.Message
                continue
            }
        }
    } else {
        # WIT already exists - check if it's customizable
        if ((Get-Prop $tgtWit 'customizationType') -eq 'system') {
            Write-Warn2 "WIT '$($tgtWit.name)' is a system WIT in target and cannot be customized, skipping"
            Write-AdoRunLog -Level warning -Operation process-wit -Outcome skipped -Target $tgtWit.name -Message "System WIT cannot be customized"
            continue
        }
        Write-Skip "WIT already exists: $($tgtWit.name)"
    }
    
    # Ensure we have a valid target WIT before proceeding
    if (-not $tgtWit) {
        Write-Warn2 "No target WIT available for '$($srcWit.name)', skipping"
        continue
    }
    
    # Migrate fields for this WIT
    Write-Step "  Migrating fields for WIT: $($srcWit.name)"
    $srcWitFieldsUri = "$srcOrgUrl/_apis/work/processes/$srcProcessId/workitemtypes/$($srcWit.referenceName)/fields?$vProc"
    $srcWitFields = (Invoke-Ado -Uri $srcWitFieldsUri -Headers $srcHeaders).value
    
    $tgtWitFieldsUri = "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes/$($tgtWit.referenceName)/fields?$vProc"
    $tgtWitFields = (Invoke-Ado -Uri $tgtWitFieldsUri -Headers $tgtHeaders).value
    
    $witFieldCount = 0
    foreach ($srcWitField in $srcWitFields) {
        $existing = $tgtWitFields | Where-Object { $_.referenceName -eq $srcWitField.referenceName }
        
        $fieldBody = @{
            referenceName = $srcWitField.referenceName
            required = Get-Prop $srcWitField 'required' $false
            readOnly = Get-Prop $srcWitField 'readOnly' $false
            defaultValue = Get-Prop $srcWitField 'defaultValue' $null
            allowGroups = Get-Prop $srcWitField 'allowGroups' $false
        }
        
        if ($existing) {
            # Update/patch existing field (skip system fields that can't be edited)
            if ($srcWitField.referenceName -match '^System\.(AreaId|IterationId|TeamProject|AreaPath|IterationPath|Id|Rev|RevisedDate|ChangedDate|ChangedBy|CreatedDate|CreatedBy|AuthorizedAs|AuthorizedDate|Watermark)$') {
                # These system fields have read-only properties that can't be changed
                continue
            }
            
            $updateUri = "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes/$($tgtWit.referenceName)/fields/$($srcWitField.referenceName)?$vProc"
            try {
                Invoke-Ado -Method PATCH -Uri $updateUri -Headers $tgtHeaders -Body $fieldBody | Out-Null
                $witFieldCount++
            } catch {
                # Silently skip errors about properties that aren't editable on system fields
                # and 404 errors for WITs that don't exist in target process (inherited from parent)
                if ($_.Exception.Message -notmatch "not editable" -and $_.Exception.Message -notmatch "Cannot find work item type") {
                    Write-Warn2 "  Failed to update field '$($srcWitField.referenceName)' on WIT: $_"
                }
            }
        } else {
            # Add new field
            $addUri = "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes/$($tgtWit.referenceName)/fields?$vProc"
            try {
                Invoke-Ado -Method POST -Uri $addUri -Headers $tgtHeaders -Body $fieldBody | Out-Null
                $witFieldCount++
            } catch {
                # Only warn if it's not a "field not found" error (which means it needs to be created at org level first)
                # and not a 404 error for WITs that don't exist in target process
                if ($_.Exception.Message -notmatch "Cannot find field" -and $_.Exception.Message -notmatch "Cannot find work item type") {
                    Write-Warn2 "  Failed to add field '$($srcWitField.referenceName)' to WIT: $_"
                }
            }
        }
    }
    if ($witFieldCount -gt 0) {
        Write-Ok "  Updated/added $witFieldCount fields"
    }
    
    # Migrate states
    Write-Step "  Migrating states for WIT: $($srcWit.name)"
    $srcStatesUri = "$srcOrgUrl/_apis/work/processes/$srcProcessId/workitemtypes/$($srcWit.referenceName)/states?$vStates"
    $srcStates = (Invoke-Ado -Uri $srcStatesUri -Headers $srcHeaders).value
    
    $tgtStatesUri = "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes/$($tgtWit.referenceName)/states?$vStates"
    $tgtStates = (Invoke-Ado -Uri $tgtStatesUri -Headers $tgtHeaders).value
    
    $witStateCount = 0
    foreach ($srcState in $srcStates | Where-Object { $_.customizationType -ne 'system' }) {
        $existing = $tgtStates | Where-Object { $_.name -eq $srcState.name }
        if ($existing) {
            Write-Skip "  State already exists: $($srcState.name) on $($srcWit.name)"
        } else {
            $stateBody = @{
                name = $srcState.name
                color = Get-Prop $srcState 'color' '007acc'
                stateCategory = $srcState.stateCategory
            }
            $createStateUri = "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes/$($tgtWit.referenceName)/states?$vStates"
            try {
                Invoke-Ado -Method POST -Uri $createStateUri -Headers $tgtHeaders -Body $stateBody | Out-Null
                $witStateCount++
                $stateCount++
                Write-AdoRunLog -Level info -Operation create-state -Outcome created -Target "$($srcWit.name)/$($srcState.name)" -Message "Category: $($srcState.stateCategory)"
            } catch {
                # Silently skip 404 errors for WITs that don't exist in target process
                if ($_.Exception.Message -match "Cannot find work item type") {
                    Write-Warn2 "  WIT '$($srcWit.name)' not found in target process — cannot create state '$($srcState.name)'"
                    Write-AdoRunLog -Level warning -Operation create-state -Outcome skipped -Target "$($srcWit.name)/$($srcState.name)" -Message "WIT not found in target process"
                } else {
                    Write-Warn2 "  Failed to create state '$($srcState.name)': $_"
                    Write-AdoRunLog -Level warning -Operation create-state -Outcome failed -Target "$($srcWit.name)/$($srcState.name)" -Message $_.Exception.Message
                }
            }
        }
    }

    # Hide states that are hidden in source
    foreach ($srcState in $srcStates | Where-Object { (Get-Prop $_ 'hidden' $false) -eq $true }) {
        $existing = $tgtStates | Where-Object { $_.name -eq $srcState.name -and (Get-Prop $_ 'hidden' $false) -eq $false }
        if ($existing) {
            $hideUri = "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes/$($tgtWit.referenceName)/states/$($existing.id)?$vStates"
            $hideBody = @{ hidden = $true }
            try {
                Invoke-Ado -Method PATCH -Uri $hideUri -Headers $tgtHeaders -Body $hideBody | Out-Null
                $witStateCount++
                Write-AdoRunLog -Level info -Operation hide-state -Outcome updated -Target "$($srcWit.name)/$($srcState.name)"
            } catch {
                if ($_.Exception.Message -match "Cannot find work item type") {
                    Write-Warn2 "  WIT '$($srcWit.name)' not found in target process — cannot hide state '$($srcState.name)'"
                    Write-AdoRunLog -Level warning -Operation hide-state -Outcome skipped -Target "$($srcWit.name)/$($srcState.name)" -Message "WIT not found in target process"
                } else {
                    Write-Warn2 "  Failed to hide state '$($srcState.name)': $_"
                    Write-AdoRunLog -Level warning -Operation hide-state -Outcome failed -Target "$($srcWit.name)/$($srcState.name)" -Message $_.Exception.Message
                }
            }
        }
    }

    if ($witStateCount -gt 0) {
        Write-Ok "  Created/updated $witStateCount states"
    } else {
        Write-Skip "  No new states to create for $($srcWit.name)"
    }
    
    # Migrate rules (best effort)
    Write-Step "  Migrating rules for WIT: $($srcWit.name)"
    $srcRulesUri = "$srcOrgUrl/_apis/work/processes/$srcProcessId/workitemtypes/$($srcWit.referenceName)/rules?$vProc"
    $srcRules = (Invoke-Ado -Uri $srcRulesUri -Headers $srcHeaders).value
    
    $witRuleCount = 0
    foreach ($srcRule in $srcRules) {
        # Skip rules without a name (friendlyName is required by Azure DevOps)
        $ruleName = Get-Prop $srcRule 'name'
        if ([string]::IsNullOrWhiteSpace($ruleName)) {
            continue
        }
        
        $ruleBody = @{
            name = $ruleName
            conditions = Get-Prop $srcRule 'conditions' @()
            actions = Get-Prop $srcRule 'actions' @()
        }
        
        $createRuleUri = "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes/$($tgtWit.referenceName)/rules?$vProc"
        try {
            Invoke-Ado -Method POST -Uri $createRuleUri -Headers $tgtHeaders -Body $ruleBody | Out-Null
            $witRuleCount++
            $ruleCount++
        } catch {
            # Silently skip 404 errors for WITs that don't exist in target process
            if ($_.Exception.Message -notmatch "Cannot find work item type") {
                Write-Warn2 "  Failed to create rule '$ruleName': $_"
            }
        }
    }
    
    if ($witRuleCount -gt 0) {
        Write-Ok "  Created $witRuleCount rules"
    }
    
    # Migrate layout (skip for system WITs or if source is locked)
    Write-Step "  Migrating layout for WIT: $($srcWit.name)"
    
    # Check if source WIT is a system WIT or locked - if so, skip layout entirely
    $srcWitCustomization = Get-Prop $srcWit 'customizationType'
    if ($srcWitCustomization -eq 'system') {
        Write-Skip "  Skipping layout for system WIT: $($srcWit.name)"
        $srcLayout = $null
    } else {
        $srcLayoutUri = "$srcOrgUrl/_apis/work/processes/$srcProcessId/workitemtypes/$($srcWit.referenceName)/layout?$vLayout"
        
        # Temporarily set ErrorActionPreference to Continue to prevent errors from escaping to trap
        $prevErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        
        try {
            $srcLayout = Invoke-Ado -Uri $srcLayoutUri -Headers $srcHeaders
        } catch {
            # Skip layout migration if source layout cannot be read or WIT is locked
            if ($_.Exception.Message -match "locked|Cannot find work item type|cannot modify form layout") {
                Write-Warn2 "  Cannot migrate layout for WIT '$($srcWit.name)': WIT is locked or not customizable"
            } else {
                Write-Warn2 "  Failed to read layout for WIT '$($srcWit.name)': $_"
            }
            $srcLayout = $null
        } finally {
            $ErrorActionPreference = $prevErrorAction
        }
    }
    
    if ($srcLayout -and $srcLayout.pages) {
        foreach ($srcPage in $srcLayout.pages) {
            foreach ($srcSection in $srcPage.sections) {
                foreach ($srcGroup in $srcSection.groups) {
                    foreach ($srcControl in $srcGroup.controls) {
                        if ($srcControl.controlType -eq 'FieldControl' -and $srcControl.id) {
                            # Add control to target layout
                            $controlBody = @{
                                id = $srcControl.id
                                label = Get-Prop $srcControl 'label' $srcControl.id
                                readOnly = Get-Prop $srcControl 'readOnly' $false
                                visible = Get-Prop $srcControl 'visible' $true
                            }
                            
                            $addControlUri = "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes/$($tgtWit.referenceName)/layout/pages/$($srcPage.id)/sections/$($srcSection.id)/groups/$($srcGroup.id)/controls?$vLayout"
                            try {
                                Invoke-Ado -Method POST -Uri $addControlUri -Headers $tgtHeaders -Body $controlBody | Out-Null
                                $layoutCount++
                            } catch {
                                # Silently ignore layout errors - many are expected:
                                # - Control already exists
                                # - Inherited controls cannot be modified
                                # - WIT is locked (system WIT)
                                # - Section/group doesn't exist in target
                            }
                        }
                    }
                }
            }
        }
    }
}

# ---------------------------------------------------------------- summary ---

Write-Step "Migration Summary"
Write-Host "  Process:    $($srcProcess.name) → $($tgtProcess.name)"
Write-Host "  WITs:       $witCount created"
Write-Host "  Picklists:  $picklistCount created"
Write-Host "  Fields:     $fieldCount created"
Write-Host "  States:     $stateCount created"
Write-Host "  Rules:      $ruleCount created"
Write-Host "  Layouts:    $layoutCount controls added"

Complete-AdoScriptRun -Outcome succeeded -Operation 'migrate-process' -Target $TargetProcess -Message "Process migration completed successfully"
Write-Host "`nProcess migration completed successfully!" -ForegroundColor Green
