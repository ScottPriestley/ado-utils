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

.EXAMPLE
    .\ado-migrate-process.ps1 -SourceOrganization 'source-org' -SourceProcess 'My Process' `
        -TargetOrganization 'target-org' -TargetProcess 'My Process' `
        -TargetProject 'MyProject' -ProcessMode AssistedManual
    # Migrates the process and checks whether the target project already uses
    # it; Azure DevOps has no REST API to switch an existing project's process
    # (or create one against an existing project), so the script prints manual
    # instructions and exits 3 if a person still needs to create or switch
    # 'MyProject'. Rerun the same command once that's done. This is the
    # default mode when -ProcessMode is omitted.

.EXAMPLE
    .\ado-migrate-process.ps1 -SourceOrganization 'source-org' -SourceProcess 'My Process' `
        -TargetOrganization 'target-org' -TargetProcess 'My Process' `
        -TargetProject 'MyProject' -ProcessMode FullAuto
    # Migrates the process, creates a brand-new project named 'MyProject' via
    # the REST API already on that process (private visibility, Git version
    # control), then migrates WITs/fields/states/rules/layout onto it in the
    # same run. Only use this when the customer has granted API access to
    # create projects in their target organization.

.EXAMPLE
    .\ado-migrate-process.ps1 -SourceOrganization 'source-org' -SourceProcess 'My Process' `
        -ProcessMode ExportOnly
    # Makes no API calls to a target organization at all. Reads the source
    # process definition and writes it to a JSON file under -LogDirectory for
    # hand-off to the customer's own Azure DevOps admin.
#>
[CmdletBinding()]
param(
    [string]$SourceOrganization,
    [string]$SourceProcess,
    [SecureString]$SourcePat,
    [string]$TargetOrganization,
    [string]$TargetProcess,
    [SecureString]$TargetPat,
    [string]$TargetProject,
    [string]$LogDirectory,
    [switch]$NonInteractive,
    # FullAuto: create the process AND a brand-new target project via API, then
    #   continue straight into migration in this run (requires -TargetProject).
    # AssistedManual (default): create the process via API, then stop for a
    #   person to create or switch the target project, and rerun.
    # ExportOnly: make zero API calls to the target org; write the source
    #   process definition to a local JSON file instead.
    [ValidateSet('FullAuto', 'AssistedManual', 'ExportOnly')]
    [string]$ProcessMode = 'AssistedManual'
)

$ErrorActionPreference = 'Stop'
# Explicit, not incidental: Set-StrictMode is scope-inherited from whatever
# calls this script. Run standalone it's Off (PowerShell's default); run
# through ado-project-setup-runner.ps1 (which sets -Version Latest) it's
# silently ON in this script too, via `& $command` creating a child scope of
# the runner's. That mismatch is why "$hideUri cannot be retrieved because it
# has not been set" only ever reproduced through the launcher, never in a
# standalone run or a static read of this file. Fixing it here makes this
# script's behavior the same regardless of caller.
Set-StrictMode -Off
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap {
    $location = if ($_.InvocationInfo) { " at line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" } else { '' }
    $detail = "$($_.Exception.Message)$location"
    Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'migrate-process' -Message $detail
    throw
}

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

# Exit codes used to tell a calling launcher "stopped cleanly, not a failure" --
# distinct from 0 (fully done) and a thrown error (genuinely failed). See
# ado-project-setup-runner.ps1's 'process' case.
# 3 = AssistedManual paused: a person needs to create/switch the target
#     project, then rerun this same step to finish.
# 4 = ExportOnly finished: the process definition was written to a file and no
#     target-org calls were made at all; there is nothing to rerun in this
#     session -- a fresh run happens later once the target project exists.
$script:ExitCodeActionRequired = 3
$script:ExitCodeExported = 4

function New-AdoProject {
    <#
    Creates a brand-new Azure DevOps project already on the given process
    (Mode FullAuto only -- there is no API to change an EXISTING project's
    process, only to create a new one already on the desired process).
    Polls the resulting async operation until it succeeds, fails, or times out.
    #>
    param(
        [Parameter(Mandatory)][string]$OrgUrl,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$ProjectName,
        [Parameter(Mandatory)][string]$ProcessTypeId,
        [string]$Visibility = 'private',
        [string]$SourceControlType = 'Git',
        [int]$PollIntervalSeconds = 5,
        [int]$PollTimeoutSeconds = 300
    )
    $createBody = @{
        name = $ProjectName
        visibility = $Visibility
        capabilities = @{
            versioncontrol  = @{ sourceControlType = $SourceControlType }
            processTemplate = @{ templateTypeId = $ProcessTypeId }
        }
    }
    $createUri = "$OrgUrl/_apis/projects?api-version=7.2-preview.4"
    $operation = Invoke-Ado -Method POST -Uri $createUri -Headers $Headers -Body $createBody

    $opUri = "$OrgUrl/_apis/operations/$($operation.id)?api-version=7.1"
    $elapsed = 0
    $opStatus = $operation
    while ($opStatus.status -notin @('succeeded', 'failed', 'cancelled')) {
        if ($elapsed -ge $PollTimeoutSeconds) {
            throw "Timed out waiting for project '$ProjectName' creation to complete (last status: $($opStatus.status))."
        }
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
        $opStatus = Invoke-Ado -Uri $opUri -Headers $Headers
    }
    if ($opStatus.status -ne 'succeeded') {
        throw "Project '$ProjectName' creation ended with status '$($opStatus.status)'. $(Get-Prop $opStatus 'resultMessage' '')"
    }
    Write-AdoRunLog -Level info -Operation create-project -Outcome created -Target $ProjectName -Message "Process: $ProcessTypeId; visibility: $Visibility; source control: $SourceControlType"
    $opStatus
}

function Export-AdoProcessDefinition {
    <#
    Reads the full source process definition -- the same data the migration
    loop below already reads from source before POSTing it to target -- and
    serializes it to one JSON file instead (Mode ExportOnly). No target-org
    calls are made. The shape mirrors the actual create/update request bodies
    this script builds (createWitBody/stateBody/ruleBody/controlBody) rather
    than a loose summary, so a future "import from file" mode could replay it
    with minimal transformation.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceOrgUrl,
        [Parameter(Mandatory)][hashtable]$SourceHeaders,
        [Parameter(Mandatory)]$SourceProcess,
        [Parameter(Mandatory)][string]$SourceProcessId,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$ProcessName
    )
    Write-Step "Reading source process definition for export"

    $witsUri = "$SourceOrgUrl/_apis/work/processes/$SourceProcessId/workitemtypes?`$expand=all&$vProc"
    $wits = (Invoke-Ado -Uri $witsUri -Headers $SourceHeaders).value
    Write-Ok "Read $($wits.Count) work item types"

    $picklistsUri = "$SourceOrgUrl/_apis/work/processes/lists?$vLists"
    $picklists = (Invoke-Ado -Uri $picklistsUri -Headers $SourceHeaders).value | Where-Object { -not $_.isSuggested }
    Write-Ok "Read $(@($picklists).Count) picklists"

    $fieldsUri = "$SourceOrgUrl/_apis/wit/fields?$vFields"
    $fields = (Invoke-Ado -Uri $fieldsUri -Headers $SourceHeaders).value | Where-Object {
        (Get-Prop $_ 'isIdentity' $false) -eq $false -and (Get-Prop $_ 'type') -ne 'html'
    }
    Write-Ok "Read $(@($fields).Count) organization-level fields"

    $witDetails = @()
    foreach ($wit in $wits) {
        $witFieldsUri = "$SourceOrgUrl/_apis/work/processes/$SourceProcessId/workitemtypes/$($wit.referenceName)/fields?$vProc"
        $statesUri    = "$SourceOrgUrl/_apis/work/processes/$SourceProcessId/workitemtypes/$($wit.referenceName)/states?$vStates"
        $rulesUri     = "$SourceOrgUrl/_apis/work/processes/$SourceProcessId/workitemtypes/$($wit.referenceName)/rules?$vProc"

        $layout = $null
        if ((Get-Prop $wit 'customizationType') -ne 'system') {
            $layoutUri = "$SourceOrgUrl/_apis/work/processes/$SourceProcessId/workitemtypes/$($wit.referenceName)/layout?$vLayout"
            try { $layout = Invoke-Ado -Uri $layoutUri -Headers $SourceHeaders } catch { $layout = $null }
        }

        $witDetails += [ordered]@{
            referenceName      = $wit.referenceName
            name               = $wit.name
            description        = Get-Prop $wit 'description' ''
            color              = Get-Prop $wit 'color' ''
            icon               = Get-Prop $wit 'icon' ''
            inherits           = Get-Prop $wit 'inherits' $null
            customizationType  = Get-Prop $wit 'customizationType' ''
            fields             = (Invoke-Ado -Uri $witFieldsUri -Headers $SourceHeaders).value
            states             = (Invoke-Ado -Uri $statesUri -Headers $SourceHeaders).value
            rules              = (Invoke-Ado -Uri $rulesUri -Headers $SourceHeaders).value
            layout             = $layout
        }
    }
    Write-Ok "Read field/state/rule/layout detail for $($witDetails.Count) work item types"

    $export = [ordered]@{
        schemaVersion      = 1
        exportedUtc        = [DateTime]::UtcNow.ToString('o')
        sourceProcess      = [ordered]@{
            name              = $SourceProcess.name
            typeId            = $SourceProcessId
            customizationType = Get-Prop $SourceProcess 'customizationType' ''
        }
        picklists          = $picklists
        organizationFields = $fields
        workItemTypes      = $witDetails
    }

    $safeName = ($ProcessName -replace '[\\/:*?"<>|]', '_')
    $fileName = 'process-export-{0}-{1}.json' -f $safeName, (Get-Date -Format 'yyyyMMdd-HHmmss')
    [IO.Directory]::CreateDirectory($LogDirectory) | Out-Null
    $exportPath = Join-Path $LogDirectory $fileName
    ($export | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $exportPath -Encoding utf8
    $exportPath
}

function Complete-AdoActionRequired {
    <#
    Prints a numbered manual-step banner, logs it, marks the run as a clean
    (non-failure) stop, and exits with the AssistedManual sentinel (3).
    #>
    param(
        [Parameter(Mandatory)][string]$HeaderLine,
        [Parameter(Mandatory)][string[]]$InstructionLines,
        [Parameter(Mandatory)][string]$LogMessage,
        [Parameter(Mandatory)][string]$CompletionMessage,
        [Parameter(Mandatory)][string]$Target
    )
    Write-Host ''
    Write-Host '=================================================================' -ForegroundColor Yellow
    Write-Host " $HeaderLine" -ForegroundColor Yellow
    Write-Host '=================================================================' -ForegroundColor Yellow
    foreach ($line in $InstructionLines) {
        if ([string]::IsNullOrEmpty($line)) { Write-Host '' } else { Write-Host " $line" -ForegroundColor Yellow }
    }
    Write-Host '=================================================================' -ForegroundColor Yellow
    Write-AdoRunLog -Level warning -Operation check-project-process -Outcome action-required -Target $Target -Message $LogMessage
    Complete-AdoScriptRun -Outcome succeeded -Operation 'migrate-process' -Target $Target -Message $CompletionMessage
    exit $script:ExitCodeActionRequired
}

function Resolve-AdoAssistedManualProject {
    <#
    The AssistedManual check-and-stop logic: is the target project missing,
    on the wrong process, or already correct? Exits the script (via
    Complete-AdoActionRequired) for the first two cases; returns normally
    (falling through to migration) for the last. Also used by FullAuto as a
    forgiving fallback when the target project already exists (e.g. a rerun
    after a prior partial FullAuto run).
    #>
    param(
        [Parameter(Mandatory)][string]$ProjectsUri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)]$TgtProcess,
        [Parameter(Mandatory)][string]$TgtProcessId,
        [Parameter(Mandatory)][string]$TargetProject
    )
    $targetProjectObj = $null
    try {
        $targetProjectObj = Invoke-Ado -Uri $ProjectsUri -Headers $Headers -AllowNotFound
    } catch {
        Write-Warn2 "Failed to check target project process: $_"
        Write-AdoRunLog -Level warning -Operation check-project-process -Outcome failed -Target $TargetProject -Message $_.Exception.Message
        return
    }

    if ($null -eq $targetProjectObj) {
        Complete-AdoActionRequired -Target $TargetProject `
            -HeaderLine 'ACTION NEEDED -- one manual step, then run this again' `
            -InstructionLines @(
                "The process '$($TgtProcess.name)' now exists in the target organization.",
                "Project '$TargetProject' does not exist yet, and only a person can create it",
                '(Azure DevOps does not allow project creation on this process over the API',
                'in this mode):',
                '',
                "  1. In Azure DevOps, create a new project named '$TargetProject'",
                "  2. When prompted for a process, choose '$($TgtProcess.name)'",
                '',
                'Once that is done, run this step again to migrate work item types,',
                'fields, states, rules, and layout onto the new project.'
            ) `
            -LogMessage "Process '$($TgtProcess.name)' created; project '$TargetProject' does not exist yet. Create it manually, then rerun." `
            -CompletionMessage "Process '$($TgtProcess.name)' created. Waiting for '$TargetProject' to be created manually before WITs/fields/states are migrated."
        return
    }

    $currentProcessId = $targetProjectObj.capabilities.processTemplate.templateTypeId
    if ($currentProcessId -eq $TgtProcessId) {
        Write-Skip "Project '$TargetProject' already uses process '$($TgtProcess.name)'"
        return
    }

    Complete-AdoActionRequired -Target $TargetProject `
        -HeaderLine 'ACTION NEEDED -- one manual step, then run this again' `
        -InstructionLines @(
            "The process '$($TgtProcess.name)' now exists in the target organization.",
            "Project '$TargetProject' is still using a different process, and only",
            'a person can switch it (Azure DevOps does not allow this over the API):',
            '',
            '  1. In Azure DevOps, go to Organization Settings > Process',
            "  2. Select the process '$($TgtProcess.name)'",
            "  3. Open its Projects tab and add '$TargetProject'",
            '',
            'Once that is done, run this step again to migrate work item types,',
            'fields, states, rules, and layout onto the new process.'
        ) `
        -LogMessage "Process '$($TgtProcess.name)' created; project still on process ID $currentProcessId. Switch it manually, then rerun." `
        -CompletionMessage "Process '$($TgtProcess.name)' created. Waiting for '$TargetProject' to be switched to it manually before WITs/fields/states are migrated."
}

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

# ---------------------------------------------------------------- export-only mode ---
# ExportOnly makes NO calls to the target organization at all -- gate here,
# before the target process lookup/creation below, which is the first target
# call in the script.

if ($ProcessMode -eq 'ExportOnly') {
    Write-Step "Export mode: no changes will be made in the target organization"
    $logDirectory = Split-Path -Parent $adoRun.SuccessLogPath
    $exportPath = Export-AdoProcessDefinition -SourceOrgUrl $srcOrgUrl -SourceHeaders $srcHeaders `
        -SourceProcess $srcProcess -SourceProcessId $srcProcessId -LogDirectory $logDirectory -ProcessName $SourceProcess
    Write-Ok "Process definition exported to: $exportPath"
    Write-AdoRunLog -Level info -Operation export-process -Outcome exported -Target $SourceProcess -Message "Exported to $exportPath"
    Complete-AdoScriptRun -Outcome succeeded -Operation 'migrate-process' -Target $SourceProcess `
        -Message "Process '$SourceProcess' exported to $exportPath. No target-organization changes were made; hand this file to the customer's Azure DevOps admin, then run project setup again once the target project exists."
    Write-Host "`nProcess definition exported: $exportPath" -ForegroundColor Green
    exit $script:ExitCodeExported
}

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

# Apply process to target project according to -ProcessMode
#
# NOTE: Azure DevOps does not expose changing an existing project's process
# through the public REST API. The Projects - Update endpoint
# (PATCH _apis/projects/{projectId}) is documented as supporting only name,
# abbreviation, description, or restore -- attempting to PATCH
# capabilities.processTemplate.templateTypeId on an existing project fails
# with HTTP 400 "The project update is invalid." Switching a project's
# process is a UI-only operation (Organization Settings > Process). Creating a
# BRAND NEW project already on a given process IS supported via the API
# (Projects - Create, capabilities.processTemplate.templateTypeId) -- that is
# what FullAuto mode uses below.
# See: https://learn.microsoft.com/azure/devops/organizations/settings/work/manage-process

if ($ProcessMode -eq 'FullAuto' -and [string]::IsNullOrWhiteSpace($TargetProject)) {
    throw "TargetProject is required when -ProcessMode FullAuto is used (the project name is needed to create it)."
}

if (-not [string]::IsNullOrWhiteSpace($TargetProject)) {
    Write-Step "Checking target project '$TargetProject'"
    $projectsUri = "$tgtOrgUrl/_apis/projects/$TargetProject`?includeCapabilities=true&api-version=7.1"

    if ($ProcessMode -eq 'FullAuto') {
        $existingProject = $null
        try {
            $existingProject = Invoke-Ado -Uri $projectsUri -Headers $tgtHeaders -AllowNotFound
        } catch {
            Write-Warn2 "Failed to check whether target project already exists: $_"
            Write-AdoRunLog -Level warning -Operation check-project-exists -Outcome failed -Target $TargetProject -Message $_.Exception.Message
        }
        if ($null -eq $existingProject) {
            Write-Step "Creating target project '$TargetProject'"
            New-AdoProject -OrgUrl $tgtOrgUrl -Headers $tgtHeaders -ProjectName $TargetProject -ProcessTypeId $tgtProcessId -Visibility 'private' -SourceControlType 'Git' | Out-Null
            Write-Ok "Created project '$TargetProject' on process '$($tgtProcess.name)'"
        } else {
            # Project already exists -- likely a rerun after a prior partial FullAuto
            # run. Fall back to the same check-and-continue logic AssistedManual uses
            # rather than failing outright, so a rerun after a network blip is
            # forgiving.
            Resolve-AdoAssistedManualProject -ProjectsUri $projectsUri -Headers $tgtHeaders `
                -TgtProcess $tgtProcess -TgtProcessId $tgtProcessId -TargetProject $TargetProject
        }
    } else {
        Resolve-AdoAssistedManualProject -ProjectsUri $projectsUri -Headers $tgtHeaders `
            -TgtProcess $tgtProcess -TgtProcessId $tgtProcessId -TargetProject $TargetProject
    }
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
    
    # Ensure we have a valid target WIT with referenceName before attempting state migration
    if (-not $tgtWit -or -not $tgtWit.referenceName) {
        Write-Warn2 "  Cannot migrate states - target WIT not properly initialized"
        Write-AdoRunLog -Level warning -Operation migrate-states -Outcome skipped -Target $srcWit.name -Message "Target WIT not properly initialized"
        continue
    }
    
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
        $existing = $tgtStates | Where-Object { $_.name -eq $srcState.name -and (Get-Prop $_ 'hidden' $false) -eq $false } | Select-Object -First 1

        if ($existing -and $existing.id -and $tgtWit -and $tgtWit.referenceName) {
            try {
                $hideBody = @{ hidden = $true }
                Invoke-Ado -Method PATCH -Uri "$tgtOrgUrl/_apis/work/processes/$tgtProcessId/workitemtypes/$($tgtWit.referenceName)/states/$($existing.id)?$vStates" -Headers $tgtHeaders -Body $hideBody | Out-Null
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
