#Requires -Version 7.0
<#
.SYNOPSIS
    Links Azure DevOps work items ACROSS PROJECTS of the same organization, per an Excel
    crosswalk, using the Work Item Tracking REST API. The link type is read per row from a
    LinkType column in the workbook.

.DESCRIPTION
    Reads 'Source ID' / 'Target ID' / 'LinkType' triples from a worksheet of an .xlsx
    crosswalk workbook (no Excel or ImportExcel dependency - the .xlsx is parsed directly
    as Open XML), then adds the requested relation ON each target work item pointing at
    the corresponding source work item.

    Direction semantics: the LinkType value is the role the SOURCE item takes on the
    TARGET item's work item form. Examples (target = T, source = S):
      Predecessor -> T shows S under Related Work -> Predecessor (System.LinkTypes.Dependency-Reverse)
      Successor   -> T shows S under Related Work -> Successor   (System.LinkTypes.Dependency-Forward)
      Related     -> T shows S as Related                          (System.LinkTypes.Related)
      Parent      -> T shows S as Parent                           (System.LinkTypes.Hierarchy-Reverse)

    LinkType accepts friendly end names (Predecessor, Successor, Related, Parent, Child,
    Duplicate, Duplicate Of, Affects, Affected By, Tested By, Tests, ...) or raw relation
    reference names (System.LinkTypes.Dependency-Reverse, Microsoft.VSTS.Common.Affects-Forward,
    ...). In DryRun/Apply/Remove modes the values are validated against the organization's
    actual list of work item relation types; ParseOnly validates against a built-in table
    of the standard system types.

    No work items are created and no fields are edited - link additions (or removals) only.

    Modes:
      ParseOnly  Read and validate the workbook locally. No network calls at all.
      DryRun     Validate every pair and link type against Azure DevOps with read-only
                 GETs and write a report. Nothing is modified.
      Apply      Create the links (one PATCH per target work item).
      Remove     Rollback: remove exactly the crosswalk-defined links.

    The script is idempotent: links that already exist (same relation type and source) are
    reported ALREADY_LINKED and skipped, so interrupted runs can simply be re-run.

.PARAMETER Mode
    ParseOnly | DryRun | Apply | Remove. Default: DryRun.

.PARAMETER OrgUrl
    Organization URL, e.g. https://dev.azure.com/your-org. Both projects must be in this
    organization (cross-project, same-org relations).

.PARAMETER WorkbookPath
    Path to the crosswalk .xlsx workbook.

.PARAMETER SheetName
    Worksheet holding the crosswalk. Default: 'Related Links Master List'.

.PARAMETER SourceIdHeader
    Header text of the column containing the source work item IDs. Default: 'Legacy ID'.
    The header row is located by scanning the sheet for this and the other headers, so
    title/note rows above the table are fine.

.PARAMETER TargetIdHeader
    Header text of the column containing the target work item IDs. Default: 'Target ID'.

.PARAMETER LinkTypeHeader
    Header text of the column containing the link type. Default: 'LinkType'. Blank cells
    are skipped and reported (SKIPPED_NO_LINKTYPE) - the script never guesses a link type.

.PARAMETER Pat
    Azure DevOps PAT (recommended scope: Work Items, Read & Write). Resolution order:
    -Pat parameter, then the AZDO_PAT environment variable. There is deliberately NO
    embedded default - never hard-code tokens in shared scripts.

.PARAMETER LinkComment
    Comment stored on each created link. Default: 'Link per crosswalk'.

.PARAMETER Limit
    Process only the first N target work items (smoke testing). 0 = all.

.PARAMETER ReportPath
    Where to write the per-pair CSV report. Default: link_run_<mode>_<timestamp>.csv
    next to this script.

.EXAMPLE
    pwsh -NoProfile -File .\ado-linkWorkItemsAcrossProjects.ps1 `
        -OrgUrl 'https://dev.azure.com/your-org' -WorkbookPath 'C:\migrations\crosswalk.xlsx' -Mode ParseOnly

    pwsh -NoProfile -File .\ado-linkWorkItemsAcrossProjects.ps1 `
        -OrgUrl 'https://dev.azure.com/your-org' -WorkbookPath 'C:\migrations\crosswalk.xlsx' -Mode DryRun

    pwsh -NoProfile -File .\ado-linkWorkItemsAcrossProjects.ps1 `
        -OrgUrl 'https://dev.azure.com/your-org' -WorkbookPath 'C:\migrations\crosswalk.xlsx' -Mode Apply
#>
[CmdletBinding()]
param(
    [ValidateSet('ParseOnly', 'DryRun', 'Apply', 'Remove')]
    [string]$Mode = 'DryRun',

    [Parameter(Mandatory)]
    [string]$OrgUrl,

    [Parameter(Mandatory)]
    [string]$WorkbookPath,

    [string]$SheetName = 'Related Links Master List',

    [string]$SourceIdHeader = 'Legacy ID',

    [string]$TargetIdHeader = 'Target ID',

    [string]$LinkTypeHeader = 'LinkType',

    [string]$Pat,

    [string]$LinkComment = 'Link per crosswalk',

    [ValidateRange(0, [int]::MaxValue)]
    [int]$Limit = 0,

    [string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$OrgUrl = $OrgUrl.TrimEnd('/')

# ---------------------------------------------------------------- configuration
$ApiVersion = '7.1'

# Built-in fallback map: friendly end name -> relation reference name (standard system
# types). In network modes this is replaced/superseded by the organization's own list.
$BuiltInRelMap = @{
    'predecessor'                             = 'System.LinkTypes.Dependency-Reverse'
    'successor'                               = 'System.LinkTypes.Dependency-Forward'
    'related'                                 = 'System.LinkTypes.Related'
    'parent'                                  = 'System.LinkTypes.Hierarchy-Reverse'
    'child'                                   = 'System.LinkTypes.Hierarchy-Forward'
    'duplicate'                               = 'System.LinkTypes.Duplicate-Forward'
    'duplicate of'                            = 'System.LinkTypes.Duplicate-Reverse'
    'affects'                                 = 'Microsoft.VSTS.Common.Affects-Forward'
    'affected by'                             = 'Microsoft.VSTS.Common.Affects-Reverse'
    'tested by'                               = 'Microsoft.VSTS.Common.TestedBy-Forward'
    'tests'                                   = 'Microsoft.VSTS.Common.TestedBy-Reverse'
    'system.linktypes.dependency-reverse'     = 'System.LinkTypes.Dependency-Reverse'
    'system.linktypes.dependency-forward'     = 'System.LinkTypes.Dependency-Forward'
    'system.linktypes.related'                = 'System.LinkTypes.Related'
    'system.linktypes.hierarchy-reverse'      = 'System.LinkTypes.Hierarchy-Reverse'
    'system.linktypes.hierarchy-forward'      = 'System.LinkTypes.Hierarchy-Forward'
    'system.linktypes.duplicate-forward'      = 'System.LinkTypes.Duplicate-Forward'
    'system.linktypes.duplicate-reverse'      = 'System.LinkTypes.Duplicate-Reverse'
    'microsoft.vsts.common.affects-forward'   = 'Microsoft.VSTS.Common.Affects-Forward'
    'microsoft.vsts.common.affects-reverse'   = 'Microsoft.VSTS.Common.Affects-Reverse'
    'microsoft.vsts.common.testedby-forward'  = 'Microsoft.VSTS.Common.TestedBy-Forward'
    'microsoft.vsts.common.testedby-reverse'  = 'Microsoft.VSTS.Common.TestedBy-Reverse'
}

$script:FatalAuth = $false
$script:reportRows = New-Object System.Collections.Generic.List[object]
$sw = [System.Diagnostics.Stopwatch]::StartNew()

function Add-Report {
    param([long]$SourceId, [long]$TargetId, [string]$LinkType, [string]$Status, [string]$Message)
    $script:reportRows.Add([pscustomobject]@{
        source_id = $SourceId; target_id = $TargetId; link_type = $LinkType; status = $Status; message = $Message
    })
}

# ---------------------------------------------------------------- xlsx reading
# Returns rows as @{ RowNr = <int>; Cells = @{ '<col letter>' = '<string value>' } }.
# Reads the workbook through a temp copy so a file open in Excel cannot block it.
function Read-XlsxSheet {
    param([string]$Path, [string]$Sheet)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    if (-not (Test-Path -LiteralPath $Path)) { throw "Workbook not found: $Path" }

    $nsMain = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    $nsRel  = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'

    $tempCopy = Join-Path ([System.IO.Path]::GetTempPath()) ('xwalk_' + [guid]::NewGuid().ToString('N') + '.xlsx')
    Copy-Item -LiteralPath $Path -Destination $tempCopy -Force

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($tempCopy)

        # sheet name -> worksheet part path (workbook.xml + its rels)
        $wbXml = New-Object System.Xml.XmlDocument
        $wbXml.Load($zip.GetEntry('xl/workbook.xml').Open())
        $wbNs = New-Object System.Xml.XmlNamespaceManager($wbXml.NameTable)
        $wbNs.AddNamespace('d', $nsMain)

        $sheetEl = $wbXml.SelectNodes('/d:workbook/d:sheets/d:sheet', $wbNs) |
            Where-Object { $_.GetAttribute('name') -eq $Sheet } | Select-Object -First 1
        if (-not $sheetEl) {
            $names = ($wbXml.SelectNodes('/d:workbook/d:sheets/d:sheet', $wbNs) | ForEach-Object { $_.GetAttribute('name') }) -join ', '
            throw "Sheet '$Sheet' not found in workbook. Available sheets: $names"
        }
        $rId = $sheetEl.GetAttribute('id', $nsRel)

        $relsXml = New-Object System.Xml.XmlDocument
        $relsXml.Load($zip.GetEntry('xl/_rels/workbook.xml.rels').Open())
        $target = $null
        foreach ($rel in $relsXml.DocumentElement.ChildNodes) {
            if ($rel.GetAttribute('Id') -eq $rId) { $target = ($rel.GetAttribute('Target') -replace '\\', '/'); break }
        }
        if (-not $target) { throw "Could not resolve worksheet part for sheet '$Sheet' (rId=$rId)." }
        $sheetPath = if ($target.StartsWith('/')) { $target.TrimStart('/') } else { 'xl/' + $target }

        # shared strings table
        $shared = New-Object System.Collections.Generic.List[string]
        $ssEntry = $zip.GetEntry('xl/sharedStrings.xml')
        if ($ssEntry) {
            $ssXml = New-Object System.Xml.XmlDocument
            $ssXml.Load($ssEntry.Open())
            $ssNs = New-Object System.Xml.XmlNamespaceManager($ssXml.NameTable)
            $ssNs.AddNamespace('d', $nsMain)
            foreach ($si in $ssXml.SelectNodes('/d:sst/d:si', $ssNs)) {
                $shared.Add(-join ($si.SelectNodes('.//d:t', $ssNs) | ForEach-Object { $_.InnerText }))
            }
        }

        # worksheet rows
        $shXml = New-Object System.Xml.XmlDocument
        $shXml.Load($zip.GetEntry($sheetPath).Open())
        $shNs = New-Object System.Xml.XmlNamespaceManager($shXml.NameTable)
        $shNs.AddNamespace('d', $nsMain)

        $rows = New-Object System.Collections.Generic.List[hashtable]
        foreach ($rowEl in $shXml.SelectNodes('/d:worksheet/d:sheetData/d:row', $shNs)) {
            $cells = @{}
            foreach ($c in $rowEl.SelectNodes('d:c', $shNs)) {
                $col = $c.GetAttribute('r') -replace '\d', ''
                if (-not $col) { continue }
                $t = $c.GetAttribute('t')
                $v = $c.SelectSingleNode('d:v', $shNs)
                if ($t -eq 'inlineStr') {
                    $val = -join ($c.SelectNodes('.//d:t', $shNs) | ForEach-Object { $_.InnerText })
                }
                elseif ($t -eq 's' -and $v) {
                    $idx = [int]$v.InnerText
                    $val = if ($idx -lt $shared.Count) { $shared[$idx] } else { '' }
                }
                elseif ($v) {
                    $val = $v.InnerText
                }
                else {
                    $val = ''
                }
                $cells[$col] = $val
            }
            $rows.Add(@{ RowNr = [int]$rowEl.GetAttribute('r'); Cells = $cells })
        }
        return $rows
    }
    finally {
        if ($zip) { $zip.Dispose() }
        Remove-Item -LiteralPath $tempCopy -ErrorAction SilentlyContinue
    }
}

function ConvertTo-WorkItemId {
    param([string]$Raw)
    if ($null -eq $Raw) { return $null }
    $s = $Raw.Trim()
    if ($s -eq '') { return $null }
    $v = 0L
    if ([int64]::TryParse($s, [ref]$v)) { return $v }
    $d = 0.0
    if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d) -and ($d -eq [math]::Floor($d))) {
        return [int64]$d
    }
    return $null
}

# ---------------------------------------------------------------- Azure DevOps REST layer
# Always returns @{ Ok; Code; Message; Data } - never throws for HTTP errors except that a
# 401 sets $script:FatalAuth to stop the whole run. Retries 429/5xx/network errors.
function Invoke-AdoRest {
    param([string]$Method, [string]$Uri, [object]$BodyObj, [string]$ContentType = 'application/json')

    $json = $null
    if ($null -ne $BodyObj) { $json = ConvertTo-Json -InputObject $BodyObj -Depth 10 }

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $p = @{ Method = $Method; Uri = $Uri; Headers = $script:AdoHeaders; TimeoutSec = 120; ErrorAction = 'Stop' }
            if ($null -ne $json) { $p.Body = $json; $p.ContentType = $ContentType }
            $data = Invoke-RestMethod @p
            return [pscustomobject]@{ Ok = $true; Code = 200; Message = ''; Data = $data }
        }
        catch {
            $code = 0
            $msg = $_.Exception.Message
            if ($_.Exception.Response) {
                try { $code = [int]$_.Exception.Response.StatusCode } catch { }
            }
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
                try {
                    $j = $_.ErrorDetails.Message | ConvertFrom-Json
                    if ($j.message) { $msg = $j.message } else { $msg = $_.ErrorDetails.Message }
                }
                catch { $msg = $_.ErrorDetails.Message }
            }
            if ($code -eq 401) {
                $script:FatalAuth = $true
                return [pscustomobject]@{ Ok = $false; Code = 401; Message = $msg; Data = $null }
            }
            $retryable = ($code -eq 0) -or ($code -eq 429) -or ($code -ge 500)
            if ($retryable -and $attempt -lt 6) {
                $delay = [math]::Min(30, [math]::Pow(2, $attempt))   # 2, 4, 8, 16, 30 s
                Start-Sleep -Seconds $delay
                continue
            }
            return [pscustomobject]@{ Ok = $false; Code = $code; Message = $msg; Data = $null }
        }
    }
}

function Find-RelationIndex {
    param([object[]]$Relations, [string]$Rel, [long]$TargetId)
    for ($i = 0; $i -lt $Relations.Count; $i++) {
        $r = $Relations[$i]
        if ($r.rel -eq $Rel -and $r.url -match '/(\d+)$' -and ([long]$Matches[1]) -eq $TargetId) { return $i }
    }
    return -1
}

# ---------------------------------------------------------------- read crosswalk (raw)
Write-Host "=== ado-linkWorkItemsAcrossProjects - Mode: $Mode ==="
Write-Host "Org      : $OrgUrl"
Write-Host "Workbook : $WorkbookPath"
Write-Host "Sheet    : $SheetName"
Write-Host ''

$rows = Read-XlsxSheet -Path $WorkbookPath -Sheet $SheetName
Write-Host "Read $($rows.Count) worksheet rows."

# locate the header row (robust to title/note rows above it)
$headerInfo = $null
foreach ($row in $rows) {
    $srcCol = $null; $tgtCol = $null; $relCol = $null
    foreach ($kv in $row.Cells.GetEnumerator()) {
        $h = "$($kv.Value)".Trim()
        if ($h -ieq $SourceIdHeader) { $srcCol = $kv.Key }
        elseif ($h -ieq $TargetIdHeader) { $tgtCol = $kv.Key }
        elseif ($h -ieq $LinkTypeHeader) { $relCol = $kv.Key }
    }
    if ($srcCol -and $tgtCol -and $relCol) {
        $headerInfo = @{ RowNr = $row.RowNr; SourceCol = $srcCol; TargetCol = $tgtCol; LinkTypeCol = $relCol }
        break
    }
}
if (-not $headerInfo) { throw "Could not find a header row containing '$SourceIdHeader', '$TargetIdHeader' AND '$LinkTypeHeader' on sheet '$SheetName'." }
Write-Host ("Header   : row {0} ($SourceIdHeader = column {1}, $TargetIdHeader = column {2}, $LinkTypeHeader = column {3})" -f `
    $headerInfo.RowNr, $headerInfo.SourceCol, $headerInfo.TargetCol, $headerInfo.LinkTypeCol)

# raw pairs: IDs parsed, link type kept as written (resolved later against the org's list)
$rawPairs = New-Object System.Collections.Generic.List[object]
$seenRaw = New-Object 'System.Collections.Generic.HashSet[string]'
$stats = [ordered]@{ data_rows = 0; skipped_blank = 0; skipped_nonnumeric = 0; skipped_self = 0; skipped_duplicate = 0; skipped_no_linktype = 0; skipped_unknown_linktype = 0; valid_pairs = 0 }

foreach ($row in $rows) {
    if ($row.RowNr -le $headerInfo.RowNr) { continue }
    if (-not $row.Cells.ContainsKey($headerInfo.SourceCol) -and -not $row.Cells.ContainsKey($headerInfo.TargetCol)) { continue }
    $stats.data_rows++

    $sRaw = if ($row.Cells.ContainsKey($headerInfo.SourceCol)) { "$($row.Cells[$headerInfo.SourceCol])" } else { '' }
    $tRaw = if ($row.Cells.ContainsKey($headerInfo.TargetCol)) { "$($row.Cells[$headerInfo.TargetCol])" } else { '' }
    $rRaw = if ($row.Cells.ContainsKey($headerInfo.LinkTypeCol)) { "$($row.Cells[$headerInfo.LinkTypeCol])" } else { '' }
    $s = ConvertTo-WorkItemId $sRaw
    $t = ConvertTo-WorkItemId $tRaw

    if ($sRaw.Trim() -eq '' -or $tRaw.Trim() -eq '') {
        $stats.skipped_blank++
        Add-Report 0 0 $rRaw.Trim() 'SKIPPED_BLANK' ("workbook row {0}: blank $SourceIdHeader or $TargetIdHeader" -f $row.RowNr)
        continue
    }
    if ($null -eq $s -or $null -eq $t) {
        $stats.skipped_nonnumeric++
        Add-Report 0 0 $rRaw.Trim() 'SKIPPED_NONNUMERIC' ("workbook row {0}: unparseable $SourceIdHeader '{1}' or $TargetIdHeader '{2}'" -f $row.RowNr, $sRaw.Trim(), $tRaw.Trim())
        continue
    }
    if ($s -eq $t) {
        $stats.skipped_self++
        Add-Report $s $t $rRaw.Trim() 'SKIPPED_SELF' ("workbook row {0}: source and target IDs are identical" -f $row.RowNr)
        continue
    }
    if ($rRaw.Trim() -eq '') {
        $stats.skipped_no_linktype++
        Add-Report $s $t '' 'SKIPPED_NO_LINKTYPE' ("workbook row {0}: $LinkTypeHeader is blank - the script never guesses a link type" -f $row.RowNr)
        continue
    }
    if (-not $seenRaw.Add(("{0}:{1}:{2}" -f $s, $t, $rRaw.Trim().ToLower()))) {
        $stats.skipped_duplicate++
        Add-Report $s $t $rRaw.Trim() 'SKIPPED_DUPLICATE' ("workbook row {0}: duplicate pair" -f $row.RowNr)
        continue
    }
    $rawPairs.Add([pscustomobject]@{ SourceId = $s; TargetId = $t; LinkTypeRaw = $rRaw.Trim(); RowNr = $row.RowNr })
}

# ---------------------------------------------------------------- link type resolution map
$relMap = $BuiltInRelMap
if ($Mode -ne 'ParseOnly') {
    # PAT resolution: -Pat parameter, then AZDO_PAT environment variable. No embedded default.
    $resolvedPat = $null
    if ($Pat) { $resolvedPat = $Pat }
    elseif ($env:AZDO_PAT) { $resolvedPat = $env:AZDO_PAT }
    if (-not $resolvedPat) {
        throw 'No PAT provided. Pass -Pat or set the AZDO_PAT environment variable (recommended scope: Work Items, Read & Write). This script intentionally has no embedded token.'
    }
    $script:AdoHeaders = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(':' + $resolvedPat)) }

    # fetch the organization's authoritative relation type list (friendly names + reference names)
    $rt = Invoke-AdoRest -Method Get -Uri "$OrgUrl/_apis/wit/workitemrelationtypes?api-version=$ApiVersion"
    if ($script:FatalAuth) {
        Write-Host ''
        Write-Error 'AUTHENTICATION FAILED (HTTP 401): the PAT is invalid or expired. Nothing was modified.'
        exit 1
    }
    if ($rt.Ok) {
        $rtItems = if ($rt.Data -is [System.Array]) { @($rt.Data) }
                   elseif ($rt.Data.PSObject.Properties['value']) { @($rt.Data.value) }
                   else { @($rt.Data) }
        $liveMap = @{}
        foreach ($rtItem in $rtItems) {
            if ($rtItem.referenceName) {
                $liveMap["$($rtItem.referenceName)".ToLower()] = $rtItem.referenceName
                if ($rtItem.name) { $liveMap["$($rtItem.name)".ToLower()] = $rtItem.referenceName }
            }
        }
        if ($liveMap.Count -gt 0) { $relMap = $liveMap }
    }
    else {
        Write-Warning "Could not fetch the organization's relation types (HTTP $($rt.Code)) - validating LinkType values against the built-in table only."
    }
}

# ---------------------------------------------------------------- resolve link types
$pairs = New-Object System.Collections.Generic.List[object]
$seenResolved = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($rp in $rawPairs) {
    $key = $rp.LinkTypeRaw.ToLower()
    if (-not $relMap.ContainsKey($key)) {
        $stats.skipped_unknown_linktype++
        $known = ($relMap.Keys | Sort-Object) -join ', '
        Add-Report $rp.SourceId $rp.TargetId $rp.LinkTypeRaw 'SKIPPED_UNKNOWN_LINKTYPE' ("workbook row {0}: unknown LinkType '{1}'. Accepted values (case-insensitive): {2}" -f $rp.RowNr, $rp.LinkTypeRaw, $known)
        continue
    }
    $rel = $relMap[$key]
    if (-not $seenResolved.Add(("{0}:{1}:{2}" -f $rp.SourceId, $rp.TargetId, $rel.ToLower()))) {
        $stats.skipped_duplicate++
        Add-Report $rp.SourceId $rp.TargetId $rp.LinkTypeRaw 'SKIPPED_DUPLICATE' ("workbook row {0}: duplicate pair (same source/target/link type as an earlier row)" -f $rp.RowNr)
        continue
    }
    $stats.valid_pairs++
    $pairs.Add([pscustomobject]@{ SourceId = $rp.SourceId; TargetId = $rp.TargetId; LinkType = $rel; RowNr = $rp.RowNr })
}

if ($pairs.Count -eq 0) { throw "No valid $SourceIdHeader / $TargetIdHeader / $LinkTypeHeader rows found - nothing to do." }

$groups = @($pairs | Group-Object -Property TargetId)
if ($Limit -gt 0) {
    $groups = @($groups | Select-Object -First $Limit)
    Write-Host "Limit    : first $Limit target work item(s) only"
}
$inScopePairs = ($groups | Measure-Object -Property Count -Sum).Sum

$uniqueSource = @($groups | ForEach-Object { $_.Group.SourceId } | Sort-Object -Unique).Count
Write-Host ("Crosswalk: {0} valid pairs | {1} unique source IDs | {2} unique target work items (skipped: blank={3}, nonnumeric={4}, self={5}, duplicate={6}, no-linktype={7}, unknown-linktype={8})" -f `
    $inScopePairs, $uniqueSource, $groups.Count, $stats.skipped_blank, $stats.skipped_nonnumeric, $stats.skipped_self, $stats.skipped_duplicate, $stats.skipped_no_linktype, $stats.skipped_unknown_linktype)
Write-Host 'Link types in scope:'
$groups | ForEach-Object { $_.Group } | Group-Object LinkType | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,-50} {1}" -f $_.Name, $_.Count)
}
Write-Host ''

if ($Mode -eq 'ParseOnly') {
    Write-Host 'ParseOnly complete - no network calls were made.'
    Write-Host ("Sample pairs: {0}" -f (($pairs | Select-Object -First 5 | ForEach-Object { "$($_.SourceId) -> $($_.TargetId) [$($_.LinkType)]" }) -join '  |  '))
    Write-Host "Elapsed: $($sw.Elapsed.ToString('hh\:mm\:ss'))"
    exit 0
}

# ---------------------------------------------------------------- pre-validate source IDs (cheap: up to 200 ids per batch call)
$sourceMissing = New-Object 'System.Collections.Generic.HashSet[long]'
if ($Mode -in 'DryRun', 'Apply') {
    $allSource = @($groups | ForEach-Object { $_.Group.SourceId } | Sort-Object -Unique)
    Write-Host "Validating $($allSource.Count) unique source work item IDs (batched, read-only)..."
    for ($i = 0; $i -lt $allSource.Count; $i += 200) {
        $end = [math]::Min($i + 199, $allSource.Count - 1)
        $chunk = [long[]]$allSource[$i..$end]
        $r = Invoke-AdoRest -Method Post -Uri "$OrgUrl/_apis/wit/workitemsbatch?api-version=$ApiVersion" `
            -BodyObj @{ ids = @($chunk); fields = @('System.Id') } -ContentType 'application/json'
        if ($script:FatalAuth) { break }
        if ($r.Ok) {
            # normalize the response: this API may return a bare array or a {count, value} wrapper
            $items = if ($r.Data -is [System.Array]) { @($r.Data) }
                     elseif ($r.Data.PSObject.Properties['value']) { @($r.Data.value) }
                     else { @($r.Data) }
            if ($items.Count -eq 0) {
                # an empty response is a validation failure, NOT proof that every id is missing
                Write-Warning "workitemsbatch returned an empty response for ids $($chunk[0])..$($chunk[-1]) - chunk left unvalidated."
                continue
            }
            # ids absent from the response do not exist (or are deleted/removed) - linking them would fail
            $foundIds = New-Object 'System.Collections.Generic.HashSet[long]'
            foreach ($wi in $items) { if ($wi.id) { [void]$foundIds.Add([long]$wi.id) } }
            foreach ($id in $chunk) { if (-not $foundIds.Contains($id)) { [void]$sourceMissing.Add($id) } }
        }
        else {
            Write-Warning "workitemsbatch call failed (HTTP $($r.Code)) - ids in this chunk will be validated only at link time."
        }
        Write-Progress -Activity 'Validating source IDs' -Status ("ids {0}-{1}" -f ($i + 1), ($end + 1)) -PercentComplete ((($end + 1) * 100) / $allSource.Count)
    }
    Write-Progress -Activity 'Validating source IDs' -Completed
    if ($script:FatalAuth) {
        Write-Host ''
        Write-Error 'AUTHENTICATION FAILED (HTTP 401): the PAT is invalid or expired. Nothing was modified.'
        exit 1
    }
    Write-Host "  source IDs not found (would fail linking): $($sourceMissing.Count)"
    Write-Host ''
}

# ---------------------------------------------------------------- main loop
$groupTotal = $groups.Count
$groupIndex = 0
foreach ($g in $groups) {
    $groupIndex++
    if ($script:FatalAuth) { break }

    $tgtId = [long]$g.Name
    $pairSet = @($g.Group)
    Write-Progress -Activity 'Processing target work items' -Status ("target {0}  ({1} of {2})" -f $tgtId, $groupIndex, $groupTotal) -PercentComplete ([int](($groupIndex * 100) / $groupTotal))

    $r = Invoke-AdoRest -Method Get -Uri ('{0}/_apis/wit/workitems/{1}?$expand=relations&api-version={2}' -f $OrgUrl, $tgtId, $ApiVersion)
    if ($script:FatalAuth) { break }
    if (-not $r.Ok) {
        $status = if ($r.Code -eq 404) { 'ERROR_TARGET_NOT_FOUND' } else { 'ERROR' }
        foreach ($p in $pairSet) { Add-Report $p.SourceId $tgtId $p.LinkType $status ("GET of target item failed (HTTP $($r.Code)): $($r.Message)") }
        continue
    }

    $relations = @($r.Data.relations)

    if ($Mode -eq 'Remove') {
        # rollback: remove exactly the crosswalk-defined links on this item
        $targets = @()
        foreach ($p in $pairSet) {
            $idx = Find-RelationIndex -Relations $relations -Rel $p.LinkType -TargetId $p.SourceId
            if ($idx -ge 0) { $targets += [pscustomobject]@{ Index = $idx; Pair = $p } }
        }
        if ($targets.Count -eq 0) {
            foreach ($p in $pairSet) { Add-Report $p.SourceId $tgtId $p.LinkType 'NOT_PRESENT' 'no matching link to remove' }
            continue
        }
        # descending index order so sequential JSON Patch removes do not shift pending indexes
        $ops = @($targets | Sort-Object -Property Index -Descending | ForEach-Object { @{ op = 'remove'; path = "/relations/$($_.Index)" } })
        $pr = Invoke-AdoRest -Method Patch -Uri ('{0}/_apis/wit/workitems/{1}?api-version={2}' -f $OrgUrl, $tgtId, $ApiVersion) -BodyObj $ops -ContentType 'application/json-patch+json'
        if ($pr.Ok) {
            foreach ($t in $targets) { Add-Report $t.Pair.SourceId $tgtId $t.Pair.LinkType 'REMOVED' ("work item rev $($pr.Data.rev)") }
        }
        else {
            foreach ($t in $targets) {
                $rr = Invoke-AdoRest -Method Get -Uri ('{0}/_apis/wit/workitems/{1}?$expand=relations&api-version={2}' -f $OrgUrl, $tgtId, $ApiVersion)
                if (-not $rr.Ok) { Add-Report $t.Pair.SourceId $tgtId $t.Pair.LinkType 'ERROR' ("re-GET failed (HTTP $($rr.Code)): $($rr.Message)"); continue }
                $idx2 = Find-RelationIndex -Relations @($rr.Data.relations) -Rel $t.Pair.LinkType -TargetId $t.Pair.SourceId
                if ($idx2 -lt 0) { Add-Report $t.Pair.SourceId $tgtId $t.Pair.LinkType 'NOT_PRESENT' 'link disappeared before removal'; continue }
                $sr = Invoke-AdoRest -Method Patch -Uri ('{0}/_apis/wit/workitems/{1}?api-version={2}' -f $OrgUrl, $tgtId, $ApiVersion) `
                    -BodyObj @{ op = 'remove'; path = "/relations/$idx2" } -ContentType 'application/json-patch+json'
                if ($sr.Ok) { Add-Report $t.Pair.SourceId $tgtId $t.Pair.LinkType 'REMOVED' ("isolated remove, work item rev $($sr.Data.rev)") }
                else { Add-Report $t.Pair.SourceId $tgtId $t.Pair.LinkType 'ERROR' ("remove failed (HTTP $($sr.Code)): $($sr.Message)") }
            }
        }
        continue
    }

    # DryRun / Apply
    $existing = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($rel in $relations) {
        if ($rel.url -match '/(\d+)$') { [void]$existing.Add(("$($rel.rel)".ToLower() + '|' + $Matches[1])) }
    }

    foreach ($p in $pairSet) {
        if ($existing.Contains("$($p.LinkType.ToLower())|$($p.SourceId)")) { Add-Report $p.SourceId $tgtId $p.LinkType 'ALREADY_LINKED' '' }
    }
    $toLink = @($pairSet | Where-Object { -not $existing.Contains("$($_.LinkType.ToLower())|$($_.SourceId)") })
    if ($toLink.Count -eq 0) { continue }

    if ($Mode -eq 'DryRun') {
        foreach ($p in $toLink) {
            if ($sourceMissing.Contains($p.SourceId)) { Add-Report $p.SourceId $tgtId $p.LinkType 'ERROR_SOURCE_NOT_FOUND' 'source work item does not exist (or is deleted) - linking would fail' }
            else { Add-Report $p.SourceId $tgtId $p.LinkType 'PLANNED' "would add link ($($p.LinkType))" }
        }
        continue
    }

    # Apply
    foreach ($p in $toLink) {
        if ($sourceMissing.Contains($p.SourceId)) { Add-Report $p.SourceId $tgtId $p.LinkType 'ERROR_SOURCE_NOT_FOUND' 'source work item does not exist (or is deleted) - skipped' }
    }
    $linkable = @($toLink | Where-Object { -not $sourceMissing.Contains($_.SourceId) })
    if ($linkable.Count -eq 0) { continue }

    $patchUri = '{0}/_apis/wit/workitems/{1}?api-version={2}' -f $OrgUrl, $tgtId, $ApiVersion
    $ops = @($linkable | ForEach-Object {
        @{ op = 'add'; path = '/relations/-'
           value = @{ rel = $_.LinkType; url = "$OrgUrl/_apis/wit/workitems/$($_.SourceId)"; attributes = @{ comment = $LinkComment } } }
    })
    $pr = Invoke-AdoRest -Method Patch -Uri $patchUri -BodyObj $ops -ContentType 'application/json-patch+json'
    if ($pr.Ok) {
        foreach ($p in $linkable) { Add-Report $p.SourceId $tgtId $p.LinkType 'LINKED' ("work item rev $($pr.Data.rev)") }
    }
    else {
        # batch failed - retry one relation at a time to isolate the offending pairs
        foreach ($p in $linkable) {
            $one = @{ op = 'add'; path = '/relations/-'
                      value = @{ rel = $p.LinkType; url = "$OrgUrl/_apis/wit/workitems/$($p.SourceId)"; attributes = @{ comment = $LinkComment } } }
            $sr = Invoke-AdoRest -Method Patch -Uri $patchUri -BodyObj $one -ContentType 'application/json-patch+json'
            if ($sr.Ok) { Add-Report $p.SourceId $tgtId $p.LinkType 'LINKED' ("isolated add, work item rev $($sr.Data.rev)") }
            else { Add-Report $p.SourceId $tgtId $p.LinkType 'ERROR' ("add failed (HTTP $($sr.Code)): $($sr.Message)") }
        }
    }
}
Write-Progress -Activity 'Processing target work items' -Completed

# ---------------------------------------------------------------- report + summary
if (-not $ReportPath) {
    $baseDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    $ReportPath = Join-Path $baseDir ("link_run_{0}_{1}.csv" -f $Mode.ToLower(), (Get-Date -Format 'yyyyMMdd_HHmmss'))
}
$script:reportRows | Export-Csv -LiteralPath $ReportPath -NoTypeInformation -Encoding utf8

Write-Host ''
Write-Host "=== Summary ($Mode) ==="
Write-Host ("Crosswalk pairs in scope : {0} across {1} target work item(s)" -f $inScopePairs, $groupTotal)
if ($script:reportRows.Count -gt 0) {
    $script:reportRows | Group-Object status | Sort-Object Name | ForEach-Object {
        Write-Host ("  {0,-25} {1}" -f $_.Name, $_.Count)
    }
}
else {
    Write-Host '  (no per-pair rows - nothing skipped or errored)'
}
Write-Host ("Elapsed : {0}" -f $sw.Elapsed.ToString('hh\:mm\:ss'))
Write-Host ("Report  : {0}" -f $ReportPath)

if ($script:FatalAuth) {
    Write-Error 'AUTHENTICATION FAILED (HTTP 401): the PAT is invalid or expired. Partial report written; re-run after fixing the PAT.'
    exit 1
}
exit 0
