<#
.SYNOPSIS
    Offline validation for ado-extract-workitems.ps1: unit checks of helpers plus end-to-end runs
    against tests/mock_ado_server.py (no live Azure DevOps calls).
    Requires PowerShell 7+ and python3 on PATH. Exit code 0 = all passed.
#>
[CmdletBinding()]
param([int]$Port = 18765)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$scriptPath = Join-Path (Split-Path $here -Parent) 'ado-extract-workitems.ps1'
$script:Failures = [System.Collections.Generic.List[string]]::new()
$script:Passed = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ("$Expected" -ceq "$Actual") { $script:Passed++; return }
    $script:Failures.Add("$Name`n    expected: <$Expected>`n    actual:   <$Actual>")
}
function Assert-True { param([bool]$Condition, [string]$Name) Assert-Equal $true $Condition $Name }
function Assert-Throws {
    param([scriptblock]$Block, [string]$Pattern, [string]$Name)
    try { & $Block; $script:Failures.Add("$Name`n    expected exception matching '$Pattern' but none was thrown") }
    catch { Assert-True ($_.Exception.Message -match $Pattern) "$Name (message: $($_.Exception.Message))" }
}

# ------------------------------------------------------------------ unit checks (dot-source)
. $scriptPath

$u = ConvertFrom-AdoProjectUrl 'https://dev.azure.com/contoso/Fit%20Gap/_workitems/recentlyupdated/'
Assert-Equal 'contoso' $u.Org 'url: dev.azure.com org'
Assert-Equal 'Fit Gap' $u.Project 'url: dev.azure.com project decoded'
Assert-Equal 'https://dev.azure.com/contoso' $u.CollectionUrl 'url: dev.azure.com collection'
$u = ConvertFrom-AdoProjectUrl 'https://Contoso.visualstudio.com/DefaultCollection/Proj'
Assert-Equal 'contoso' $u.Org 'url: visualstudio org'
Assert-Equal 'https://contoso.visualstudio.com/DefaultCollection' $u.CollectionUrl 'url: visualstudio DefaultCollection'
$u = ConvertFrom-AdoProjectUrl 'https://tfs.contoso.local:8443/tfs/Main Collection/Proj X/_boards'
Assert-Equal 'Main Collection' $u.Org 'url: server collection label'
Assert-Equal 'Proj X' $u.Project 'url: server project'
Assert-Equal 'https://tfs.contoso.local:8443/tfs/Main%20Collection' $u.CollectionUrl 'url: server collection url'
Assert-Throws { ConvertFrom-AdoProjectUrl 'https://dev.azure.com/contoso' } 'organization and project' 'url: missing project rejected'
Assert-Throws { ConvertFrom-AdoProjectUrl 'http://dev.azure.com/contoso/p' } 'https' 'url: http to remote host rejected'
Assert-Throws { ConvertFrom-AdoProjectUrl 'dev.azure.com/contoso/p' } 'absolute' 'url: relative rejected'

Assert-Equal "Line one & more`n$([char]0x2022) A`n$([char]0x2022) B" (ConvertFrom-Html '<div><p>Line one &amp; more</p><ul><li>A</li><li>B</li></ul></div>') 'html: paragraphs and bullets'
Assert-Equal 'see spec (https://x/y)' (ConvertFrom-Html 'see <a href="https://x/y">spec</a>') 'html: link keeps url'
Assert-Equal '@Bob please' (ConvertFrom-Html '<a href="#" data-vss-mention="v">@Bob</a> please') 'html: mention'
Assert-Equal "a | b`nc | d" (ConvertFrom-Html '<table><tr><td>a</td><td>b</td></tr><tr><td>c</td><td>d</td></tr></table>') 'html: table'
Assert-Equal "x`ny" (ConvertFrom-Html "x`ny") 'html: plain text newlines preserved'
Assert-Equal '' (ConvertFrom-Html $null) 'html: null'

$script:DisableFormulaGuard = $false
Assert-Equal "'=1+1" (Protect-CsvText '=1+1') 'guard: formula'
Assert-Equal "'- dash" (Protect-CsvText '- dash') 'guard: leading dash text'
Assert-Equal '-5' (Protect-CsvText '-5') 'guard: negative number untouched'
Assert-Equal '[2026] x' (Protect-CsvText '[2026] x') 'guard: normal text untouched'

Assert-Equal '2026-01-15 14:30' (ConvertTo-DateText '2026-01-15T14:30:00.123Z' -AsUtc) 'date: string utc'
Assert-Equal '2026-01-15 14:30' (ConvertTo-DateText ([datetime]::new(2026, 1, 15, 14, 30, 0, [DateTimeKind]::Utc)) -AsUtc) 'date: datetime utc'
Assert-Equal 'not a date' (ConvertTo-DateText 'not a date' -AsUtc) 'date: unparseable passthrough'

Assert-Equal (Get-NormalizedName 'SME Request Teeshirt Size') (Get-NormalizedName 'SME Request T-Shirt Size') 'normalize: t-shirt'
Assert-Equal 'Branch feature/x' (Format-ArtifactLink ([pscustomobject]@{ rel = 'ArtifactLink'; url = 'vstfs:///Git/Ref/p%2Fr%2FGBfeature%2Fx'; attributes = $null })) 'artifact: branch'

$ambiguousFields = @(
    [pscustomobject]@{ referenceName = 'Custom.A1'; name = 'Gap-Closure'; type = 'string' },
    [pscustomobject]@{ referenceName = 'Custom.A2'; name = 'Gap_Closure'; type = 'string' }
)
$cols = Resolve-ExportColumn -Fields $ambiguousFields
$gc = $cols | Where-Object Name -eq 'Gap Closure'
Assert-Equal 'UNRESOLVED' $gc.Match 'resolve: ambiguous normalized match not guessed'
Assert-True ($gc.Note -match 'Ambiguous') 'resolve: ambiguous note'
Assert-Throws { Resolve-ExportColumn -Fields $ambiguousFields -Overrides @{ 'Not A Column' = 'Custom.A1' } } 'not an output column' 'resolve: bad FieldMap key'
Assert-Throws { Resolve-ExportColumn -Fields $ambiguousFields -Overrides @{ 'Gap Closure' = 'Custom.Nope' } } 'not a field' 'resolve: bad FieldMap value'
$cols = Resolve-ExportColumn -Fields $ambiguousFields -Overrides @{ 'gap closure' = 'Gap_Closure' }
Assert-Equal 'Custom.A2' ($cols | Where-Object Name -eq 'Gap Closure').Field.referenceName 'resolve: FieldMap by display name, case-insensitive key'

# ------------------------------------------------------------------ end-to-end against mock server
$uniTitle = 'Ünïcödé ' + [char]0x201C + 'quotes' + [char]0x201D + ", commas, and`nnewline"
$python = (Get-Command python3 -ErrorAction SilentlyContinue) ?? (Get-Command python -ErrorAction Stop)
$server = Start-Process -FilePath $python.Source -ArgumentList @((Join-Path $here 'mock_ado_server.py'), $Port) -PassThru -NoNewWindow
try {
    $deadline = (Get-Date).AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 200
        try { $null = Invoke-RestMethod "http://127.0.0.1:$Port/__calls"; $up = $true } catch { $up = $false }
    } until ($up -or (Get-Date) -gt $deadline)
    if (-not $up) { throw 'Mock server did not start.' }

    $out = Join-Path ([IO.Path]::GetTempPath()) ("ado-extract-test-" + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $out | Out-Null
    $pat = ConvertTo-SecureString 'testpat' -AsPlainText -Force
    $url = "http://127.0.0.1:$Port/contoso/fit%20gap/_workitems"   # lower-case project: canonical name comes from API
    $common = @{ ProjectUrl = $url; Pat = $pat; OutputDirectory = $out; Utc = $true; WiqlPageSize = 2; BatchSize = 2; NonInteractive = $true }

    # Run 1: full export, FieldMap fixes the one unresolved column
    $r = & $scriptPath @common -FieldMap @{ 'Identified When' = 'Custom.WhenIdentified' } -WarningVariable run1Warnings -WarningAction SilentlyContinue 6>$null
    Assert-True (@($run1Warnings | Where-Object { "$_" -match 'HTTP 429.*retrying in 1s' }).Count -eq 1) 'retry: Retry-After header honored on 429'
    Assert-True (@($run1Warnings | Where-Object { "$_" -match 'HTTP 503.*retrying in 2s' }).Count -eq 1) 'retry: exponential backoff on 503'
    Assert-True (@($run1Warnings | Where-Object { "$_" -match "Also found field 'Area'" }).Count -eq 0) 'mapping notes are table text, not warnings'
    $expectedName = 'ADO Extract contoso-Fit Gap-{0}.csv' -f (Get-Date -Format 'yyyy-MM-dd')
    Assert-Equal (Join-Path $out $expectedName) $r.Path 'e2e: file name'
    Assert-Equal 5 $r.WorkItems 'e2e: work item count (other-project item excluded, WIQL paged)'
    Assert-Equal 0 $r.UnresolvedColumns.Count 'e2e: no unresolved columns with FieldMap'
    Assert-Equal 0 $r.DiscussionErrors 'e2e: no discussion errors (429 and 503 retried)'
    Assert-True (-not (Test-Path (Join-Path $out "$expectedName.partial"))) 'e2e: no temp file left'

    $bytes = [IO.File]::ReadAllBytes($r.Path)
    Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'e2e: UTF-8 BOM for Excel'

    $expectedHeader = @('ID', 'Work Item Type', 'State', 'Area', 'Iteration', 'Created Date', 'Created By', 'Updated Date', 'Updated By', 'Title', 'Description',
        'Gap Description', 'Desired Business Outcome', 'Options Considered', 'Pros/Cons of all Options', 'HSO Recommended Solution', 'AVI-SPL Recommended Solution',
        'Work Item Status', 'Fit Gap Assessment', 'SME Request Teeshirt Size', 'HSO Solution Teeshirt Size', 'Gap Closure', 'Wave', 'CE New Field Request',
        'Identified When', 'Change Order Required', 'Change Order Number', 'Timeline Impact', 'Development', 'Dual Write Impact', 'Teeshirt Size', 'Answer',
        'Acceptance Criteria', 'Assigned To', 'Client Team Lead', 'HSO Consultant', 'Due Date', 'Workshop Number', 'Workshop Date', 'Priority', 'OCM Impact',
        'Service Impact', 'Cross Functional Impact', 'Cross Functional Impact Details', 'Responsible', 'Related Work links', 'All Discussion entries')
    $csv = @(Import-Csv -LiteralPath $r.Path)
    $header = @($csv[0].PSObject.Properties.Name)
    Assert-Equal 47 $header.Count 'e2e: column count'
    Assert-Equal ($expectedHeader -join '|') ($header -join '|') 'e2e: column names and order'
    Assert-Equal '1|2|5|7|10' (($csv | ForEach-Object ID) -join '|') 'e2e: rows sorted by ID'

    $w1 = $csv | Where-Object ID -eq '1'
    Assert-Equal 'Requirement' $w1.'Work Item Type' 'w1: type'
    Assert-Equal 'Fit Gap\Finance' $w1.Area 'w1: Area uses System.AreaPath (not Custom.Area)'
    Assert-Equal 'Fit Gap\Wave 1' $w1.Iteration 'w1: iteration'
    Assert-Equal '2026-01-15 14:30' $w1.'Created Date' 'w1: created date (UTC)'
    Assert-Equal 'Ana López' $w1.'Created By' 'w1: created by display name (unicode)'
    Assert-Equal '2026-02-01 09:05' $w1.'Updated Date' 'w1: updated date = ChangedDate'
    Assert-Equal 'Bob Smith' $w1.'Updated By' 'w1: updated by = ChangedBy'
    Assert-Equal 'GL posting — multi-currency' $w1.Title 'w1: title unicode'
    Assert-Equal "Line one & more`n$([char]0x2022) Bullet A`n$([char]0x2022) Bullet B`nSee spec (https://contoso.sharepoint.com/doc)" $w1.Description 'w1: description html->text'
    Assert-Equal "Gap`nsecond line" $w1.'Gap Description' 'w1: custom html field'
    Assert-Equal "'=SUM(A1:A2)" $w1.'Pros/Cons of all Options' 'w1: formula guarded'
    Assert-Equal 'M' $w1.'SME Request Teeshirt Size' 'w1: normalized name match (T-Shirt)'
    Assert-Equal 'L' $w1.'HSO Solution Teeshirt Size' 'w1: exact match'
    Assert-Equal 'Workshop 3' $w1.'Identified When' 'w1: FieldMap override'
    Assert-Equal 'True' $w1.'Change Order Required' 'w1: boolean'
    Assert-Equal "Pull Request: Pull Request 42`nBranch: Branch feature/gl-posting`nFixed in Commit: Commit abcdef12" $w1.Development 'w1: development links fallback'
    Assert-Equal 'Chen Wei' $w1.'Assigned To' 'w1: assigned to'
    Assert-Equal 'Dana Client' $w1.'Client Team Lead' 'w1: custom identity'
    Assert-Equal '2026-04-30 00:00' $w1.'Due Date' 'w1: due date'
    Assert-Equal '3' $w1.'Workshop Number' 'w1: integer'
    Assert-Equal '2026-03-10 05:00' $w1.'Workshop Date' 'w1: custom date'
    Assert-Equal '2' $w1.Priority 'w1: priority'
    Assert-Equal 'Yes' $w1.'Cross Functional Impact' 'w1: normalized (Cross-Functional)'
    Assert-Equal 'HSO' $w1.Responsible 'w1: responsible'
    $expectedRelated = @(
        'Parent: #10 Epic: Finance epic [New]',
        "Related: #5 Requirement: $uniTitle [New]",
        'Related: #900 Feature: Other project feature [New] (comment: cross-project)',
        'Hyperlink: https://contoso.sharepoint.com/fitgap.xlsx') -join "`n"
    Assert-Equal $expectedRelated $w1.'Related Work links' 'w1: related work (names, cross-project lookup, hyperlink; no attachment/artifact)'
    $expectedDiscussion = @(
        '[2026-01-16 08:00] Ana López: First comment <tag>',
        '[2026-01-18 12:00] Chen Wei: md second',
        '[2026-01-20 10:00] Bob Smith: Third bold',
        '[2026-01-22 10:00] Ana López: @Bob Smith please review') -join "`n`n"
    Assert-Equal $expectedDiscussion $w1.'All Discussion entries' 'w1: all comments, paged, chronological, deleted excluded, renderedText used'

    $w2 = $csv | Where-Object ID -eq '2'
    Assert-Equal '' $w2.'All Discussion entries' 'w2: no comments'
    Assert-Equal '' $w2.'Related Work links' 'w2: no links'
    Assert-Equal '' $w2.'Gap Description' 'w2: empty custom field'
    $w5 = $csv | Where-Object ID -eq '5'
    Assert-Equal $uniTitle $w5.Title 'w5: quotes/commas/newline round-trip'
    Assert-Equal 'plain text, no tags' $w5.Description 'w5: plain text in html field'
    Assert-Equal '[2026-02-02 10:00] Ana López: only one' $w5.'All Discussion entries' 'w5: single comment after 503 retry'
    Assert-Equal "'- leading dash text" ($csv | Where-Object ID -eq '7').Description 'w7: leading dash guarded'
    Assert-Equal 'Child: #1 Requirement: GL posting — multi-currency [New]' ($csv | Where-Object ID -eq '10').'Related Work links' 'w10: child link'

    $calls = @((Invoke-RestMethod "http://127.0.0.1:$Port/__calls") | ForEach-Object { $_ })
    $commentCalls = @($calls | Where-Object { $_.path -match '/comments$' })
    Assert-True (@($commentCalls | Where-Object { $_.path -match '/workItems/(2|7|10)/comments' }).Count -eq 0) 'e2e: comments skipped when CommentCount = 0'
    Assert-True (@($calls | Where-Object { $_.path -match '/wiql$' }).Count -ge 3) 'e2e: WIQL paged by ID'
    Assert-True (@($calls | Where-Object { $_.body -and $_.body.PSObject.Properties['$expand'] -and $_.body.PSObject.Properties['fields'] }).Count -eq 0) 'e2e: never sends $expand with fields'

    # Run 2: same day, no -Force -> suffixed file; with -Force -> overwrite
    $r2 = & $scriptPath @common 6>$null 3>$null
    Assert-Equal (Join-Path $out ($expectedName -replace '\.csv$', ' (2).csv')) $r2.Path 'rerun: suffixed, original kept'
    Assert-Equal 'Identified When' ($r2.UnresolvedColumns -join ',') 'rerun: unresolved column reported without FieldMap'
    Assert-Equal '' (@(Import-Csv -LiteralPath $r2.Path) | Where-Object ID -eq '1').'Identified When' 'rerun: unresolved column empty'
    $r3 = & $scriptPath @common -Force 6>$null 3>$null
    Assert-Equal (Join-Path $out $expectedName) $r3.Path 'rerun: -Force overwrites'

    # Filter, resolve-only, KeepHtml, bad PAT, bad project
    $r4 = & $scriptPath @common -Force -WorkItemType 'Epic', 'Task' 6>$null 3>$null
    Assert-Equal '7|10' ((@(Import-Csv -LiteralPath $r4.Path) | ForEach-Object ID) -join '|') 'filter: WorkItemType'
    $before = @(Get-ChildItem $out).Count
    $resolveText = (& $scriptPath @common -ResolveFieldsOnly 6>&1 3>$null | Out-String)
    Assert-True ($resolveText -match 'Area\s+system\s+Area Path \[System\.AreaPath\]') 'resolve-only: mapping table printed without a console width'
    Assert-True ($resolveText -match "Also found field 'Area' \(Custom\.Area\)") 'resolve-only: name collision note'
    Assert-True ($resolveText -match 'Development\s+development links') 'resolve-only: development fallback shown'
    Assert-True ($resolveText -match 'When Identified\s+Custom\.WhenIdentified') 'resolve-only: unmapped custom fields listed'
    Assert-Equal $before @(Get-ChildItem $out).Count 'resolve-only: writes nothing'
    $r5 = & $scriptPath @common -Force -KeepHtml -NoFormulaGuard 6>$null 3>$null
    $k1 = @(Import-Csv -LiteralPath $r5.Path) | Where-Object ID -eq '1'
    Assert-True ($k1.Description -like '<div><p>Line one &amp; more*') 'keephtml: markup kept'
    Assert-Equal '=SUM(A1:A2)' $k1.'Pros/Cons of all Options' 'noformulaguard: raw value'

    $badPat = ConvertTo-SecureString 'wrong' -AsPlainText -Force
    Assert-Throws { & $scriptPath @common -Pat $badPat 6>$null 3>$null } '401 Unauthorized' 'auth: bad PAT gives clear 401'
    Assert-Throws { & $scriptPath @common -ProjectUrl "http://127.0.0.1:$Port/contoso/Nope" 6>$null 3>$null } 'was not found' 'project: unknown project'
    $np = @{} + $common; $np.Remove('Pat')
    Assert-Throws { & $scriptPath @np 6>$null 3>$null } 'NonInteractive' 'noninteractive: missing PAT'
}
finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    if ($out -and (Test-Path $out)) { Remove-Item $out -Recurse -Force }
}

Write-Host ''
if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host "FAIL: $_" -ForegroundColor Red }
    Write-Host "$($script:Passed) passed, $($script:Failures.Count) failed" -ForegroundColor Red
    exit 1
}
Write-Host "All $($script:Passed) checks passed." -ForegroundColor Green
exit 0
