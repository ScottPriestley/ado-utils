[CmdletBinding()]
param(
    [string]$SourceProjectUrl,
    [string]$TargetProjectUrl,
    [string[]]$Steps = @('team-config', 'iterations', 'areas', 'work-items', 'queries', 'dashboards', 'wiki'),
    [string]$TargetTeam,
    [string]$DefaultAreaPath,
    [string]$SourceWikiName,
    [string]$TargetWikiName,
    [string]$RunRoot,
    [string]$ProgressPath,
    [SecureString]$SourcePat,
    [SecureString]$TargetPat,
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $RunRoot -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'project-setup-runner'; throw }

# Declared before any logging can occur: Protect-TextLogFallback reads it, and under
# StrictMode an unassigned variable is fatal. Populated once the PATs resolve.
$script:LocalSecrets = @()

$script:StepCatalog = [ordered]@{
    'team-config' = [pscustomobject]@{ Number = 1; Activity = 'default-area'; Name = 'Set target team default area' }
    'iterations'  = [pscustomobject]@{ Number = 2; Activity = 'iterations'; Name = 'Copy Iteration Paths' }
    'areas'       = [pscustomobject]@{ Number = 3; Activity = 'area-paths'; Name = 'Copy Area Paths' }
    'work-items'  = [pscustomobject]@{ Number = 4; Activity = 'workitems'; Name = 'Copy all Work Items' }
    'queries'     = [pscustomobject]@{ Number = 5; Activity = 'queries'; Name = 'Copy Shared Queries' }
    'dashboards'  = [pscustomobject]@{ Number = 6; Activity = 'dashboards'; Name = 'Copy Dashboards' }
    'wiki'        = [pscustomobject]@{ Number = 7; Activity = 'wiki'; Name = 'Copy Wiki' }
}

function UrlEnc { param([Parameter(Mandatory)][string]$Value) [uri]::EscapeDataString($Value) }

function ConvertTo-AdoSafeFilePart {
    param([Parameter(Mandatory)][string]$Value)
    (($Value -replace '[\\/:*?"<>|]', '_') -replace '\s+', ' ').Trim()
}

function New-RunDirectory {
    param([Parameter(Mandatory)]$Target)
    $path = if ([string]::IsNullOrWhiteSpace($RunRoot)) {
        $base = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AdoMigrationLogs'
        $targetPart = '{0}_{1}' -f (ConvertTo-AdoSafeFilePart $Target.Org), (ConvertTo-AdoSafeFilePart $Target.Project)
        Join-Path (Join-Path $base $targetPart) (Get-Date -Format 'yyyyMMdd-HHmmss')
    } else {
        [IO.Path]::GetFullPath($RunRoot)
    }
    [IO.Directory]::CreateDirectory($path) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $path 'technical-jsonl')) | Out-Null
    $path
}

function New-StepLogPath {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$Activity,
        [Parameter(Mandatory)][string]$RunDirectory
    )
    $fileName = '{0}_{1} {2}.log' -f (ConvertTo-AdoSafeFilePart $Target.Org), (ConvertTo-AdoSafeFilePart $Target.Project), $Activity
    Join-Path $RunDirectory $fileName
}

function Protect-TextLogFallback {
    <#
        Stand-in for Protect-AdoLogValue for the window in which that function is
        unavailable. Redaction must never simply be skipped: these lines can carry
        authorization headers.
    #>
    param([AllowEmptyString()][string]$Value)
    $text = $Value
    foreach ($secret in $script:LocalSecrets) {
        if (-not [string]::IsNullOrWhiteSpace($secret)) { $text = $text.Replace($secret, '[REDACTED]') }
    }
    $text = [regex]::Replace($text, '(?i)(Authorization\s*[:=]\s*)(Basic|Bearer)\s+[^\s,;\}\]]+', '$1$2 [REDACTED]')
    $text = [regex]::Replace($text, '(?i)([?&](?:access_token|token|pat|sig|signature|client_secret)=)[^&#\s]+', '$1[REDACTED]')
    $text
}

function Write-TextLog {
    # AllowEmptyString so a blank spacer line is loggable: a mandatory [string]
    # otherwise rejects '' and takes the whole run down at the summary.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Message)

    # Protect-AdoLogValue is exported by AdoUtils.Common. A child entry script calls
    # Import-Module -Force, which unloads that module before reloading it, and this
    # function consumes the child's merged output stream - so it can be invoked while
    # the module is briefly absent. Calling it unguarded threw CommandNotFound,
    # aborting the child mid-import and leaving the module unloaded for the rest of
    # the run. Fall back to a local redactor instead of failing.
    $safe = if (Get-Command Protect-AdoLogValue -ErrorAction SilentlyContinue) {
        Protect-AdoLogValue -Value $Message
    } else {
        Protect-TextLogFallback -Value $Message
    }

    $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $safe
    Add-Content -LiteralPath $Path -Value $line -Encoding utf8
}

function Write-ProgressEvent {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][ValidateSet('pending', 'running', 'succeeded', 'failed', 'skipped')][string]$Status,
        [string]$Message = '',
        [string]$LogPath = '',
        [int]$Percent = -1
    )
    if ([string]::IsNullOrWhiteSpace($ProgressPath)) { return }
    $parent = Split-Path -Parent $ProgressPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        step = $Step
        status = $Status
        message = Protect-AdoLogValue -Value $Message
        logPath = $LogPath
        percent = $Percent
    } | ConvertTo-Json -Compress | Add-Content -LiteralPath $ProgressPath -Encoding utf8
}

function Invoke-AdoJson {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH')][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [object]$Body,
        [switch]$AllowNotFound
    )
    $request = @{ Method = $Method; Uri = $Uri; Headers = $Headers; ErrorAction = 'Stop' }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.ContentType = 'application/json'
        $request.Body = $Body | ConvertTo-Json -Depth 100
    }
    try { Invoke-RestMethod @request }
    catch {
        $status = $null
        try { $status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($AllowNotFound -and $status -eq 404) { return $null }

        # A bare "(400) Bad Request" says nothing about which call failed or why.
        # Azure DevOps returns an explanatory body, so surface the method, URI and
        # that body; otherwise every API problem here costs a log-archaeology trip.
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
        if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 400) + '...' }

        $statusText = if ($null -ne $status) { $status } else { 'no status' }
        throw ("Azure DevOps request failed ($statusText). $Method $Uri" +
               $(if ($detail) { [Environment]::NewLine + "Response: $detail" } else { '' }))
    }
}

function Resolve-DefaultTeamName {
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)][hashtable]$Headers)
    if (-not [string]::IsNullOrWhiteSpace($TargetTeam)) { return $TargetTeam }
    $base = 'https://dev.azure.com/{0}' -f (UrlEnc $Target.Org)
    $project = Invoke-AdoJson -Method GET -Uri "$base/_apis/projects/$(UrlEnc $Target.Project)?api-version=7.1" -Headers $Headers
    $teams = @(Invoke-AdoJson -Method GET -Uri "$base/_apis/projects/$($project.id)/teams?`$top=200&api-version=7.1" -Headers $Headers).value
    $projectTeam = @($teams | Where-Object { $_.name -eq $Target.Project -or $_.name -eq "$($Target.Project) Team" } | Select-Object -First 1)
    if ($projectTeam.Count) { return [string]$projectTeam[0].name }
    if ($teams.Count -eq 1) { return [string]$teams[0].name }
    throw "Target team was not supplied and a default could not be inferred. Available teams: $($teams.name -join ', ')"
}

function Invoke-EntryScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][hashtable]$Arguments,
        [Parameter(Mandatory)][string]$LogPath
    )
    Write-TextLog -Path $LogPath -Message "Running $ScriptPath"
    $command = Get-Command $ScriptPath -ErrorAction Stop
    try {
        # Success, error, warning and information streams only. The verbose and debug
        # streams are deliberately not captured: some entry scripts set
        # $VerbosePreference = 'Continue', which turns Import-Module -Force into
        # hundreds of "Removing the imported ... function" lines that bury the real
        # output and are of no use to the person reading this log.
        & $command @Arguments 2>&1 3>&1 6>&1 | ForEach-Object {
            $text = ($_ | Out-String).TrimEnd()
            if (-not [string]::IsNullOrWhiteSpace($text)) { Write-TextLog -Path $LogPath -Message $text }
        }
    }
    catch {
        $message = $_.Exception.Message
        if ($Arguments.ContainsKey('LogDirectory') -and -not [string]::IsNullOrWhiteSpace([string]$Arguments.LogDirectory)) {
            $childErrorLog = Get-ChildItem -LiteralPath $Arguments.LogDirectory -Filter '*-error log-*.jsonl' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Length -gt 0 } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($null -ne $childErrorLog) {
                $childErrorLine = Get-Content -LiteralPath $childErrorLog.FullName -ErrorAction SilentlyContinue |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Last 1
                if (-not [string]::IsNullOrWhiteSpace($childErrorLine)) {
                    try {
                        $childError = $childErrorLine | ConvertFrom-Json
                        if (-not [string]::IsNullOrWhiteSpace([string]$childError.message)) { $message = [string]$childError.message }
                    } catch { }
                }
            }
        }
        throw $message
    }
}

function Copy-SharedQueries {
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][hashtable]$SourceHeaders,
        [Parameter(Mandatory)][hashtable]$TargetHeaders,
        [Parameter(Mandatory)][string]$LogPath
    )
    $sourceBase = 'https://dev.azure.com/{0}' -f (UrlEnc $Source.Org)
    $targetBase = 'https://dev.azure.com/{0}' -f (UrlEnc $Target.Org)
    $sourceProject = UrlEnc $Source.Project
    $targetProject = UrlEnc $Target.Project
    # The Queries API caps $depth at 2 and answers 400 above it, unlike the
    # classification-node API the Area and Iteration steps use, which accepts far
    # more. Fetch two levels at a time and pull deeper folders on demand, so a
    # hierarchy of any depth still copies.
    $queryDepth = 2

    function Get-SourceQueryNode {
        param([Parameter(Mandatory)][string]$PathOrId)
        Invoke-AdoJson -Method GET -Headers $SourceHeaders `
            -Uri "$sourceBase/$sourceProject/_apis/wit/queries/${PathOrId}?`$depth=$queryDepth&`$expand=wiql&api-version=7.1"
    }

    function Get-NodeProperty {
        # StrictMode makes a missing property fatal, and these vary by node type.
        param($Node, [Parameter(Mandatory)][string]$Name)
        $property = $Node.PSObject.Properties[$Name]
        if ($property) { $property.Value } else { $null }
    }

    $root = Get-SourceQueryNode -PathOrId (UrlEnc 'Shared Queries')
    $stats = [ordered]@{ folders = 0; created = 0; updated = 0; reused = 0; skipped = 0 }

    # One query that cannot be recreated must not discard the rest of the work. These
    # are collected and reported at the end, matching how ado-copy-query-workitems
    # handles individual item failures.
    $failures = [Collections.Generic.List[string]]::new()

    function Get-QueryFailureHint {
        param([Parameter(Mandatory)][string]$Message)
        if ($Message -match 'TF51011') {
            return 'references a classification path that does not exist in the target project'
        }
        if ($Message -match 'TF51005|does not exist|could not be found') {
            return 'references a field, type, or path that does not exist in the target project'
        }
        if ($Message -match '\(403\)|permission') { return 'the target PAT lacks permission to create it' }
        'the target rejected it'
    }

    function Ensure-Folder {
        param([string]$ParentPath, [string]$Name)
        try {
            Invoke-AdoJson -Method POST -Uri "$targetBase/$targetProject/_apis/wit/queries/$(($ParentPath -split '/' | ForEach-Object { UrlEnc $_ }) -join '/')?api-version=7.1" -Headers $TargetHeaders -Body @{ name = $Name; isFolder = $true } | Out-Null
            $stats.folders++
            Write-TextLog -Path $LogPath -Message "Created query folder '$ParentPath/$Name'."
        } catch {
            if ($_.Exception.Message -notmatch '409|already exists|TF237018|VS402371') { throw }
        }
    }

    function Copy-Node {
        param($Node, [string]$ParentPath)
        foreach ($child in @((Get-NodeProperty -Node $Node -Name 'children') | Where-Object { $_ })) {
            # Azure DevOps omits isFolder on leaf queries rather than sending false,
            # and omits wiql on folders and on unexpanded nodes. Under StrictMode a
            # direct property read on an absent field is fatal, so every optional
            # field on an API response goes through Get-NodeProperty.
            if (Get-NodeProperty -Node $child -Name 'isFolder') {
                Ensure-Folder -ParentPath $ParentPath -Name $child.name

                # Past the fetched depth a folder arrives with hasChildren set but no
                # children populated. Fetch that subtree before recursing, or its
                # contents are silently skipped.
                $subtree = $child
                if ((Get-NodeProperty -Node $child -Name 'hasChildren') -and
                    -not (Get-NodeProperty -Node $child -Name 'children')) {
                    $subtree = Get-SourceQueryNode -PathOrId $child.id
                }

                Copy-Node -Node $subtree -ParentPath "$ParentPath/$($child.name)"
                continue
            }
            $wiql = [string](Get-NodeProperty -Node $child -Name 'wiql')
            if ([string]::IsNullOrWhiteSpace($wiql)) {
                $full = Invoke-AdoJson -Method GET -Uri "$sourceBase/$sourceProject/_apis/wit/queries/$($child.id)?`$expand=wiql&api-version=7.1" -Headers $SourceHeaders
                $wiql = [string](Get-NodeProperty -Node $full -Name 'wiql')
            }
            if ([string]::IsNullOrWhiteSpace($wiql)) {
                # A query with no WIQL cannot be recreated; skip it loudly rather than
                # sending an empty definition to the target.
                Write-TextLog -Path $LogPath -Message "Skipped '$ParentPath/$($child.name)': the source returned no WIQL for it."
                continue
            }
            $wiql = [regex]::Replace($wiql, [regex]::Escape($Source.Project), [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Target.Project }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            $targetPath = "$ParentPath/$($child.name)"
            $targetPathEncoded = (($targetPath -split '/' | ForEach-Object { UrlEnc $_ }) -join '/')

            try {
                $existing = Invoke-AdoJson -Method GET -Uri "$targetBase/$targetProject/_apis/wit/queries/${targetPathEncoded}?`$expand=wiql&api-version=7.1" -Headers $TargetHeaders -AllowNotFound
                if ($null -eq $existing) {
                    Invoke-AdoJson -Method POST -Uri "$targetBase/$targetProject/_apis/wit/queries/$(($ParentPath -split '/' | ForEach-Object { UrlEnc $_ }) -join '/')?api-version=7.1" -Headers $TargetHeaders -Body @{ name = $child.name; wiql = $wiql } | Out-Null
                    $stats.created++
                    Write-TextLog -Path $LogPath -Message "Created query '$targetPath'."
                } elseif ([string](Get-NodeProperty -Node $existing -Name 'wiql') -cne $wiql) {
                    Invoke-AdoJson -Method PATCH -Uri "$targetBase/$targetProject/_apis/wit/queries/$($existing.id)?api-version=7.1" -Headers $TargetHeaders -Body @{ name = $child.name; wiql = $wiql } | Out-Null
                    $stats.updated++
                    Write-TextLog -Path $LogPath -Message "Updated query '$targetPath'."
                } else {
                    $stats.reused++
                    Write-TextLog -Path $LogPath -Message "Reused query '$targetPath'."
                }
            }
            catch {
                $message = [string]$_.Exception.Message
                $hint = Get-QueryFailureHint -Message $message
                $stats.skipped++
                $failures.Add("$targetPath - $hint")
                Write-TextLog -Path $LogPath -Message "SKIPPED query '$targetPath': $hint."
                Write-TextLog -Path $LogPath -Message "  $($message -replace '\s+', ' ')"
            }
        }
    }

    Copy-Node -Node $root -ParentPath 'Shared Queries'
    Write-TextLog -Path $LogPath -Message "Shared Queries complete. Folders created: $($stats.folders); queries created: $($stats.created); queries updated: $($stats.updated); queries reused: $($stats.reused); queries skipped: $($stats.skipped)."

    if ($failures.Count -gt 0) {
        Write-TextLog -Path $LogPath -Message ''
        Write-TextLog -Path $LogPath -Message "$($failures.Count) query/queries could not be copied:"
        foreach ($failure in $failures) { Write-TextLog -Path $LogPath -Message "  $failure" }
        Write-TextLog -Path $LogPath -Message ''
        Write-TextLog -Path $LogPath -Message 'A query that filters on another project''s Area or Iteration Paths cannot be recreated here: only the source project name is rewritten to the target, because silently repointing a different project''s paths would change what the query means. Recreate these by hand, or migrate the paths they depend on first.'

        throw ("$($stats.created) query/queries copied, $($failures.Count) could not be. First: " +
               "$($failures[0]). See $LogPath for the full list.")
    }
}

function Invoke-SetupStep {
    param(
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][SecureString]$ResolvedSourcePat,
        [Parameter(Mandatory)][SecureString]$ResolvedTargetPat,
        [Parameter(Mandatory)][hashtable]$SourceHeaders,
        [Parameter(Mandatory)][hashtable]$TargetHeaders,
        [Parameter(Mandatory)][string]$RunDirectory,
        [Parameter(Mandatory)][string]$TechnicalLogDirectory
    )
    $meta = $script:StepCatalog[$Step]
    $logPath = New-StepLogPath -Target $Target -Activity $meta.Activity -RunDirectory $RunDirectory
    New-Item -ItemType File -Path $logPath -Force | Out-Null
    Write-ProgressEvent -Step $Step -Status running -Message $meta.Name -LogPath $logPath -Percent 0
    try {
        switch ($Step) {
            'team-config' {
                $team = Resolve-DefaultTeamName -Target $Target -Headers $TargetHeaders
                $area = if ([string]::IsNullOrWhiteSpace($DefaultAreaPath)) { $Target.Project } else { $DefaultAreaPath }
                Invoke-EntryScript -ScriptPath (Join-Path $PSScriptRoot '..\ado-set-default-area\ado-set-default-area.ps1') -LogPath $logPath -Arguments @{
                    ProjectUrl = $TargetProjectUrl; Team = $team; AreaPath = $area; Pat = $ResolvedTargetPat; LogDirectory = $TechnicalLogDirectory; NonInteractive = $true
                }
            }
            'iterations' {
                Invoke-EntryScript -ScriptPath (Join-Path $PSScriptRoot '..\ado-import-iterations\ado-migrate-iterations.ps1') -LogPath $logPath -Arguments @{
                    SourceOrganization = $Source.Org; SourceProject = $Source.Project; SourcePat = $ResolvedSourcePat; TargetOrganization = $Target.Org; TargetProject = $Target.Project; TargetPat = $ResolvedTargetPat; LogDirectory = $TechnicalLogDirectory; NonInteractive = $true
                }
            }
            'areas' {
                Invoke-EntryScript -ScriptPath (Join-Path $PSScriptRoot '..\ado-import-area-paths\ado-migrate-area-paths.ps1') -LogPath $logPath -Arguments @{
                    SourceOrganization = $Source.Org; SourceProject = $Source.Project; SourcePat = $ResolvedSourcePat; TargetOrganization = $Target.Org; TargetProject = $Target.Project; TargetPat = $ResolvedTargetPat; LogDirectory = $TechnicalLogDirectory; NonInteractive = $true
                }
            }
            'work-items' {
                # Discovers work items with WIQL rather than creating a saved query in
                # the source project. That keeps the source PAT read-only, as this
                # folder's README states, and leaves no launcher artifacts behind in
                # the source.
                $sourceUrl = 'https://dev.azure.com/{0}/{1}' -f (UrlEnc $Source.Org), (UrlEnc $Source.Project)
                Invoke-EntryScript -ScriptPath (Join-Path $PSScriptRoot '..\ado-copy-all-workitems\ado-copy-all-workitems.ps1') -LogPath $logPath -Arguments @{
                    SourceProjectUrl = $sourceUrl; TargetProjectUrl = $TargetProjectUrl; SourcePat = $ResolvedSourcePat; TargetPat = $ResolvedTargetPat; StatePath = (Join-Path $RunDirectory 'workitems-state.json'); LogDirectory = $TechnicalLogDirectory; NonInteractive = $true
                }
            }
            'queries' {
                Copy-SharedQueries -Source $Source -Target $Target -SourceHeaders $SourceHeaders -TargetHeaders $TargetHeaders -LogPath $logPath
            }
            'dashboards' {
                $exportDir = Join-Path $RunDirectory 'dashboard-export'
                $team = Resolve-DefaultTeamName -Target $Target -Headers $TargetHeaders
                Invoke-EntryScript -ScriptPath (Join-Path $PSScriptRoot '..\ado-dashboard-migration\01-export-dashboards.ps1') -LogPath $logPath -Arguments @{ Org = $Source.Org; Project = $Source.Project; OutDir = $exportDir; SourcePat = $ResolvedSourcePat; LogDirectory = $TechnicalLogDirectory; NonInteractive = $true }
                Invoke-EntryScript -ScriptPath (Join-Path $PSScriptRoot '..\ado-dashboard-migration\02-migrate-queries.ps1') -LogPath $logPath -Arguments @{ TargetOrg = $Target.Org; TargetProject = $Target.Project; ExportDir = $exportDir; SourceProjectName = $Source.Project; TargetPat = $ResolvedTargetPat; LogDirectory = $TechnicalLogDirectory; NonInteractive = $true }
                Invoke-EntryScript -ScriptPath (Join-Path $PSScriptRoot '..\ado-dashboard-migration\03-import-dashboards.ps1') -LogPath $logPath -Arguments @{ TargetOrg = $Target.Org; TargetProject = $Target.Project; TargetTeam = $team; ExportDir = $exportDir; TargetPat = $ResolvedTargetPat; LogDirectory = $TechnicalLogDirectory; NonInteractive = $true }
            }
            'wiki' {
                $wikiArgs = @{ SourceOrganization = $Source.Org; SourceProject = $Source.Project; TargetOrganization = $Target.Org; TargetProject = $Target.Project; SourcePat = $ResolvedSourcePat; TargetPat = $ResolvedTargetPat; LogDirectory = $TechnicalLogDirectory; NonInteractive = $true }
                if (-not [string]::IsNullOrWhiteSpace($SourceWikiName)) { $wikiArgs.SourceWikiName = $SourceWikiName }
                if (-not [string]::IsNullOrWhiteSpace($TargetWikiName)) { $wikiArgs.TargetWikiName = $TargetWikiName }
                Invoke-EntryScript -ScriptPath (Join-Path $PSScriptRoot '..\ado-migrate-wiki\ado-migrate-wiki.ps1') -LogPath $logPath -Arguments $wikiArgs
            }
            default { throw "Unknown setup step '$Step'." }
        }
        Write-ProgressEvent -Step $Step -Status succeeded -Message "$($meta.Name) completed." -LogPath $logPath -Percent 100
        [pscustomobject]@{ step = $Step; status = 'succeeded'; logPath = $logPath; message = "$($meta.Name) completed." }
    }
    catch {
        Write-TextLog -Path $logPath -Message "FAILED: $($_.Exception.Message)"
        Write-ProgressEvent -Step $Step -Status failed -Message $_.Exception.Message -LogPath $logPath -Percent 100
        [pscustomobject]@{ step = $Step; status = 'failed'; logPath = $logPath; message = $_.Exception.Message }
    }
}

if ([string]::IsNullOrWhiteSpace($SourceProjectUrl)) { $SourceProjectUrl = Read-AdoInput -Prompt (Get-AdoPrompt -Name SourceProjectUrl) }
if ([string]::IsNullOrWhiteSpace($TargetProjectUrl)) { $TargetProjectUrl = Read-AdoInput -Prompt (Get-AdoPrompt -Name TargetProjectUrl) }
$source = ConvertFrom-AdoProjectUrl -Url $SourceProjectUrl -Role Source
$target = ConvertFrom-AdoProjectUrl -Url $TargetProjectUrl -Role Target
$sourcePatResolved = Resolve-AdoPat -Pat $SourcePat -Role Source
$targetPatResolved = Resolve-AdoPat -Pat $TargetPat -Role Target

# Seed the local redactor used by Write-TextLog when the shared module is briefly
# unloaded by a child script's Import-Module -Force.
$script:LocalSecrets = @(
    (ConvertFrom-AdoSecureString -SecureString $sourcePatResolved),
    (ConvertFrom-AdoSecureString -SecureString $targetPatResolved)
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
$sourceHeaders = New-AdoAuthorizationHeaders -Pat $sourcePatResolved -AdditionalHeaders @{ 'Content-Type' = 'application/json' }
$targetHeaders = New-AdoAuthorizationHeaders -Pat $targetPatResolved -AdditionalHeaders @{ 'Content-Type' = 'application/json' }
$runDirectory = New-RunDirectory -Target $target
$technicalLogDirectory = Join-Path $runDirectory 'technical-jsonl'
if ([string]::IsNullOrWhiteSpace($ProgressPath)) { $ProgressPath = Join-Path $runDirectory 'progress.jsonl' }

# powershell.exe -File cannot bind more than one value to a [string[]] parameter:
# "-Steps a b" keeps only "a", and "-Steps a,b" arrives as the single string "a,b".
# The UI therefore passes one comma-delimited token, so split every element here.
# This still accepts a real array when the runner is called from a session.
$orderedSteps = @(
    $Steps |
        ForEach-Object { $_ -split ',' } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { $_.Trim().ToLowerInvariant() } |
        Sort-Object { if ($script:StepCatalog.Contains($_)) { $script:StepCatalog[$_].Number } else { 999 } }
)
foreach ($step in $orderedSteps) {
    if (-not $script:StepCatalog.Contains($step)) { throw "Unknown step '$step'." }
}

$results = [Collections.Generic.List[object]]::new()
$failed = $false
foreach ($step in $orderedSteps) {
    if ($failed) {
        Write-ProgressEvent -Step $step -Status skipped -Message 'Skipped because an earlier selected step failed.'
        [void]$results.Add([pscustomobject]@{ step = $step; status = 'skipped'; logPath = ''; message = 'Skipped because an earlier selected step failed.' })
        continue
    }
    $result = Invoke-SetupStep -Step $step -Source $source -Target $target -ResolvedSourcePat $sourcePatResolved -ResolvedTargetPat $targetPatResolved -SourceHeaders $sourceHeaders -TargetHeaders $targetHeaders -RunDirectory $runDirectory -TechnicalLogDirectory $technicalLogDirectory
    [void]$results.Add($result)
    if ($result.status -eq 'failed') { $failed = $true }
}

$summary = [pscustomobject]@{
    sourceProjectUrl = $SourceProjectUrl
    targetProjectUrl = $TargetProjectUrl
    runDirectory = $runDirectory
    progressPath = $ProgressPath
    results = $results.ToArray()
    finalStatus = if ($failed) { 'failed' } else { 'succeeded' }
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $runDirectory 'summary.json') -Encoding utf8
$summary | ConvertTo-Json -Depth 20

Complete-AdoScriptRun -Outcome $(if ($failed) { 'partial' } else { 'succeeded' }) -ErrorRecord $null -Operation 'project-setup-runner' -Message "Project setup run $($summary.finalStatus)."
if ($failed) { exit 1 }
