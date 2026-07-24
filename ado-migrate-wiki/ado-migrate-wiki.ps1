[CmdletBinding()]
param(
    [string]$SourceWikiName,
    [string]$TargetWikiName,
    [switch]$NoExecute
)

$canonicalScript = Join-Path $PSScriptRoot 'ado-migrate-wiki.ps1'
if (-not (Test-Path -LiteralPath $canonicalScript)) {
    throw "The canonical migration script was not found: $canonicalScript"
}

Write-Warning "Migrate-AzureDevOpsWiki.ps1 has been renamed to ado-migrate-wiki.ps1. Forwarding this run to the renamed script."
& $canonicalScript @PSBoundParameters
exit $LASTEXITCODE
