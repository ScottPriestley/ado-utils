Set-StrictMode -Version Latest

$script:RunContext = $null
$script:SensitiveValues = [System.Collections.Generic.List[string]]::new()

$script:AdoPrompts = @{
    Organization       = 'Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)'
    SourceOrganization = 'Source Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)'
    TargetOrganization = 'Target Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)'
    SourceProjectUrl   = 'Source URL'
    TargetProjectUrl   = 'Target URL'
    Pat                = 'Azure DevOps PAT (input hidden)'
    SourcePat          = 'Source Azure DevOps PAT (input hidden)'
    TargetPat          = 'Target Azure DevOps PAT (input hidden)'
}

function Get-AdoPrompt {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Organization', 'SourceOrganization', 'TargetOrganization', 'SourceProjectUrl', 'TargetProjectUrl', 'Pat', 'SourcePat', 'TargetPat')][string]$Name)
    $script:AdoPrompts[$Name]
}

function ConvertTo-AdoOrganizationName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Value)
    if ($Value -match '^https://dev\.azure\.com/([^/]+)/?') { return $Matches[1] }
    if ($Value -match '^https://([^.]+)\.visualstudio\.com/?') { return $Matches[1] }
    return $Value.Trim('/')
}

function ConvertFrom-AdoProjectUrl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][ValidateSet('Default', 'Source', 'Target')][string]$Role
    )
    $label = if ($Role -eq 'Default') { 'Project URL' } else { "$Role Project URL" }
    if ([string]::IsNullOrWhiteSpace($Url) -or $Url -notmatch '^https?://') {
        throw "$label must be an absolute Azure DevOps project URL."
    }

    $uri = [uri]$Url
    if ($uri.Host -eq 'dev.azure.com') {
        $segments = @($uri.AbsolutePath.Trim('/') -split '/' | Where-Object { $_ })
        if ($segments.Count -lt 2) { throw "$label must look like https://dev.azure.com/{org}/{project}" }
        return [pscustomobject]@{
            Org     = [uri]::UnescapeDataString($segments[0])
            Project = [uri]::UnescapeDataString($segments[1])
        }
    }
    if ($uri.Host -match '^([^.]+)\.visualstudio\.com$') {
        $segments = @($uri.AbsolutePath.Trim('/') -split '/' | Where-Object { $_ })
        if ($segments.Count -lt 1) { throw "$label must include a project path." }
        return [pscustomobject]@{
            Org     = [uri]::UnescapeDataString($Matches[1])
            Project = [uri]::UnescapeDataString($segments[0])
        }
    }
    throw "$label must use dev.azure.com or visualstudio.com."
}

function Resolve-AdoProjectEndpoint {
    [CmdletBinding()]
    param(
        [string]$ProjectUrl,
        [string]$Organization,
        [string]$Project,
        [Parameter(Mandatory)][ValidateSet('Source', 'Target')][string]$Role
    )
    if (-not [string]::IsNullOrWhiteSpace($ProjectUrl)) {
        return ConvertFrom-AdoProjectUrl -Url $ProjectUrl -Role $Role
    }
    if (-not [string]::IsNullOrWhiteSpace($Organization) -and -not [string]::IsNullOrWhiteSpace($Project)) {
        return [pscustomobject]@{
            Org     = ConvertTo-AdoOrganizationName -Value $Organization
            Project = $Project
        }
    }
    $promptName = if ($Role -eq 'Source') { 'SourceProjectUrl' } else { 'TargetProjectUrl' }
    return ConvertFrom-AdoProjectUrl -Url (Read-AdoInput -Prompt (Get-AdoPrompt -Name $promptName)) -Role $Role
}

function Get-AdoUtf8NoBomEncoding {
    [Text.UTF8Encoding]::new($false)
}

function New-AdoLogFile {
    param([Parameter(Mandatory)][string]$Path)
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    $stream.Dispose()
}

function Initialize-AdoScriptRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$LogDirectory,
        [switch]$NonInteractive
    )

    $scriptBase = [IO.Path]::GetFileNameWithoutExtension($ScriptPath)
    if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
        $LogDirectory = Join-Path (Split-Path -Parent $ScriptPath) 'logs'
    }
    $resolvedLogDirectory = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogDirectory))
    [IO.Directory]::CreateDirectory($resolvedLogDirectory) | Out-Null

    $runId = '{0}-{1}' -f ([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    $successPath = Join-Path $resolvedLogDirectory ("{0}-success log-{1}.jsonl" -f $scriptBase, $runId)
    $errorPath = Join-Path $resolvedLogDirectory ("{0}-error log-{1}.jsonl" -f $scriptBase, $runId)
    New-AdoLogFile -Path $successPath
    New-AdoLogFile -Path $errorPath

    $script:SensitiveValues.Clear()
    $script:RunContext = [pscustomobject]@{
        Script         = $scriptBase
        RunId          = $runId
        SuccessLogPath = $successPath
        ErrorLogPath   = $errorPath
        NonInteractive = $NonInteractive.IsPresent
        Completed      = $false
    }
    Write-AdoRunLog -Level info -Operation initialize -Outcome started -Target $scriptBase -Message 'Run initialized.'
    $script:RunContext
}

function Add-AdoSensitiveValue {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)
    if (-not [string]::IsNullOrWhiteSpace($Value) -and -not $script:SensitiveValues.Contains($Value)) {
        $script:SensitiveValues.Add($Value)
    }
}

function Protect-AdoLogValue {
    [CmdletBinding()]
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    foreach ($secret in $script:SensitiveValues) {
        if (-not [string]::IsNullOrEmpty($secret)) { $text = $text.Replace($secret, '[REDACTED]') }
    }
    $text = [regex]::Replace($text, '(?i)(Authorization\s*[:=]\s*)(Basic|Bearer)\s+[^\s,;\}\]]+', '$1$2 [REDACTED]')
    $text = [regex]::Replace($text, '(?i)([?&](?:access_token|token|pat|sig|signature|client_secret)=)[^&#\s]+', '$1[REDACTED]')
    $text = [regex]::Replace($text, '(?i)("(?:access_token|token|pat|password|client_secret)"\s*:\s*")[^"]+', '$1[REDACTED]')
    $text
}

function Write-AdoRunLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('debug', 'info', 'warning', 'error')][string]$Level,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Outcome,
        [AllowEmptyString()][string]$Target = '',
        [AllowEmptyString()][string]$Message = '',
        [AllowEmptyString()][string]$ErrorType = '',
        [AllowNull()][object]$StatusCode
    )
    if ($null -eq $script:RunContext) { throw 'Initialize-AdoScriptRun must be called before writing run logs.' }
    $record = [ordered]@{
        timestampUtc = [DateTime]::UtcNow.ToString('o')
        level        = $Level
        script       = $script:RunContext.Script
        runId        = $script:RunContext.RunId
        operation    = Protect-AdoLogValue $Operation
        outcome      = Protect-AdoLogValue $Outcome
        target       = Protect-AdoLogValue $Target
        message      = Protect-AdoLogValue $Message
        errorType    = Protect-AdoLogValue $ErrorType
        statusCode   = if ($null -eq $StatusCode) { $null } else { $StatusCode }
    }
    $line = $record | ConvertTo-Json -Compress
    $path = if ($Level -eq 'error') { $script:RunContext.ErrorLogPath } else { $script:RunContext.SuccessLogPath }
    [IO.File]::AppendAllText($path, $line + [Environment]::NewLine, (Get-AdoUtf8NoBomEncoding))
}

function Get-AdoStatusCode {
    param([AllowNull()][object]$ErrorRecord)
    if ($null -eq $ErrorRecord) { return $null }
    try {
        if ($null -ne $ErrorRecord.Exception.Response.StatusCode) { return [int]$ErrorRecord.Exception.Response.StatusCode }
    } catch { }
    try {
        if ($null -ne $ErrorRecord.Exception.StatusCode) { return [int]$ErrorRecord.Exception.StatusCode }
    } catch { }
    $null
}

function Complete-AdoScriptRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('succeeded', 'failed', 'partial', 'preview')][string]$Outcome,
        [AllowNull()][object]$ErrorRecord,
        [string]$Operation = 'run',
        [string]$Target = '',
        [string]$Message = ''
    )
    if ($null -eq $script:RunContext -or $script:RunContext.Completed) { return }
    if ($Outcome -in @('failed', 'partial')) {
        if ([string]::IsNullOrWhiteSpace($Message) -and $null -ne $ErrorRecord) { $Message = [string]$ErrorRecord.Exception.Message }
        $errorType = if ($null -eq $ErrorRecord) { '' } else { [string]$ErrorRecord.Exception.GetType().FullName }
        Write-AdoRunLog -Level error -Operation $Operation -Outcome $Outcome -Target $Target -Message $Message -ErrorType $errorType -StatusCode (Get-AdoStatusCode $ErrorRecord)
    } else {
        Write-AdoRunLog -Level info -Operation $Operation -Outcome $Outcome -Target $Target -Message $Message
    }
    $script:RunContext.Completed = $true
    Write-Host ("Success log: {0}" -f $script:RunContext.SuccessLogPath)
    Write-Host ("Error log:   {0}" -f $script:RunContext.ErrorLogPath)
    Write-Host ("Final outcome: {0}" -f $Outcome)
}

function Read-AdoInput {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Prompt,
        [switch]$AsSecureString
    )
    if ($null -ne $script:RunContext -and $script:RunContext.NonInteractive) {
        throw "Input '$Prompt' is required in -NonInteractive mode; supply it as a parameter or supported environment variable."
    }
    if ($AsSecureString) { return Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt -AsSecureString }
    Microsoft.PowerShell.Utility\Read-Host -Prompt $Prompt
}

function Resolve-AdoRequiredInput {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Prompt
    )
    if (-not [string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }
    $resolved = Read-AdoInput -Prompt $Prompt
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        throw "$Name is required."
    }
    $resolved
}

function ConvertFrom-AdoSecureString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][SecureString]$SecureString)
    $credential = [pscredential]::new('ado', $SecureString)
    $plainText = $credential.GetNetworkCredential().Password
    Add-AdoSensitiveValue -Value $plainText
    $plainText
}

function ConvertTo-AdoSecureString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PlainText)
    $secureString = [SecureString]::new()
    foreach ($character in $PlainText.ToCharArray()) {
        $secureString.AppendChar($character)
    }
    $secureString.MakeReadOnly()
    $secureString
}

function Resolve-AdoPat {
    [CmdletBinding()]
    param(
        [SecureString]$Pat,
        [Parameter(Mandatory)][ValidateSet('Default', 'Source', 'Target')][string]$Role
    )
    $environmentName = switch ($Role) { 'Source' { 'ADO_SOURCE_PAT' } 'Target' { 'ADO_TARGET_PAT' } default { 'ADO_PAT' } }
    $promptName = switch ($Role) { 'Source' { 'SourcePat' } 'Target' { 'TargetPat' } default { 'Pat' } }
    if ($null -eq $Pat) {
        $environmentValue = [Environment]::GetEnvironmentVariable($environmentName)
        if (-not [string]::IsNullOrWhiteSpace($environmentValue)) {
            Add-AdoSensitiveValue -Value $environmentValue
            $Pat = ConvertTo-AdoSecureString -PlainText $environmentValue
        }
    }
    if ($null -eq $Pat) {
        $Pat = Read-AdoInput -Prompt (Get-AdoPrompt -Name $promptName) -AsSecureString
    }
    if ($null -eq $Pat -or [string]::IsNullOrWhiteSpace((ConvertFrom-AdoSecureString -SecureString $Pat))) {
        throw "A non-empty $environmentName credential is required."
    }
    $Pat
}

function New-AdoAuthorizationHeaders {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][SecureString]$Pat,
        [hashtable]$AdditionalHeaders
    )
    $plainText = ConvertFrom-AdoSecureString -SecureString $Pat
    try {
        $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $plainText)); Accept = 'application/json' }
        if ($null -ne $AdditionalHeaders) { foreach ($key in $AdditionalHeaders.Keys) { $headers[$key] = $AdditionalHeaders[$key] } }
        $headers
    } finally { $plainText = $null }
}

Export-ModuleMember -Function Get-AdoPrompt, ConvertTo-AdoOrganizationName, ConvertFrom-AdoProjectUrl, Resolve-AdoProjectEndpoint, Initialize-AdoScriptRun, Add-AdoSensitiveValue, Protect-AdoLogValue, Write-AdoRunLog, Complete-AdoScriptRun, Read-AdoInput, Resolve-AdoRequiredInput, ConvertFrom-AdoSecureString, ConvertTo-AdoSecureString, Resolve-AdoPat, New-AdoAuthorizationHeaders
