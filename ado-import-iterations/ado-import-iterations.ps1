<#
.SYNOPSIS
    Previews or imports Azure DevOps Iteration Paths from an Excel workbook.

.DESCRIPTION
    Reads the Iterations worksheet in ADO_Iteration_Load_Template.xlsx using
    built-in .NET ZIP/XML support (no Python, Excel COM, or module install).
    It creates missing parent nodes first, creates missing leaf iterations with
    their dates, and skips existing leaf iterations unless -UpdateExisting is
    supplied. The default is preview only; add -Apply to make changes.

.EXAMPLE
    .\Import-AzureDevOpsIterations.ps1 `
      -Organization 'https://dev.azure.com/contoso' `
      -Project 'New Project' `
      -ExcelFile '.\ADO_Iteration_Load_Template.xlsx'

.EXAMPLE
    .\Import-AzureDevOpsIterations.ps1 `
      -Organization 'https://dev.azure.com/contoso' `
      -Project 'New Project' `
      -ExcelFile '.\ADO_Iteration_Load_Template.xlsx' -Apply
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^https://dev\.azure\.com/[^/]+/?$')]
    [string]$Organization,

    [Parameter(Mandatory)]
    [string]$Project,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$ExcelFile,

    [switch]$Apply,
    [switch]$UpdateExisting,
    [SecureString]$Pat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Get-PlainText([SecureString]$SecureValue) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Read-ZipText($Archive, [string]$Path) {
    $entry = $Archive.GetEntry($Path)
    if (-not $entry) { return $null }
    $reader = [IO.StreamReader]::new($entry.Open())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Get-XlsxIterationRows([string]$Path) {
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $Path))
    try {
        [xml]$workbook = Read-ZipText $archive 'xl/workbook.xml'
        [xml]$relationships = Read-ZipText $archive 'xl/_rels/workbook.xml.rels'
        $ns = [Xml.XmlNamespaceManager]::new($workbook.NameTable)
        $ns.AddNamespace('x', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
        $ns.AddNamespace('r', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        $sheet = $workbook.SelectSingleNode("//x:sheet[@name='Iterations']", $ns)
        if (-not $sheet) { throw "Workbook must contain a worksheet named 'Iterations'." }
        $relationshipId = $sheet.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        $relationship = @($relationships.Relationships.Relationship | Where-Object { $_.Id -eq $relationshipId })[0]
        if (-not $relationship) { throw 'Could not locate the Iterations worksheet.' }
        $sheetPath = $relationship.Target.TrimStart('/')
        if (-not $sheetPath.StartsWith('xl/')) { $sheetPath = "xl/$sheetPath" }
        [xml]$worksheet = Read-ZipText $archive $sheetPath

        $shared = @()
        $sharedXml = Read-ZipText $archive 'xl/sharedStrings.xml'
        if ($sharedXml) {
            [xml]$strings = $sharedXml
            $strings.SelectNodes('//x:si', $ns) | ForEach-Object { $shared += $_.InnerText }
        }
        $records = @()
        foreach ($row in $worksheet.SelectNodes('//x:sheetData/x:row', $ns)) {
            $cells = @{}
            foreach ($cell in $row.SelectNodes('x:c', $ns)) {
                $column = ($cell.r -replace '\d', '')
                if ($cell.t -eq 'inlineStr') { $value = $cell.SelectSingleNode('x:is', $ns).InnerText }
                else {
                    $value = $cell.SelectSingleNode('x:v', $ns).InnerText
                    if ($cell.t -eq 's' -and $value) { $value = $shared[[int]$value] }
                }
                $cells[$column] = if ($null -eq $value) { '' } else { $value.Trim() }
            }
            if ($cells.Values | Where-Object { $_ }) { $records += [pscustomobject]$cells }
        }
        $headerIndex = -1
        for ($index = 0; $index -lt $records.Count; $index++) {
            if ($records[$index].A -eq 'Parent Path' -and $records[$index].B -eq 'Iteration Name') { $headerIndex = $index; break }
        }
        if ($headerIndex -lt 0) { throw 'Iterations worksheet is missing the required header row.' }
        $data = @()
        foreach ($record in $records[($headerIndex + 1)..($records.Count - 1)]) {
            # Rows below the template's blank separator are instructions with only column A populated.
            if ($record.B -or $record.C -or $record.D) {
                $data += [pscustomobject]@{ ParentPath = [string]$record.A; Name = [string]$record.B; StartDate = [string]$record.C; FinishDate = [string]$record.D }
            }
        }
        if ($data.Count -eq 0) { throw 'The Iterations worksheet has no iteration rows.' }
        return $data
    }
    finally { $archive.Dispose() }
}

function Get-RelativeIterationPath([string]$ApiPath, [string]$ApiRootPath) {
    if ($ApiPath -eq $ApiRootPath) { return $null }
    $prefix = "$ApiRootPath\"
    if (-not $ApiPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw "API returned unexpected Iteration Path: $ApiPath" }
    return $ApiPath.Substring($prefix.Length)
}

if ($UpdateExisting -and -not $Apply) { throw '-UpdateExisting requires -Apply.' }
if (-not $Pat) { $Pat = Read-Host 'Azure DevOps PAT (Work Items Read & Write)' -AsSecureString }
$plainPat = Get-PlainText $Pat
try {
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":" + $plainPat)); Accept = 'application/json'; 'Content-Type' = 'application/json' }
    $rows = @(Get-XlsxIterationRows $ExcelFile)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $rows) {
        $row.ParentPath = $row.ParentPath.Trim(); $row.Name = $row.Name.Trim(); $row.StartDate = $row.StartDate.Trim(); $row.FinishDate = $row.FinishDate.Trim()
        if (-not $row.Name) { throw 'Iteration Name cannot be blank.' }
        if ($row.Name.Contains('\') -or ($row.ParentPath -and @($row.ParentPath.Split([char]'\') | Where-Object { -not $_.Trim() }).Count)) { throw "Invalid iteration path: '$($row.ParentPath)\$($row.Name)'" }
        foreach ($dateValue in @($row.StartDate, $row.FinishDate) | Where-Object { $_ }) { if (-not [datetime]::TryParseExact($dateValue, 'yyyy-MM-dd', $null, [Globalization.DateTimeStyles]::None, [ref]$null)) { throw "Dates must be YYYY-MM-DD. Invalid value: $dateValue" } }
        if ($row.StartDate -and $row.FinishDate -and $row.StartDate -gt $row.FinishDate) { throw "Start Date cannot be after Finish Date for '$($row.Name)'." }
        $full = (@($row.ParentPath, $row.Name) | Where-Object { $_ }) -join '\'
        if (-not $seen.Add($full)) { throw "Duplicate iteration path: $full" }
    }

    $projectUri = [Uri]::EscapeDataString($Project)
    $baseUri = "$($Organization.TrimEnd('/'))/$projectUri/_apis/wit/classificationnodes/iterations"
    $tree = (Invoke-WebRequest -Method Get -Uri "${baseUri}?`$depth=20&api-version=7.1" -Headers $headers -TimeoutSec 30 -UseBasicParsing).Content | ConvertFrom-Json
    $apiRootPath = $tree.path
    $existing = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    function Add-ExistingIterations($Node) {
        $relative = Get-RelativeIterationPath $Node.path $apiRootPath
        if ($null -ne $relative) { [void]$existing.Add($relative) }
        foreach ($child in @($Node.children)) { if ($null -ne $child) { Add-ExistingIterations $child } }
    }
    Add-ExistingIterations $tree

    $needed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($row in $rows) {
        $full = (@($row.ParentPath, $row.Name) | Where-Object { $_ }) -join '\'
        $parts = $full.Split([char]'\')
        for ($i = 1; $i -le $parts.Count; $i++) { [void]$needed.Add(($parts[0..($i - 1)] -join '\')) }
    }
    $created = [Collections.Generic.List[string]]::new()
    foreach ($path in @($needed | Where-Object { -not $existing.Contains($_) } | Sort-Object { ($_ -split '\\').Count }, @{ Expression = { $_ } })) {
        $parent = if ($path.Contains('\')) { $path.Substring(0, $path.LastIndexOf('\')) } else { '' }
        $name = $path.Substring($path.LastIndexOf('\') + 1)
        Write-Host "CREATE: $path"
        if ($Apply -and $PSCmdlet.ShouldProcess($path, 'Create Azure DevOps Iteration')) {
            $parentUri = if (-not $parent) { $baseUri } else { "$baseUri/$(($parent.Split([char]'\') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/')" }
            $source = @($rows | Where-Object { ((@($_.ParentPath, $_.Name) | Where-Object { $_ }) -join '\') -eq $path })[0]
            $body = @{ name = $name }
            if ($source -and ($source.StartDate -or $source.FinishDate)) { $body.attributes = @{}; if ($source.StartDate) { $body.attributes.startDate = "$($source.StartDate)T00:00:00Z" }; if ($source.FinishDate) { $body.attributes.finishDate = "$($source.FinishDate)T00:00:00Z" } }
            Invoke-WebRequest -Method Post -Uri "${parentUri}?api-version=7.1" -Headers $headers -Body ($body | ConvertTo-Json -Compress) -TimeoutSec 30 -UseBasicParsing | Out-Null
            [void]$created.Add($path); [void]$existing.Add($path)
        }
    }
    foreach ($row in $rows | Where-Object { $existing.Contains((@($_.ParentPath, $_.Name) | Where-Object { $_ }) -join '\') }) {
        $path = (@($row.ParentPath, $row.Name) | Where-Object { $_ }) -join '\'
        if (-not $UpdateExisting) { Write-Host "SKIP existing: $path" }
    }
    Write-Host "$(if ($Apply) { 'Applied' } else { 'Previewed' }) $($needed.Count) iteration path(s). Created $($created.Count) node(s)."
}
finally { if ($plainPat) { $plainPat = $null } }
