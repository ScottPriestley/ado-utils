[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$failures = [Collections.Generic.List[string]]::new()
$passed = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if ($Condition) { $script:passed++; Write-Host "PASS: $Message" -ForegroundColor Green }
    else { $script:failures.Add($Message); Write-Host "FAIL: $Message" -ForegroundColor Red }
}

$expectedEntries = @(
    'ado-copy-query-workitems.ps1',
    'ado-delete-query-test-scripts.ps1',
    'ado-extract-discussions.ps1',
    'ado-migrate-query.ps1',
    'ado-dashboard-migration/01-export-dashboards.ps1',
    'ado-dashboard-migration/02-migrate-queries.ps1',
    'ado-dashboard-migration/03-import-dashboards.ps1',
    'ado-dashboard-migration/04-create-classification-nodes.ps1',
    'ado-field-extraction/ado-organization-ID-listing.ps1',
    'ado-field-extraction/ado-process-fields.ps1',
    'ado-import-area-paths/ado-import-area-paths.ps1',
    'ado-import-area-paths/ado-migrate-area-paths.ps1',
    'ado-import-iterations/ado-import-iterations.ps1',
    'ado-import-iterations/ado-migrate-iterations.ps1',
    'ado-migrate-wiki/ado-extract-wiki.ps1',
    'ado-migrate-wiki/ado-load-wiki.ps1',
    'ado-migrate-wiki/ado-migrate-wiki.ps1',
    'ado-migrate-workitemtype/ado-migrate-workitemtype.ps1'
)

$discovered = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -Filter *.ps1 -File | Where-Object {
    $_.FullName -notmatch '[\\/](?:tests|node_modules|New folder)[\\/]' -and $_.Name -ne '_common.ps1'
} | ForEach-Object { $_.FullName.Substring($repoRoot.Length + 1).Replace('\', '/') } | Sort-Object)
Assert-True (($discovered -join "`n") -ceq (($expectedEntries | Sort-Object) -join "`n")) 'entry inventory exactly covers all 18 first-party runnable scripts'

$expectedReadmes = @(
    'README.md',
    'ado-dashboard-migration/readme.md',
    'ado-field-extraction/README.md',
    'ado-import-area-paths/README.md',
    'ado-import-iterations/README.md',
    'ado-migrate-wiki/README.md',
    'ado-migrate-workitemtype/README.md'
)
$discoveredReadmes = @(Get-ChildItem -LiteralPath $repoRoot -Recurse -File | Where-Object {
    $_.Name -ieq 'README.md' -and $_.FullName -notmatch '[\\/](?:node_modules|vendor|\.git)[\\/]'
} | ForEach-Object { $_.FullName.Substring($repoRoot.Length + 1).Replace('\', '/') } | Sort-Object)
Assert-True (($discoveredReadmes -join "`n") -ceq (($expectedReadmes | Sort-Object) -join "`n")) 'README inventory exactly covers all seven first-party documentation files'
$requiredReadmeHeadings = @(
    'Prerequisites', 'Authentication and minimum PAT scopes', 'Safety and rerun behavior',
    'Quick start', 'Parameters and precedence', 'Input formats', 'Outputs and logs',
    'Detailed workflow and behavior', 'Verification checklist', 'Troubleshooting',
    'Limitations', 'Security', 'Related workflows'
)
foreach ($relativePath in $expectedReadmes) {
    $readmeText = [IO.File]::ReadAllText((Join-Path $repoRoot $relativePath), [Text.UTF8Encoding]::new($false))
    foreach ($heading in $requiredReadmeHeadings) {
        Assert-True ($readmeText -match "(?m)^## $([regex]::Escape($heading))`r?`$") "$relativePath contains standard section '$heading'"
    }
    Assert-True ($readmeText -match '(?m)^## (?:Scripts, capabilities, and exclusions|Repository workflows and exclusions)\r?$') "$relativePath documents capabilities and exclusions"
    Assert-True ($readmeText -match '<script-base>-success log-' -and $readmeText -match '<script-base>-error log-') "$relativePath documents both literal shared JSONL log labels"
}

foreach ($relativePath in $expectedEntries) {
    $path = Join-Path $repoRoot $relativePath
    $text = [IO.File]::ReadAllText($path, [Text.UTF8Encoding]::new($false))
    $tokens = $null; $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($text, $path, [ref]$tokens, [ref]$parseErrors)
    Assert-True ($parseErrors.Count -eq 0) "$relativePath parses as PowerShell"
    $parameters = @{}; foreach ($parameter in $ast.ParamBlock.Parameters) { $parameters[$parameter.Name.VariablePath.UserPath] = $parameter.StaticType.Name }
    Assert-True ($parameters.ContainsKey('LogDirectory') -and $parameters['LogDirectory'] -eq 'String') "$relativePath exposes -LogDirectory"
    Assert-True ($parameters.ContainsKey('NonInteractive') -and $parameters['NonInteractive'] -eq 'SwitchParameter') "$relativePath exposes -NonInteractive"
    foreach ($patName in @('Pat', 'SourcePat', 'TargetPat')) {
        if ($parameters.ContainsKey($patName)) { Assert-True ($parameters[$patName] -eq 'SecureString') "$relativePath $patName is SecureString" }
    }
    Assert-True ($text -match 'Initialize-AdoScriptRun') "$relativePath initializes the shared run contract"
    Assert-True ($text -match 'Complete-AdoScriptRun') "$relativePath records a final outcome"
    Assert-True ($text -notmatch '(?m)\bRead-Host\b') "$relativePath has no direct prompt bypass"
    Assert-True ($text -notmatch '(?i)PASTE-PAT|<source-pat>|<target-pat>|<pat>') "$relativePath has no editable PAT placeholder"
    Assert-True ($text -notmatch '(?i)(SetEnvironmentVariable|Set-Item)[^\r\n]*(ADO_PAT|ADO_SOURCE_PAT|ADO_TARGET_PAT)') "$relativePath does not cache PATs in environment variables"
    Assert-True ($text -notmatch '(?i)\bDELETE\b.*Invoke-(?:RestMethod|WebRequest|Ado)') "$relativePath has no implicit delete call"
}

$modulePath = Join-Path $repoRoot 'AdoUtils.Common.psm1'
$moduleText = [IO.File]::ReadAllText($modulePath, [Text.UTF8Encoding]::new($false))
foreach ($prompt in @(
    'Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)',
    'Source Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)',
    'Target Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)',
    'Azure DevOps PAT (input hidden)',
    'Source Azure DevOps PAT (input hidden)',
    'Target Azure DevOps PAT (input hidden)'
)) { Assert-True ($moduleText.Contains($prompt)) "shared helper contains exact prompt: $prompt" }

$purposeSpecificUrlPromptLines = @()
foreach ($relativePath in $expectedEntries) {
    $scriptText = [IO.File]::ReadAllText((Join-Path $repoRoot $relativePath), [Text.UTF8Encoding]::new($false))
    $purposeSpecificUrlPromptLines += @($scriptText -split "`r?`n" | Where-Object { $_ -match 'Read-AdoInput' -and $_ -match '(?:URL|Url)' })
}
$approvedPurposeSpecificUrlPrompts = @(
    'Source Query URL',
    'Target Project URL',
    'Enter the Azure DevOps Project URL (e.g. https://dev.azure.com/contoso/ProjectName)'
)
$unapprovedPurposeSpecificUrlPromptLines = @($purposeSpecificUrlPromptLines | Where-Object {
    $line = $_
    -not @($approvedPurposeSpecificUrlPrompts | Where-Object { $line.Contains($_) }).Count
})
Assert-True ($purposeSpecificUrlPromptLines.Count -eq 3 -and $unapprovedPurposeSpecificUrlPromptLines.Count -eq 0) 'only approved purpose-specific URL prompt strings remain'

Import-Module $modulePath -Force
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('ado-utils-offline-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$saved = @{}; foreach ($name in @('ADO_PAT','ADO_SOURCE_PAT','ADO_TARGET_PAT')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, $null) }
try {
    $context = Initialize-AdoScriptRun -ScriptPath (Join-Path $repoRoot 'offline-contract.ps1') -LogDirectory $tempRoot -NonInteractive
    Assert-True ((Test-Path -LiteralPath $context.SuccessLogPath) -and (Test-Path -LiteralPath $context.ErrorLogPath)) 'initialization creates both success and error logs'
    Assert-True ((Split-Path -Leaf $context.SuccessLogPath) -match '^offline-contract-success log-\d{8}T\d{13}Z-[0-9a-f]{8}\.jsonl$') 'success filename contains script base, literal success log label, and UTC run ID'
    Assert-True ((Split-Path -Leaf $context.ErrorLogPath) -match '^offline-contract-error log-\d{8}T\d{13}Z-[0-9a-f]{8}\.jsonl$') 'error filename contains script base, literal error log label, and UTC run ID'
    $secret = 'offline-canary-PAT-42'
    Add-AdoSensitiveValue $secret
    $redacted = Protect-AdoLogValue "Authorization: Basic abc; ?pat=$secret&sig=xyz&token=tok"
    Assert-True ($redacted -notmatch [regex]::Escape($secret) -and $redacted -notmatch 'Basic abc' -and $redacted -notmatch 'sig=xyz' -and $redacted -notmatch 'token=tok') 'central redaction removes registered secrets, authorization values, and sensitive query values'
    Write-AdoRunLog -Level error -Operation test -Outcome failed -Message "Authorization: Bearer abc $secret" -ErrorType Test -StatusCode 401
    Complete-AdoScriptRun -Outcome failed -Operation test -Message 'expected offline failure'
    foreach ($path in @($context.SuccessLogPath, $context.ErrorLogPath)) {
        $bytes = [IO.File]::ReadAllBytes($path)
        Assert-True (-not ($bytes.Count -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) "$(Split-Path -Leaf $path) is UTF-8 without BOM"
        foreach ($line in [IO.File]::ReadAllLines($path)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $record = $line | ConvertFrom-Json
            $fields = @($record.PSObject.Properties.Name)
            Assert-True (@(@('timestampUtc','level','script','runId','operation','outcome','target','message','errorType','statusCode') | Where-Object { $_ -notin $fields }).Count -eq 0) 'every JSONL record contains the required schema'
            Assert-True ($line -notmatch [regex]::Escape($secret)) 'JSONL output contains no registered secret'
        }
    }
    [Environment]::SetEnvironmentVariable('ADO_SOURCE_PAT', 'source-env-canary')
    $resolved = Resolve-AdoPat -Role Source
    Assert-True ((ConvertFrom-AdoSecureString $resolved) -eq 'source-env-canary') 'ADO_SOURCE_PAT is used when no SecureString parameter is supplied'
    $parameterPat = ConvertTo-SecureString 'parameter-wins' -AsPlainText -Force
    Assert-True ((ConvertFrom-AdoSecureString (Resolve-AdoPat -Pat $parameterPat -Role Source)) -eq 'parameter-wins') 'SecureString parameter takes precedence over environment credential'
    [Environment]::SetEnvironmentVariable('ADO_TARGET_PAT', $null)
    $threw = $false; try { Resolve-AdoPat -Role Target | Out-Null } catch { $threw = $true }
    Assert-True $threw '-NonInteractive never prompts when a credential is absent'
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Assert-True ((Get-Content (Join-Path $repoRoot 'ado-import-area-paths/ado-migrate-area-paths.ps1') -Raw) -match 'verification skipped because no writes occurred') 'Area Path migration skips post-write verification under WhatIf'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-import-iterations/ado-migrate-iterations.ps1') -Raw) -match 'verification skipped because no writes occurred') 'Iteration Path migration skips post-write verification under WhatIf'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-import-iterations/ado-import-iterations.ps1') -Raw) -match '-UpdateExisting is not supported safely') 'UpdateExisting is rejected honestly before changing existing nodes'
$iterationImportText = Get-Content (Join-Path $repoRoot 'ado-import-iterations/ado-import-iterations.ps1') -Raw
Assert-True ($iterationImportText.IndexOf('if ($UpdateExisting)') -lt $iterationImportText.IndexOf('$Pat = Resolve-AdoPat')) 'UpdateExisting is rejected before authentication or Azure DevOps calls'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-migrate-wiki/ado-load-wiki.ps1') -Raw) -match 'Content -ceq \$Content\) \{ return ''Skipped'' \}') 'wiki load skips identical pages'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-migrate-wiki/ado-migrate-wiki.ps1') -Raw) -match 'Content -ceq \$Content\) \{ return ''Skipped'' \}') 'wiki migration skips identical pages'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-migrate-wiki/ado-migrate-wiki.ps1') -Raw) -match 'Skipped identical attachment') 'wiki migration skips identical attachments'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-migrate-wiki/ado-load-wiki.ps1') -Raw) -notmatch '"https://dev\.azure\.com/\$organizationSegment') 'wiki load preserves the ApiBaseUri offline seam for API calls'
$dashboardNodeText = Get-Content (Join-Path $repoRoot 'ado-dashboard-migration/04-create-classification-nodes.ps1') -Raw
Assert-True ($dashboardNodeText -match 'Method GET -Uri \$nodeUri' -and $dashboardNodeText.IndexOf('Method GET -Uri $nodeUri') -lt $dashboardNodeText.IndexOf('Method POST -Uri $uri')) 'dashboard classification nodes are read before write and freshly verified'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-copy-query-workitems.ps1') -Raw) -match 'existing\.wiql -ceq \$Wiql') 'query/work-item copy skips an identical existing query'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-migrate-query.ps1') -Raw) -match 'WIQL differs.*will not overwrite') 'query migration compares existing WIQL and refuses implicit overwrite'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-migrate-query.ps1') -Raw) -match 'Fresh read-back verification failed') 'query migration freshly verifies created queries'
$deleteCalls = @()
foreach ($relativePath in $expectedEntries) {
    $scriptText = Get-Content (Join-Path $repoRoot $relativePath) -Raw
    if ($scriptText -match 'Invoke-Ado\s+-Method\s+DELETE') { $deleteCalls += $relativePath }
}
Assert-True (($deleteCalls -join '') -ceq 'ado-delete-query-test-scripts.ps1') 'only the explicit test-artifact cleanup entry contains a DELETE API call'
$deleteScriptText = Get-Content (Join-Path $repoRoot 'ado-delete-query-test-scripts.ps1') -Raw
Assert-True ($deleteScriptText.IndexOf('if (-not $Apply)') -lt $deleteScriptText.IndexOf('Invoke-Ado -Method DELETE')) 'DELETE API call occurs only after the non-Apply preview branch returns'
Assert-True ($deleteScriptText.IndexOf('$ConfirmationText -cne $expectedConfirmation') -lt $deleteScriptText.IndexOf('Invoke-Ado -Method DELETE')) 'DELETE API call occurs only after exact confirmation validation'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-import-area-paths/ado-import-area-paths.ps1') -Raw) -notmatch 'Import-AzureDevOpsAreaPaths\.ps1') 'Area Path help uses the current script filename'
Assert-True ((Get-Content (Join-Path $repoRoot 'ado-import-iterations/ado-import-iterations.ps1') -Raw) -notmatch 'Import-AzureDevOpsIterations\.ps1') 'Iteration help uses the current script filename'

Write-Host "`nOffline checks passed: $passed; failed: $($failures.Count)."
if ($failures.Count) { throw "Offline checks failed:`n - $($failures -join "`n - ")" }
