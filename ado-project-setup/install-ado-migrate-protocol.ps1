[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$LauncherScriptPath,
    [ValidateSet('LocalMachine', 'CurrentUser')]
    [string]$Scope = 'LocalMachine',
    [string]$PowerShellExe = 'powershell.exe',
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# See the note in ado-project-setup-ui.ps1: $PSScriptRoot is empty in parameter
# defaults for a [CmdletBinding()] script started with powershell.exe -File.
if ([string]::IsNullOrWhiteSpace($LauncherScriptPath)) {
    $LauncherScriptPath = Join-Path $PSScriptRoot 'ado-project-setup-ui.ps1'
}
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$null = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'install-protocol'; throw }

if (-not (Test-Path -LiteralPath $LauncherScriptPath -PathType Leaf)) {
    throw "Launcher script not found: $LauncherScriptPath"
}

$resolvedLauncher = [IO.Path]::GetFullPath($LauncherScriptPath)
$root = if ($Scope -eq 'LocalMachine') {
    'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\ado-migrate'
} else {
    'Registry::HKEY_CURRENT_USER\Software\Classes\ado-migrate'
}
$command = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $PowerShellExe, $resolvedLauncher

if ($PSCmdlet.ShouldProcess($root, 'Register ado-migrate URL protocol')) {
    New-Item -Path $root -Force | Out-Null
    Set-ItemProperty -Path $root -Name '(default)' -Value 'URL:ADO Migration Launcher'
    New-ItemProperty -Path $root -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
    New-Item -Path (Join-Path $root 'shell\open\command') -Force | Out-Null
    Set-ItemProperty -Path (Join-Path $root 'shell\open\command') -Name '(default)' -Value $command
}

Write-Host "Registered ado-migrate:// for $Scope."
Write-Host "Command: $command"
Complete-AdoScriptRun -Outcome succeeded -ErrorRecord $null -Operation 'install-protocol'
