<#
.SYNOPSIS
    Migrates an Azure DevOps inherited-process Work Item Type — including its
    custom fields, picklists, states, rules, and form layout placement — from
    one process to another, within the same organization or across two.

.DESCRIPTION
    Prompts for (or accepts as parameters) the Work Item Type name, source
    organization / process / PAT, and target organization / process / PAT.

    What it migrates:
      1. The Work Item Type itself (custom WIT created; system WIT derived).
      2. Picklists backing any custom picklist fields (reused by name if one
         already exists in the target organization).
      3. Org-level custom field definitions (created only if missing).
      4. Field membership on the WIT (required / default / allow-groups /
         read-only settings; existing fields are patched to match).
      5. Custom states, and hiding of inherited states hidden in the source.
      6. Custom rules (best-effort — a rule referencing something that does
         not exist in the target is logged and skipped).
      7. Form layout: pages, groups, and controls for the migrated fields,
         so the fields actually appear on the work item form.

    Not migrated: backlog-level/behavior assignments, extension (contribution)
    controls, and system-process content. Both PATs need "Work Items
    (Read/Write)" plus "Process (Read & Write)"; creating org-level fields in
    the target requires Project Collection Administrator (or "Create process"
    / field-create permission).

    The script is idempotent — already-existing items are detected and
    skipped or updated, so it is safe to re-run after fixing a failure.

.EXAMPLE
    .\Migrate-AzureDevOpsWorkItemType.ps1
    # Prompts interactively for all seven inputs.

.EXAMPLE
    .\Migrate-AzureDevOpsWorkItemType.ps1 -WorkItemTypeName 'Business Process' `
        -SourceOrganization 'hsouscloud' -SourceProcess 'HSO-Navigate-CMMI' `
        -TargetOrganization 'hsouscloud' -TargetProcess 'HSO-Navigate-Agile-2026-07'
    # Prompts only for the two PATs.
#>
[CmdletBinding()]
param(
    [string]$WorkItemTypeName,
    [string]$SourceOrganization,
    [string]$SourceProcess,
    [SecureString]$SourcePat,
    [string]$TargetOrganization,
    [string]$TargetProcess,
    [SecureString]$TargetPat
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- helpers ---

function Get-PlainText([SecureString]$SecureValue) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Resolve-OrgUrl([string]$Org) {
    $Org = $Org.Trim().TrimEnd('/')
    if ($Org -match '^https?://') { return $Org }
    return "https://dev.azure.com/$Org"
}

function New-AuthHeader([SecureString]$Pat) {
    $plain = Get-PlainText $Pat
    @{
        Authorization  = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $plain))
        Accept         = 'application/json'
        'Content-Type' = 'application/json'
    }
}

# Safe property access (JSON payloads vary by API version)
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
    if ($null -ne $Body) { $params.Body = ($Body | ConvertTo-Json -Depth 20) }
    try {
        $resp = Invoke-WebRequest @params
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

if (-not $WorkItemTypeName)   { $WorkItemTypeName   = Read-Host 'Work Item Type name (as shown in the process, e.g. "Business Process")' }
if (-not $SourceOrganization) { $SourceOrganization = Read-Host 'SOURCE organization (name or https://dev.azure.com/<org>)' }
if (-not $SourceProcess)      { $SourceProcess      = Read-Host 'SOURCE process name' }
if (-not $SourcePat)          { $SourcePat          = Read-Host 'SOURCE PAT (Work Items + Process read/write)' -AsSecureString }
if (-not $TargetOrganization) { $TargetOrganization = Read-Host 'TARGET organization (name or https://dev.azure.com/<org>)' }
if (-not $TargetProcess)      { $TargetProcess      = Read-Host 'TARGET process name' }
if (-not $TargetPat) {
    $sameOrg = (Resolve-OrgUrl $SourceOrganization) -eq (Resolve-OrgUrl $TargetOrganization)
    if ($sameOrg) {
        $reuse = Read-Host 'TARGET PAT — press Enter to reuse the source PAT (same org), or type N to enter a different one'
        if ($reuse -match '^[nN]') { $TargetPat = Read-Host 'TARGET PAT' -AsSecureString } else { $TargetPat = $SourcePat }
    }
    else { $TargetPat = Read-Host 'TARGET PAT (Work Items + Process read/write)' -AsSecureString }
}

$srcBase = Resolve-OrgUrl $SourceOrganization
$tgtBase = Resolve-OrgUrl $TargetOrganization
$srcH = New-AuthHeader $SourcePat
$tgtH = New-AuthHeader $TargetPat

$summary = [ordered]@{
    Picklists = 0; OrgFields = 0; WitFields = 0; States = 0; Rules = 0; Controls = 0; Warnings = 0
}
function Add-Warn([string]$Message) { Write-Warn2 $Message; $script:summary.Warnings++ }

# ------------------------------------------------------ resolve processes ---

Write-Step "Resolving processes"

$srcProcs = (Invoke-Ado -Uri "$srcBase/_apis/work/processes?$vProc" -Headers $srcH).value
$srcProc = $srcProcs | Where-Object { $_.name -ieq $SourceProcess }
if (-not $srcProc) { throw "Source process '$SourceProcess' not found in $srcBase. Available: $(($srcProcs.name | Sort-Object) -join ', ')" }

$tgtProcs = (Invoke-Ado -Uri "$tgtBase/_apis/work/processes?$vProc" -Headers $tgtH).value
$tgtProc = $tgtProcs | Where-Object { $_.name -ieq $TargetProcess }
if (-not $tgtProc) { throw "Target process '$TargetProcess' not found in $tgtBase. Available: $(($tgtProcs.name | Sort-Object) -join ', ')" }

if ((Get-Prop $tgtProc 'customizationType') -ieq 'system') {
    throw "Target process '$($tgtProc.name)' is a system process and cannot be customized. Create an inherited process from it first."
}
Write-Ok "Source: $($srcProc.name) [$($srcProc.typeId)]"
Write-Ok "Target: $($tgtProc.name) [$($tgtProc.typeId)]"

$srcProcUri = "$srcBase/_apis/work/processes/$($srcProc.typeId)"
$tgtProcUri = "$tgtBase/_apis/work/processes/$($tgtProc.typeId)"

# ----------------------------------------------- resolve / create the WIT ---

Write-Step "Resolving work item type '$WorkItemTypeName'"

$srcWits = (Invoke-Ado -Uri "$srcProcUri/workitemtypes?$vProc" -Headers $srcH).value
$srcWit = $srcWits | Where-Object { $_.name -ieq $WorkItemTypeName }
if (-not $srcWit) { throw "Work item type '$WorkItemTypeName' not found in source process. Available: $(($srcWits.name | Sort-Object) -join ', ')" }
$srcCustomization = Get-Prop $srcWit 'customization'
Write-Ok "Source WIT: $($srcWit.referenceName) (customization: $srcCustomization)"
if ($srcCustomization -ieq 'system') {
    Add-Warn "Source WIT is an unmodified system type — there is no custom content to migrate. Continuing anyway."
}

$tgtWits = (Invoke-Ado -Uri "$tgtProcUri/workitemtypes?$vProc" -Headers $tgtH).value
$tgtWit = $tgtWits | Where-Object { $_.name -ieq $srcWit.name }

if (-not $tgtWit) {
    if ($srcCustomization -ieq 'custom') {
        $body = @{
            name        = $srcWit.name
            description = Get-Prop $srcWit 'description' ''
            color       = Get-Prop $srcWit 'color'
            icon        = Get-Prop $srcWit 'icon'
            isDisabled  = [bool](Get-Prop $srcWit 'isDisabled' $false)
        }
        $tgtWit = Invoke-Ado -Method POST -Uri "$tgtProcUri/workitemtypes?$vProc" -Headers $tgtH -Body $body
        Write-Ok "Created custom WIT '$($tgtWit.name)' -> $($tgtWit.referenceName)"
    }
    else {
        # Source is a derived system type; target process lacks the base — unusual, but try deriving from the same parent.
        $body = @{
            inheritsFrom = Get-Prop $srcWit 'inherits'
            color        = Get-Prop $srcWit 'color'
            icon         = Get-Prop $srcWit 'icon'
            isDisabled   = [bool](Get-Prop $srcWit 'isDisabled' $false)
        }
        $tgtWit = Invoke-Ado -Method POST -Uri "$tgtProcUri/workitemtypes?$vProc" -Headers $tgtH -Body $body
        Write-Ok "Created inherited WIT '$($tgtWit.name)' -> $($tgtWit.referenceName)"
    }
}
elseif ((Get-Prop $tgtWit 'customization') -ieq 'system') {
    # A same-named system type exists in target — derive it so it can be customized.
    $body = @{
        inheritsFrom = $tgtWit.referenceName
        color        = Get-Prop $srcWit 'color'
        icon         = Get-Prop $srcWit 'icon'
        isDisabled   = [bool](Get-Prop $srcWit 'isDisabled' $false)
    }
    $tgtWit = Invoke-Ado -Method POST -Uri "$tgtProcUri/workitemtypes?$vProc" -Headers $tgtH -Body $body
    Write-Ok "Derived system WIT for customization -> $($tgtWit.referenceName)"
}
else {
    Write-Skip "Target WIT already exists: $($tgtWit.referenceName)"
}

$srcWitUri = "$srcProcUri/workItemTypes/$($srcWit.referenceName)"
$tgtWitUri = "$tgtProcUri/workItemTypes/$($tgtWit.referenceName)"

# ------------------------------------------------- fields and picklists -----

Write-Step "Migrating fields and picklists"

$srcWitFields = (Invoke-Ado -Uri "$srcWitUri/fields?$vProc" -Headers $srcH).value
$tgtWitFields = (Invoke-Ado -Uri "$tgtWitUri/fields?$vProc" -Headers $tgtH).value
$tgtListsCache = $null   # fetched lazily, once

$fieldsToMigrate = @($srcWitFields | Where-Object { (Get-Prop $_ 'customization') -ine 'system' })
$migratedFieldRefs = New-Object System.Collections.Generic.List[string]

foreach ($f in $fieldsToMigrate) {
    $ref = $f.referenceName
    $migratedFieldRefs.Add($ref) | Out-Null

    # 1. Ensure the org-level field definition exists in the target org.
    $tgtOrgField = Invoke-Ado -Uri "$tgtBase/_apis/wit/fields/$ref`?$vFields" -Headers $tgtH -AllowNotFound
    if (-not $tgtOrgField) {
        $srcOrgField = Invoke-Ado -Uri "$srcBase/_apis/wit/fields/$ref`?$vFields" -Headers $srcH

        $picklistId = $null
        if (Get-Prop $srcOrgField 'isPicklist' $false) {
            $srcList = Invoke-Ado -Uri "$srcBase/_apis/work/processes/lists/$(Get-Prop $srcOrgField 'picklistId')?$vLists" -Headers $srcH
            $listName = Get-Prop $srcList 'name'
            if ([string]::IsNullOrWhiteSpace($listName)) { $listName = "$ref.list" }

            if ($null -eq $tgtListsCache) {
                $tgtListsCache = @((Invoke-Ado -Uri "$tgtBase/_apis/work/processes/lists?$vLists" -Headers $tgtH).value)
            }
            $existingList = $tgtListsCache | Where-Object { $_.name -ieq $listName } | Select-Object -First 1
            if ($existingList) {
                $picklistId = $existingList.id
                $diff = Compare-Object @(Get-Prop $srcList 'items' @()) @(Get-Prop $existingList 'items' @())
                if ($diff) { Add-Warn "Picklist '$listName' already exists in target with DIFFERENT items — reusing it as-is (shared lists affect other fields; reconcile manually if needed)." }
                else { Write-Skip "Picklist '$listName' already exists in target — reusing." }
            }
            else {
                $newList = Invoke-Ado -Method POST -Uri "$tgtBase/_apis/work/processes/lists?$vLists" -Headers $tgtH -Body @{
                    name        = $listName
                    type        = Get-Prop $srcList 'type' 'String'
                    isSuggested = [bool](Get-Prop $srcList 'isSuggested' $false)
                    items       = @(Get-Prop $srcList 'items' @())
                }
                $picklistId = $newList.id
                $tgtListsCache += $newList
                $summary.Picklists++
                Write-Ok "Created picklist '$listName' ($(@(Get-Prop $srcList 'items' @()).Count) items)"
            }
        }

        $fieldBody = @{
            name          = $srcOrgField.name
            referenceName = $srcOrgField.referenceName
            type          = $srcOrgField.type
            description   = Get-Prop $srcOrgField 'description' ''
            usage         = 'workItem'
        }
        if ($picklistId) {
            $fieldBody.picklistId = $picklistId
            $fieldBody.isPicklistSuggested = [bool](Get-Prop $srcOrgField 'isPicklistSuggested' $false)
        }
        $tgtOrgField = Invoke-Ado -Method POST -Uri "$tgtBase/_apis/wit/fields?$vFields" -Headers $tgtH -Body $fieldBody
        $summary.OrgFields++
        Write-Ok "Created org-level field $ref ($($srcOrgField.type))"
    }
    else {
        $srcOrgField = Invoke-Ado -Uri "$srcBase/_apis/wit/fields/$ref`?$vFields" -Headers $srcH
        if ($tgtOrgField.type -ine $srcOrgField.type) {
            Add-Warn "Field $ref exists in target org with type '$($tgtOrgField.type)' but source is '$($srcOrgField.type)' — cannot reconcile; adding it to the WIT with the target's type."
        }
        else { Write-Skip "Org-level field $ref already exists in target." }
    }

    # 2. Ensure the field is on the target WIT with matching settings.
    $onWit = $tgtWitFields | Where-Object { $_.referenceName -ieq $ref }
    $settings = @{
        referenceName = $ref
        required      = [bool](Get-Prop $f 'required' $false)
        readOnly      = [bool](Get-Prop $f 'readOnly' $false)
    }
    $dv = Get-Prop $f 'defaultValue'
    if ($null -ne $dv) { $settings.defaultValue = $dv }
    $ag = Get-Prop $f 'allowGroups'
    if ($null -ne $ag) { $settings.allowGroups = [bool]$ag }

    if (-not $onWit) {
        try {
            Invoke-Ado -Method POST -Uri "$tgtWitUri/fields?$vProc" -Headers $tgtH -Body $settings | Out-Null
            $summary.WitFields++
            Write-Ok "Added $ref to WIT (required=$($settings.required))"
        }
        catch { Add-Warn "Could not add $ref to WIT: $_" }
    }
    else {
        $needsPatch = ([bool](Get-Prop $onWit 'required' $false) -ne $settings.required) -or
                      ([bool](Get-Prop $onWit 'readOnly' $false) -ne $settings.readOnly) -or
                      ("$(Get-Prop $onWit 'defaultValue')" -ne "$dv")
        if ($needsPatch) {
            $patch = @{}
            foreach ($k in 'required','readOnly','defaultValue','allowGroups') {
                if ($settings.ContainsKey($k)) { $patch[$k] = $settings[$k] }
            }
            try {
                Invoke-Ado -Method PATCH -Uri "$tgtWitUri/fields/$ref`?$vProc" -Headers $tgtH -Body $patch | Out-Null
                $summary.WitFields++
                Write-Ok "Updated settings for $ref on WIT"
            }
            catch { Add-Warn "Could not update $ref settings on WIT: $_" }
        }
        else { Write-Skip "$ref already on WIT with matching settings." }
    }
}
if ($fieldsToMigrate.Count -eq 0) { Write-Skip "No non-system fields on the source WIT." }

# ---------------------------------------------------------------- states ----

Write-Step "Migrating states"

$srcStates = @((Invoke-Ado -Uri "$srcWitUri/states?$vStates" -Headers $srcH).value)
$tgtStates = @((Invoke-Ado -Uri "$tgtWitUri/states?$vStates" -Headers $tgtH).value)

foreach ($s in $srcStates) {
    $existing = $tgtStates | Where-Object { $_.name -ieq $s.name }
    $custType = Get-Prop $s 'customizationType'

    if ($custType -ieq 'custom' -and -not $existing) {
        $body = @{ name = $s.name; color = Get-Prop $s 'color'; stateCategory = $s.stateCategory }
        $order = Get-Prop $s 'order'
        if ($null -ne $order) { $body.order = $order }
        try {
            $new = Invoke-Ado -Method POST -Uri "$tgtWitUri/states?$vStates" -Headers $tgtH -Body $body
            $tgtStates += $new
            $summary.States++
            Write-Ok "Created state '$($s.name)' [$($s.stateCategory)]"
        }
        catch { Add-Warn "Could not create state '$($s.name)': $_" }
    }
    elseif ($existing) {
        # Mirror hidden flag on inherited states
        if ([bool](Get-Prop $s 'hidden' $false) -and -not [bool](Get-Prop $existing 'hidden' $false)) {
            try {
                Invoke-Ado -Method PUT -Uri "$tgtWitUri/states/$($existing.id)?$vStates" -Headers $tgtH -Body @{ hidden = $true } | Out-Null
                Write-Ok "Hid inherited state '$($s.name)' to match source"
            }
            catch { Add-Warn "Could not hide state '$($s.name)': $_" }
        }
        else { Write-Skip "State '$($s.name)' already present." }
    }
}
# Warn about target states the source does not have (cannot delete inherited ones safely here)
foreach ($t in $tgtStates) {
    if (-not ($srcStates | Where-Object { $_.name -ieq $t.name }) -and -not [bool](Get-Prop $t 'hidden' $false)) {
        Add-Warn "Target has state '$($t.name)' that the source WIT does not — review manually (not auto-deleted)."
    }
}

# ----------------------------------------------------------------- rules ----

Write-Step "Migrating custom rules"

$srcRules = @((Invoke-Ado -Uri "$srcWitUri/rules?$vProc" -Headers $srcH).value) |
    Where-Object { (Get-Prop $_ 'customizationType') -ieq 'custom' }
$tgtRules = @((Invoke-Ado -Uri "$tgtWitUri/rules?$vProc" -Headers $tgtH).value)

foreach ($r in $srcRules) {
    $rName = Get-Prop $r 'name' '(unnamed rule)'
    if ($tgtRules | Where-Object { (Get-Prop $_ 'name') -ieq $rName }) {
        Write-Skip "Rule '$rName' already exists."
        continue
    }
    try {
        Invoke-Ado -Method POST -Uri "$tgtWitUri/rules?$vProc" -Headers $tgtH -Body @{
            name       = $rName
            conditions = @($r.conditions)
            actions    = @($r.actions)
            isDisabled = [bool](Get-Prop $r 'isDisabled' $false)
        } | Out-Null
        $summary.Rules++
        Write-Ok "Created rule '$rName'"
    }
    catch { Add-Warn "Could not create rule '$rName' (it may reference an identity, field, or state missing in the target): $_" }
}
if ($srcRules.Count -eq 0) { Write-Skip "No custom rules on source WIT." }

# ---------------------------------------------------------------- layout ----

Write-Step "Migrating form layout for migrated fields"

$srcLayout = Invoke-Ado -Uri "$srcWitUri/layout?$vLayout" -Headers $srcH
$tgtLayout = Invoke-Ado -Uri "$tgtWitUri/layout?$vLayout" -Headers $tgtH

# Index every control already on the target form
$tgtControlIds = New-Object System.Collections.Generic.HashSet[string]([System.StringComparer]::OrdinalIgnoreCase)
foreach ($p in @(Get-Prop $tgtLayout 'pages' @())) {
    foreach ($sec in @(Get-Prop $p 'sections' @())) {
        foreach ($g in @(Get-Prop $sec 'groups' @())) {
            foreach ($c in @(Get-Prop $g 'controls' @())) {
                $cid = Get-Prop $c 'id'
                if ($cid) { [void]$tgtControlIds.Add($cid) }
            }
        }
    }
}

foreach ($srcPage in @(Get-Prop $srcLayout 'pages' @())) {
    if ((Get-Prop $srcPage 'pageType') -ine 'custom') { continue }  # only form pages hold field controls

    $tgtPage = $null
    foreach ($srcSection in @(Get-Prop $srcPage 'sections' @())) {
        foreach ($srcGroup in @(Get-Prop $srcSection 'groups' @())) {
            # Controls in this group that belong to fields we migrated and are absent from the target form
            $wanted = @()
            foreach ($c in @(Get-Prop $srcGroup 'controls' @())) {
                $cid = Get-Prop $c 'id'
                if (-not $cid) { continue }
                if ([bool](Get-Prop $c 'isContribution' $false)) {
                    Add-Warn "Control '$(Get-Prop $c 'label')' on page '$($srcPage.label)' is an extension contribution — not migrated."
                    continue
                }
                if ($migratedFieldRefs.Contains($cid) -and -not $tgtControlIds.Contains($cid)) { $wanted += $c }
            }
            if ($wanted.Count -eq 0) { continue }

            # Ensure the page exists in the target (match by label)
            if (-not $tgtPage) {
                $tgtPage = @(Get-Prop $tgtLayout 'pages' @()) | Where-Object { $_.label -ieq $srcPage.label } | Select-Object -First 1
                if (-not $tgtPage) {
                    try {
                        $tgtPage = Invoke-Ado -Method POST -Uri "$tgtWitUri/layout/pages?$vLayout" -Headers $tgtH -Body @{
                            label    = $srcPage.label
                            pageType = 'custom'
                            visible  = [bool](Get-Prop $srcPage 'visible' $true)
                        }
                        $tgtLayout.pages += $tgtPage
                        Write-Ok "Created form page '$($srcPage.label)'"
                    }
                    catch { Add-Warn "Could not create page '$($srcPage.label)': $_"; continue }
                }
            }

            $tgtSection = @(Get-Prop $tgtPage 'sections' @()) | Where-Object { $_.id -ieq $srcSection.id } | Select-Object -First 1
            if (-not $tgtSection) { Add-Warn "Section '$($srcSection.id)' not found on target page '$($tgtPage.label)' — skipping its controls."; continue }

            # HTML (multi-line) fields live in their own group: create group with the control embedded
            $isHtmlGroup = ($wanted.Count -eq 1) -and ((Get-Prop $wanted[0] 'controlType') -ieq 'HtmlFieldControl') -and
                           (@(Get-Prop $srcGroup 'controls' @()).Count -eq 1)

            if ($isHtmlGroup) {
                $c = $wanted[0]
                try {
                    Invoke-Ado -Method POST -Uri "$tgtWitUri/layout/pages/$($tgtPage.id)/sections/$($srcSection.id)/groups?$vLayout" -Headers $tgtH -Body @{
                        label    = Get-Prop $srcGroup 'label' (Get-Prop $c 'label')
                        visible  = [bool](Get-Prop $srcGroup 'visible' $true)
                        controls = @(@{ id = $c.id; label = Get-Prop $c 'label'; visible = [bool](Get-Prop $c 'visible' $true) })
                    } | Out-Null
                    [void]$tgtControlIds.Add($c.id)
                    $summary.Controls++
                    Write-Ok "Placed HTML field $($c.id) on '$($tgtPage.label)' / $($srcSection.id)"
                }
                catch { Add-Warn "Could not place HTML field $($c.id): $_" }
                continue
            }

            # Ensure a matching group exists (by label within the same page+section)
            $tgtGroup = @(Get-Prop $tgtSection 'groups' @()) | Where-Object { (Get-Prop $_ 'label') -ieq (Get-Prop $srcGroup 'label') } | Select-Object -First 1
            if (-not $tgtGroup) {
                try {
                    $tgtGroup = Invoke-Ado -Method POST -Uri "$tgtWitUri/layout/pages/$($tgtPage.id)/sections/$($srcSection.id)/groups?$vLayout" -Headers $tgtH -Body @{
                        label   = Get-Prop $srcGroup 'label' 'Custom'
                        visible = [bool](Get-Prop $srcGroup 'visible' $true)
                    }
                    if ($null -eq (Get-Prop $tgtSection 'groups')) { $tgtSection | Add-Member -NotePropertyName groups -NotePropertyValue @() -Force }
                    $tgtSection.groups += $tgtGroup
                    Write-Ok "Created group '$(Get-Prop $srcGroup 'label')' on '$($tgtPage.label)' / $($srcSection.id)"
                }
                catch { Add-Warn "Could not create group '$(Get-Prop $srcGroup 'label')': $_"; continue }
            }

            foreach ($c in $wanted) {
                try {
                    Invoke-Ado -Method POST -Uri "$tgtWitUri/layout/groups/$($tgtGroup.id)/controls?$vLayout" -Headers $tgtH -Body @{
                        id      = $c.id
                        label   = Get-Prop $c 'label'
                        visible = [bool](Get-Prop $c 'visible' $true)
                    } | Out-Null
                    [void]$tgtControlIds.Add($c.id)
                    $summary.Controls++
                    Write-Ok "Placed $($c.id) in group '$(Get-Prop $tgtGroup 'label')'"
                }
                catch { Add-Warn "Could not place control $($c.id): $_" }
            }
        }
    }
}

# Fields migrated but still not on the form anywhere (e.g. source had them off-form): report only
foreach ($ref in $migratedFieldRefs) {
    if (-not $tgtControlIds.Contains($ref)) {
        Write-Skip "Field $ref is on the WIT but has no form control (matches source, or its placement could not be replicated)."
    }
}

# --------------------------------------------------------------- summary ----

Write-Step "Done"
Write-Host ("   Picklists created:      {0}" -f $summary.Picklists)
Write-Host ("   Org fields created:     {0}" -f $summary.OrgFields)
Write-Host ("   WIT fields added/updated: {0}" -f $summary.WitFields)
Write-Host ("   States created:         {0}" -f $summary.States)
Write-Host ("   Rules created:          {0}" -f $summary.Rules)
Write-Host ("   Form controls placed:   {0}" -f $summary.Controls)
if ($summary.Warnings -gt 0) {
    Write-Host ("   Warnings:               {0}  (review [WARN] lines above)" -f $summary.Warnings) -ForegroundColor Yellow
}
Write-Host "`nNot migrated automatically: backlog/behavior assignment (Boards > Process > Backlog levels) and extension controls." -ForegroundColor DarkGray
