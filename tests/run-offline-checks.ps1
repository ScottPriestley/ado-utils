[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$commonModulePath = Join-Path $repoRoot 'AdoUtils.Common.psm1'

function Assert-Condition {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw $Message
    }
}

function Get-TopLevelMandatoryParameters {
    param([Parameter(Mandatory)][System.Management.Automation.Language.ScriptBlockAst]$Ast)

    if ($null -eq $Ast.ParamBlock) {
        return @()
    }

    $mandatory = @()
    foreach ($parameter in $Ast.ParamBlock.Parameters) {
        foreach ($attribute in $parameter.Attributes) {
            if ($attribute.TypeName.FullName -ne 'Parameter') {
                continue
            }
            if ($attribute.Extent.Text -match 'Mandatory(\s*=\s*\$true)?($|[,)])') {
                $mandatory += $parameter.Name.VariablePath.UserPath
            }
        }
    }
    $mandatory
}

function Get-RepoRelativePath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$Path
    )

    if ([System.IO.Path].GetMethod('GetRelativePath', [type[]]@([string], [string]))) {
        return [System.IO.Path]::GetRelativePath($BasePath, $Path)
    }

    $baseFullPath = [System.IO.Path]::GetFullPath($BasePath)
    if (-not $baseFullPath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $baseFullPath += [System.IO.Path]::DirectorySeparatorChar
    }
    $baseUri = [uri]$baseFullPath
    $pathUri = [uri][System.IO.Path]::GetFullPath($Path)
    [uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString()).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
}

$entryScripts = @(
    Get-ChildItem -Path $repoRoot -Recurse -Filter '*.ps1' |
        Where-Object {
            $_.Name -ne 'run-offline-checks.ps1' -and
            $_.Name -notlike '_*' -and
            $_.FullName -notmatch '[\\/]\.git[\\/]'
        } |
        Sort-Object FullName
)

Assert-Condition ($entryScripts.Count -eq 20) "Expected 20 runnable PowerShell entry scripts in this worktree, found $($entryScripts.Count)."

foreach ($scriptFile in $entryScripts) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$parseErrors)
    $relativePath = Get-RepoRelativePath -BasePath $repoRoot -Path $scriptFile.FullName

    Assert-Condition ($parseErrors.Count -eq 0) "$relativePath has PowerShell parser errors."

    $mandatory = @(Get-TopLevelMandatoryParameters -Ast $ast)
    Assert-Condition ($mandatory.Count -eq 0) "$relativePath has top-level Mandatory parameter prompting: $($mandatory -join ', ')."

    $text = [IO.File]::ReadAllText($scriptFile.FullName)
    Assert-Condition ($text -match 'AdoUtils\.Common\.psm1') "$relativePath does not import AdoUtils.Common.psm1."
    Assert-Condition ($text -match 'Initialize-AdoScriptRun') "$relativePath does not initialize canonical run logs."
    Assert-Condition ($text -match 'Complete-AdoScriptRun') "$relativePath does not complete canonical run logs."
}

$commonText = [IO.File]::ReadAllText($commonModulePath)
$setDefaultAreaScriptPath = Join-Path $repoRoot 'ado-set-default-area/ado-set-default-area.ps1'
$setDefaultAreaScriptText = [IO.File]::ReadAllText($setDefaultAreaScriptPath)
Assert-Condition ($setDefaultAreaScriptText -match 'Get-AdoPrompt -Name TargetProjectUrl') 'ado-set-default-area.ps1 is not using the shared TargetProjectUrl prompt.'
Assert-Condition ($setDefaultAreaScriptText -match '\[string\]\$ProjectUrl') 'ado-set-default-area.ps1 does not accept a ProjectUrl input.'
Assert-Condition ($setDefaultAreaScriptText -match '_apis/work/teamsettings/teamfieldvalues') 'ado-set-default-area.ps1 does not use the documented teamfieldvalues endpoint.'
Assert-Condition ($setDefaultAreaScriptText -match '\$teamUri/_apis/work/teamsettings/teamfieldvalues') 'ado-set-default-area.ps1 does not include the team segment in the teamfieldvalues endpoint.'
Assert-Condition ($setDefaultAreaScriptText -match 'Resolve-DefaultTeamName') 'ado-set-default-area.ps1 does not resolve the default team name explicitly.'
Assert-Condition ($setDefaultAreaScriptText -match '\$\(\$ProjectName\.Trim\(\)\) Team') 'ado-set-default-area.ps1 does not default the team to project name plus Team.'
Assert-Condition ($setDefaultAreaScriptText -match 'ConvertTo-TeamFieldAreaValue') 'ado-set-default-area.ps1 does not normalize UI area paths before calling the teamfieldvalues API.'
Assert-Condition ($setDefaultAreaScriptText -match 'Get-TeamFieldAreaCandidates') 'ado-set-default-area.ps1 does not compare normalized team field area values.'
Assert-Condition ($setDefaultAreaScriptText -match 'Work Items read/write|team/project administrator') 'ado-set-default-area.ps1 does not surface PAT permission guidance for team settings updates.'
Assert-Condition ($setDefaultAreaScriptText -match 'trap \{ Complete-AdoScriptRun[\s\S]+throw \$_ \}') 'ado-set-default-area.ps1 does not preserve the original error message from its trap.'
Assert-Condition ($setDefaultAreaScriptText -notmatch '-UseBasicParsing') 'ado-set-default-area.ps1 should not use -UseBasicParsing in pwsh-compatible code.'

$expectedPrompts = @(
    'Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)',
    'Source Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)',
    'Target Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)',
    'Azure DevOps PAT (input hidden)',
    'Source Azure DevOps PAT (input hidden)',
    'Target Azure DevOps PAT (input hidden)'
)
foreach ($prompt in $expectedPrompts) {
    Assert-Condition ($commonText.Contains($prompt)) "Common module is missing prompt: $prompt"
}

Assert-Condition ($commonText -match 'ADO_PAT') 'Common PAT resolver does not reference ADO_PAT.'
Assert-Condition ($commonText -match 'ADO_SOURCE_PAT') 'Common PAT resolver does not reference ADO_SOURCE_PAT.'
Assert-Condition ($commonText -match 'ADO_TARGET_PAT') 'Common PAT resolver does not reference ADO_TARGET_PAT.'
Assert-Condition ($commonText -match 'Read-AdoInput[\s\S]+-AsSecureString') 'Common PAT resolver does not use a hidden prompt fallback.'
Assert-Condition ($commonText -match '\{0\}-success log-\{1\}\.jsonl') 'Common run logger does not create canonical success JSONL filenames.'
Assert-Condition ($commonText -match '\{0\}-error log-\{1\}\.jsonl') 'Common run logger does not create canonical error JSONL filenames.'

Import-Module $commonModulePath -Force
$tempLogDir = Join-Path ([IO.Path]::GetTempPath()) ("ado-utils-offline-checks-{0}" -f [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempLogDir) | Out-Null
try {
    $run = Initialize-AdoScriptRun -ScriptPath (Join-Path $repoRoot 'sample-entry.ps1') -LogDirectory $tempLogDir -NonInteractive
    Assert-Condition (Test-Path -LiteralPath $run.SuccessLogPath) 'Initialize-AdoScriptRun did not create a success log.'
    Assert-Condition (Test-Path -LiteralPath $run.ErrorLogPath) 'Initialize-AdoScriptRun did not create an error log.'
    Assert-Condition ([IO.Path]::GetFileName($run.SuccessLogPath) -match '^sample-entry-success log-.+\.jsonl$') 'Success log filename is not canonical.'
    Assert-Condition ([IO.Path]::GetFileName($run.ErrorLogPath) -match '^sample-entry-error log-.+\.jsonl$') 'Error log filename is not canonical.'

    $nonInteractiveFailed = $false
    try {
        Resolve-AdoRequiredInput -Value '' -Name 'Organization' -Prompt (Get-AdoPrompt -Name Organization) | Out-Null
    } catch {
        $nonInteractiveFailed = $_.Exception.Message -match 'NonInteractive'
    }
    Assert-Condition $nonInteractiveFailed 'Resolve-AdoRequiredInput did not fail without prompting in -NonInteractive mode.'

    $savedPatEnvironment = @{}
    foreach ($name in @('ADO_PAT', 'ADO_SOURCE_PAT', 'ADO_TARGET_PAT')) {
        $savedPatEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    try {
        [Environment]::SetEnvironmentVariable('ADO_SOURCE_PAT', 'source-env-offline-check')
        $sourceFromEnvironment = Resolve-AdoPat -Role Source
        Assert-Condition ((ConvertFrom-AdoSecureString -SecureString $sourceFromEnvironment) -eq 'source-env-offline-check') 'Resolve-AdoPat did not use ADO_SOURCE_PAT when no parameter was supplied.'

        $sourceParameter = ConvertTo-SecureString -String 'source-parameter-offline-check' -AsPlainText -Force
        $sourceFromParameter = Resolve-AdoPat -Pat $sourceParameter -Role Source
        Assert-Condition ((ConvertFrom-AdoSecureString -SecureString $sourceFromParameter) -eq 'source-parameter-offline-check') 'Resolve-AdoPat did not prefer the SecureString parameter over ADO_SOURCE_PAT.'

        $missingTargetFailed = $false
        try {
            Resolve-AdoPat -Role Target | Out-Null
        } catch {
            $missingTargetFailed = $_.Exception.Message -match 'NonInteractive'
        }
        Assert-Condition $missingTargetFailed 'Resolve-AdoPat did not fail without prompting when a target credential was missing in -NonInteractive mode.'
    }
    finally {
        foreach ($name in $savedPatEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedPatEnvironment[$name])
        }
    }

    Complete-AdoScriptRun -Outcome succeeded -Operation 'offline-check'

    foreach ($jsonlPath in @($run.SuccessLogPath, $run.ErrorLogPath)) {
        foreach ($line in [IO.File]::ReadAllLines($jsonlPath)) {
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            $null = $line | ConvertFrom-Json
        }
    }
}
finally {
    Remove-Item -LiteralPath $tempLogDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Offline checks passed for $($entryScripts.Count) runnable PowerShell entry scripts."
