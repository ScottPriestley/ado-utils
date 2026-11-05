<#
.SYNOPSIS
    Exports every work item in an Azure DevOps project (fit-gap field set, related work links,
    and all discussion comments) to "ADO Extract <Organization>-<Project>-<YYYY-MM-DD>.csv".

.DESCRIPTION
    Read-only against Azure DevOps. Self-contained (no module dependencies).

    Columns are resolved at run time against the project's field list:
      1. -FieldMap override (column name -> field reference name or display name)
      2. Known system reference name (e.g. Area -> System.AreaPath, Updated Date -> System.ChangedDate)
      3. Exact field display name (case-insensitive)
      4. Normalized display name (ignores spaces/punctuation/case; "T-Shirt" == "Teeshirt")
    Columns that cannot be resolved are written empty and reported. Run with -ResolveFieldsOnly
    first to review the mapping without exporting.

.PARAMETER ProjectUrl
    Project URL containing organization and project, e.g. https://dev.azure.com/contoso/Fit%20Gap
    Also accepts https://contoso.visualstudio.com/Project and Azure DevOps Server
    https://server/tfs/Collection/Project. Trailing paths (/_workitems, /_boards/...) are ignored.

.PARAMETER Pat
    Personal Access Token as SecureString. Prompted (hidden) when omitted. Minimum scope: Work Items (Read).

.PARAMETER OutputDirectory
    Folder for the CSV. Defaults to the current directory.

.PARAMETER FieldMap
    Hashtable overriding column resolution, e.g. @{ 'Teeshirt Size' = 'Custom.TShirtSize'; 'Area' = 'Custom.BusinessArea' }

.PARAMETER WorkItemType
    Optional filter: only export these work item types.

.PARAMETER ResolveFieldsOnly
    Connect, resolve columns to fields, print the mapping, and exit without exporting.

.PARAMETER KeepHtml
    Keep rich-text (HTML) field and comment markup instead of converting to plain text.

.PARAMETER Utc
    Write dates in UTC. Default is the local time zone of the machine running the script.

.PARAMETER NoFormulaGuard
    Do not prefix text values beginning with = + - @ with an apostrophe (spreadsheet formula-injection guard).

.PARAMETER Force
    Overwrite an existing CSV with the same name. Without it, a numeric suffix is added.

.PARAMETER NonInteractive
    Fail instead of prompting for missing inputs.

.EXAMPLE
    $pat = Read-Host 'PAT' -AsSecureString
    ./ado-extract-workitems.ps1 -ProjectUrl 'https://dev.azure.com/contoso/Fit Gap' -Pat $pat -ResolveFieldsOnly
    ./ado-extract-workitems.ps1 -ProjectUrl 'https://dev.azure.com/contoso/Fit Gap' -Pat $pat
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Script parameters are read by Invoke-AdoWorkItemExtract through script scope.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console tool; Write-Host writes to the information stream.')]
[CmdletBinding()]
param(
    [string]$ProjectUrl,
    [SecureString]$Pat,
    [string]$OutputDirectory,
    [hashtable]$FieldMap,
    [string[]]$WorkItemType,
    [switch]$ResolveFieldsOnly,
    [switch]$KeepHtml,
    [switch]$Utc,
    [switch]$NoFormulaGuard,
    [switch]$Force,
    [switch]$NonInteractive,
    [ValidateSet('7.0', '7.1')]
    [string]$ApiVersion = '7.1',
    [ValidateRange(1, 200)]
    [int]$BatchSize = 200,
    [ValidateRange(1, 19999)]
    [int]$WiqlPageSize = 19999
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Column definitions (output order). Plain strings resolve by field display name.
#   Refs = preferred system reference names; Kind = special (non-field) column source.
# ---------------------------------------------------------------------------------------------
$script:ColumnSpec = @(
    @{ Name = 'ID';                Refs = @('System.Id') }
    @{ Name = 'Work Item Type';    Refs = @('System.WorkItemType') }
    @{ Name = 'State';             Refs = @('System.State') }
    @{ Name = 'Area';              Refs = @('System.AreaPath') }
    @{ Name = 'Iteration';         Refs = @('System.IterationPath') }
    @{ Name = 'Created Date';      Refs = @('System.CreatedDate') }
    @{ Name = 'Created By';        Refs = @('System.CreatedBy') }
    @{ Name = 'Updated Date';      Refs = @('System.ChangedDate') }
    @{ Name = 'Updated By';        Refs = @('System.ChangedBy') }
    @{ Name = 'Title';             Refs = @('System.Title') }
    @{ Name = 'Description';       Refs = @('System.Description') }
    'Gap Description'
    'Desired Business Outcome'
    'Options Considered'
    'Pros/Cons of all Options'
    'HSO Recommended Solution'
    'AVI-SPL Recommended Solution'
    'Work Item Status'
    'Fit Gap Assessment'
    'SME Request Teeshirt Size'
    'HSO Solution Teeshirt Size'
    'Gap Closure'
    'Wave'
    'CE New Field Request'
    'Identified When'
    'Change Order Required'
    'Change Order Number'
    'Timeline Impact'
    @{ Name = 'Development';       Kind = 'FieldOrDevelopmentLinks' }
    'Dual Write Impact'
    'Teeshirt Size'
    'Answer'
    @{ Name = 'Acceptance Criteria'; Refs = @('Microsoft.VSTS.Common.AcceptanceCriteria') }
    @{ Name = 'Assigned To';       Refs = @('System.AssignedTo') }
    'Client Team Lead'
    'HSO Consultant'
    @{ Name = 'Due Date';          Refs = @('Microsoft.VSTS.Scheduling.DueDate') }
    'Workshop Number'
    'Workshop Date'
    @{ Name = 'Priority';          Refs = @('Microsoft.VSTS.Common.Priority') }
    'OCM Impact'
    'Service Impact'
    'Cross Functional Impact'
    'Cross Functional Impact Details'
    'Responsible'
    @{ Name = 'Related Work links';     Kind = 'RelatedWork' }
    @{ Name = 'All Discussion entries'; Kind = 'Discussion' }
)

$script:ExcelCellLimit = 32767
$script:Bullet = [string][char]0x2022   # kept as a char code so the file stays ASCII (PS 5.1 reads BOM-less files as ANSI)

# =============================================================================================
# Helpers
# =============================================================================================

function Get-Prop {
    param([AllowNull()][object]$InputObject, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    $p.Value
}

function Read-RequiredInput {
    param([Parameter(Mandatory)][string]$Prompt, [switch]$AsSecureString, [switch]$NoPrompt)
    if ($NoPrompt) { throw "Missing required input '$Prompt' and -NonInteractive was specified." }
    if ($AsSecureString) { return Read-Host -Prompt $Prompt -AsSecureString }
    Read-Host -Prompt $Prompt
}

function ConvertFrom-SecureStringPlain {
    param([Parameter(Mandatory)][SecureString]$SecureString)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function ConvertFrom-AdoProjectUrl {
    <# Returns Org (label for file name), Project (from URL), CollectionUrl (API base without project). #>
    param([Parameter(Mandatory)][string]$Url)

    $Url = $Url.Trim().Trim('"', "'")
    $uri = $null
    if (-not [uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin 'https', 'http') {
        throw "ProjectUrl '$Url' is not an absolute http(s) URL. Expected e.g. https://dev.azure.com/{organization}/{project}"
    }
    if ($uri.Scheme -eq 'http' -and -not $uri.IsLoopback) {
        throw 'ProjectUrl must use https (a PAT would otherwise be sent in clear text).'
    }

    # Keep path segments up to the first "_xxx" route segment (e.g. _workitems, _boards, _apis).
    $segments = [System.Collections.Generic.List[string]]::new()
    foreach ($s in ($uri.AbsolutePath -split '/')) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        if ($s.StartsWith('_')) { break }
        $segments.Add([uri]::UnescapeDataString($s))
    }

    $hostName = $uri.Host.ToLowerInvariant()
    $root = '{0}://{1}' -f $uri.Scheme, $uri.Authority

    if ($hostName -eq 'dev.azure.com') {
        if ($segments.Count -lt 2) { throw "ProjectUrl must include organization and project: https://dev.azure.com/{organization}/{project}" }
        $org = $segments[0]; $project = $segments[1]
        $collectionUrl = '{0}/{1}' -f $root, [uri]::EscapeDataString($org)
    }
    elseif ($hostName.EndsWith('.visualstudio.com')) {
        $org = $hostName.Substring(0, $hostName.Length - '.visualstudio.com'.Length)
        if ($segments.Count -ge 1 -and $segments[0] -ieq 'DefaultCollection') { $segments.RemoveAt(0); $collectionUrl = "$root/DefaultCollection" } else { $collectionUrl = $root }
        if ($segments.Count -lt 1) { throw "ProjectUrl must include the project: https://{organization}.visualstudio.com/{project}" }
        $project = $segments[0]
    }
    else {
        # Azure DevOps Server: https://server[/tfs]/{collection}/{project}
        if ($segments.Count -lt 2) { throw "ProjectUrl must include collection and project: https://{server}/{collection}/{project}" }
        $project = $segments[$segments.Count - 1]
        $collectionSegments = @($segments | Select-Object -First ($segments.Count - 1))
        $org = $collectionSegments[$collectionSegments.Count - 1]
        $collectionUrl = $root + '/' + (($collectionSegments | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/')
    }

    [pscustomobject]@{ Org = $org; Project = $project; CollectionUrl = $collectionUrl }
}

function Get-HttpStatusCode {
    param([AllowNull()][System.Management.Automation.ErrorRecord]$ErrorRecord)
    if ($null -eq $ErrorRecord) { return 0 }
    $response = Get-Prop -InputObject $ErrorRecord.Exception -Name 'Response'
    if ($null -ne $response) {
        $code = Get-Prop -InputObject $response -Name 'StatusCode'
        if ($null -ne $code) { return [int]$code }
    }
    $code = Get-Prop -InputObject $ErrorRecord.Exception -Name 'StatusCode'
    if ($null -ne $code) { try { return [int]$code } catch { return 0 } }
    0
}

function Get-RetryAfterSecond {
    param([AllowNull()][System.Management.Automation.ErrorRecord]$ErrorRecord)
    # Direct property access on purpose: returning a header collection from a function would unroll it.
    try {
        if ($null -eq $ErrorRecord -or $null -eq $ErrorRecord.Exception.PSObject.Properties['Response']) { return $null }
        $response = $ErrorRecord.Exception.Response
        if ($null -eq $response -or $null -eq $response.PSObject.Properties['Headers']) { return $null }
        $headers = $response.Headers
        if ($headers -is [System.Net.WebHeaderCollection]) {
            # Windows PowerShell 5.1
            $raw = $headers['Retry-After']
            $n = 0
            if ($raw -and [int]::TryParse($raw, [ref]$n)) { return $n }
            return $null
        }
        # PowerShell 7 (HttpResponseHeaders.RetryAfter is a RetryConditionHeaderValue)
        if ($null -ne $headers.RetryAfter -and $null -ne $headers.RetryAfter.Delta) {
            return [int][Math]::Ceiling($headers.RetryAfter.Delta.TotalSeconds)
        }
    }
    catch { Write-Verbose "Could not read Retry-After header: $($_.Exception.Message)" }
    $null
}

function Get-AdoErrorMessage {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $detail = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        try { $detail = (ConvertFrom-Json -InputObject $ErrorRecord.ErrorDetails.Message).message } catch { $detail = $ErrorRecord.ErrorDetails.Message }
    }
    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $ErrorRecord.Exception.Message }
    $detail
}

function Invoke-Ado {
    <# Invoke-RestMethod with auth header, retry for 408/429/5xx/network errors, and clear auth errors. #>
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('Get', 'Post')][string]$Method = 'Get',
        [object]$Body,
        [int]$MaxAttempts = 6
    )
    $ProgressPreference = 'SilentlyContinue'   # function-local; Windows PowerShell 5.1 download progress is very slow
    $params = @{ Uri = $Uri; Method = $Method; Headers = $script:AuthHeaders; ErrorAction = 'Stop' }
    if ($null -ne $Body) {
        $json = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Depth 10 -Compress }
        $params.Body = [Text.Encoding]::UTF8.GetBytes($json)
        $params.ContentType = 'application/json; charset=utf-8'
    }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $result = Invoke-RestMethod @params
            if ($result -is [string] -and $result -match '(?i)<html') {
                throw [System.UnauthorizedAccessException]::new('Azure DevOps returned a sign-in page instead of data. The PAT is invalid, expired, or for a different organization.')
            }
            return $result
        }
        catch [System.UnauthorizedAccessException] { throw }
        catch {
            $status = Get-HttpStatusCode -ErrorRecord $_
            $message = Get-AdoErrorMessage -ErrorRecord $_
            $transient = ($status -eq 0 -or $status -in 408, 429, 500, 502, 503, 504)
            if (-not $transient -or $attempt -eq $MaxAttempts) {
                switch ($status) {
                    401 { throw "401 Unauthorized calling $Method $Uri. The PAT is invalid, expired, or lacks Work Items (Read) scope for this organization." }
                    403 { throw "403 Forbidden calling $Method $Uri. The PAT identity cannot read this project/work items. $message" }
                    404 { $ex = [System.Collections.Generic.KeyNotFoundException]::new("404 Not Found calling $Method $Uri. $message"); throw $ex }
                    default { throw "HTTP $status calling $Method $Uri. $message" }
                }
            }
            $delay = Get-RetryAfterSecond -ErrorRecord $_
            if ($null -eq $delay -or $delay -lt 1) { $delay = [int][Math]::Min([Math]::Pow(2, $attempt), 60) }
            Write-Warning ("Request failed (HTTP {0}, attempt {1}/{2}); retrying in {3}s: {4}" -f $status, $attempt, $MaxAttempts, $delay, $message)
            Start-Sleep -Seconds $delay
        }
    }
}

function Get-NormalizedName {
    param([AllowNull()][string]$Name)
    if ($null -eq $Name) { return '' }
    $n = ($Name.ToLowerInvariant() -replace '[^a-z0-9]', '')
    $n -replace 'tshirt', 'teeshirt'
}

function Resolve-ExportColumn {
    <# Maps each column spec to a field (or special source). Returns column objects. #>
    param(
        [Parameter(Mandatory)][object[]]$Fields,
        [hashtable]$Overrides
    )

    $byRef = @{}; $byName = @{}; $byNorm = @{}
    foreach ($f in $Fields) {
        $byRef[$f.referenceName.ToLowerInvariant()] = $f
        $byName[$f.name.ToLowerInvariant()] = $f
        $norm = Get-NormalizedName $f.name
        if (-not $byNorm.ContainsKey($norm)) { $byNorm[$norm] = [System.Collections.Generic.List[object]]::new() }
        $byNorm[$norm].Add($f)
    }

    $columnNames = @($script:ColumnSpec | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Name } })
    $overrideLookup = @{}
    if ($Overrides) {
        foreach ($key in $Overrides.Keys) {
            $col = $columnNames | Where-Object { $_ -ieq [string]$key } | Select-Object -First 1
            if (-not $col) { throw "FieldMap key '$key' is not an output column. Valid columns: $($columnNames -join ', ')" }
            $target = ([string]$Overrides[$key]).Trim().ToLowerInvariant()
            $f = if ($byRef.ContainsKey($target)) { $byRef[$target] } elseif ($byName.ContainsKey($target)) { $byName[$target] } else { $null }
            if (-not $f) { throw "FieldMap value '$($Overrides[$key])' for column '$key' is not a field reference name or display name in this project." }
            $overrideLookup[$col.ToLowerInvariant()] = $f
        }
    }

    $columns = [System.Collections.Generic.List[object]]::new()
    foreach ($spec in $script:ColumnSpec) {
        $name = if ($spec -is [string]) { $spec } else { $spec.Name }
        $kind = if ($spec -is [string] -or -not $spec.ContainsKey('Kind')) { 'Field' } else { $spec.Kind }
        $refs = if ($spec -is [string] -or -not $spec.ContainsKey('Refs')) { @() } else { @($spec.Refs) }

        $field = $null; $match = $null; $note = $null
        if ($kind -in 'RelatedWork', 'Discussion') {
            $columns.Add([pscustomobject]@{ Name = $name; Kind = $kind; Field = $null; Match = 'built-in'; Note = $null })
            continue
        }

        if ($overrideLookup.ContainsKey($name.ToLowerInvariant())) {
            $field = $overrideLookup[$name.ToLowerInvariant()]; $match = 'FieldMap'
        }
        if (-not $field) {
            foreach ($r in $refs) { if ($byRef.ContainsKey($r.ToLowerInvariant())) { $field = $byRef[$r.ToLowerInvariant()]; $match = 'system'; break } }
            if ($field -and $byName.ContainsKey($name.ToLowerInvariant())) {
                $same = $byName[$name.ToLowerInvariant()]
                if ($same.referenceName -ne $field.referenceName) {
                    $note = "Also found field '$($same.name)' ($($same.referenceName)); using $($field.referenceName). Override with -FieldMap @{ '$name' = '$($same.referenceName)' } if needed."
                }
            }
        }
        if (-not $field -and $byName.ContainsKey($name.ToLowerInvariant())) {
            $field = $byName[$name.ToLowerInvariant()]; $match = 'exact name'
        }
        if (-not $field) {
            $norm = Get-NormalizedName $name
            if ($byNorm.ContainsKey($norm)) {
                $candidates = @($byNorm[$norm])
                if ($candidates.Count -eq 1) { $field = $candidates[0]; $match = 'normalized name' }
                else { $note = "Ambiguous: " + (($candidates | ForEach-Object { "'$($_.name)' ($($_.referenceName))" }) -join ', ') + '. Use -FieldMap.' }
            }
        }

        $effectiveKind = 'Field'
        if (-not $field -and $kind -eq 'FieldOrDevelopmentLinks') {
            $effectiveKind = 'DevelopmentLinks'; $match = 'development links'
            $note = 'No field named Development; populated from Development (branch/commit/PR/build) links.'
        }
        elseif (-not $field) { $match = 'UNRESOLVED' }

        $columns.Add([pscustomobject]@{ Name = $name; Kind = $effectiveKind; Field = $field; Match = $match; Note = $note })
    }
    $columns
}

function ConvertTo-DateOffset {
    <# Azure DevOps dates are UTC. PS 7 may already have converted them to [datetime]; PS 5.1 leaves strings. #>
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value }
    if ($Value -is [datetime]) {
        $dt = [datetime]$Value
        if ($dt.Kind -eq [DateTimeKind]::Unspecified) { $dt = [datetime]::SpecifyKind($dt, [DateTimeKind]::Utc) }
        return [DateTimeOffset]$dt
    }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed }
    $null
}

function ConvertTo-DateText {
    param([AllowNull()][object]$Value, [switch]$AsUtc)
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    $dto = ConvertTo-DateOffset -Value $Value
    if ($null -eq $dto) { return [string]$Value }
    if ($AsUtc) { return $dto.UtcDateTime.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
    $dto.ToLocalTime().ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-Html {
    <# Rich text -> readable plain text (paragraphs/line breaks/bullets/tables kept, links shown as "text (url)"). #>
    param([AllowNull()][string]$Html)
    if ([string]::IsNullOrEmpty($Html)) { return '' }
    if ($Html -notmatch '<\s*[a-zA-Z!/]') { return ([System.Net.WebUtility]::HtmlDecode($Html)).Trim() }

    $t = $Html -replace '\r?\n', ' '
    $t = $t -replace '(?is)<(script|style)\b.*?</\1\s*>', ''
    $t = $t -replace '(?is)<!--.*?-->', ''
    $t = [regex]::Replace($t, '(?is)<a\b[^>]*?href\s*=\s*["'']([^"'']*)["''][^>]*>(.*?)</a\s*>', [System.Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $href = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
            $text = ($m.Groups[2].Value -replace '<[^>]+>', '').Trim()
            $decodedText = [System.Net.WebUtility]::HtmlDecode($text)
            if ([string]::IsNullOrWhiteSpace($href) -or $href.StartsWith('#') -or $href -match '^(?i)javascript:' -or $decodedText -eq $href -or [string]::IsNullOrWhiteSpace($decodedText)) {
                if ([string]::IsNullOrWhiteSpace($decodedText)) { return $href } else { return $text }
            }
            '{0} ({1})' -f $text, $href
        })
    $t = $t -replace '(?i)<br\s*/?>', "`n"
    $t = $t -replace '(?i)<li\b[^>]*>', ("`n" + $script:Bullet + ' ')
    $t = $t -replace '(?i)</?(p|div|h[1-6]|tr|ul|ol|table|thead|tbody|blockquote|pre|section)\b[^>]*>', "`n"
    $t = $t -replace '(?i)</t[dh]\s*>', ' | '
    $t = $t -replace '(?i)<img\b[^>]*>', '[image]'
    $t = $t -replace '<[^>]+>', ''
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace [char]0x00A0, ' '

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($t -split "`n")) {
        $clean = ($line -replace '[ \t]+', ' ').Trim()
        $clean = ($clean -replace '(\s*\|\s*)+$', '').Trim()
        if ($clean -eq '' -or $clean -eq $script:Bullet) { continue }
        $lines.Add($clean)
    }
    ($lines -join "`n").Trim()
}

function Protect-CsvText {
    <# Prevents spreadsheet formula execution for text that starts with = + - @ (numbers are left alone). #>
    param([AllowNull()][string]$Text)
    if ($script:DisableFormulaGuard -or [string]::IsNullOrEmpty($Text)) { return $Text }
    if ($Text -match '^[=+\-@\t\r]' -and $Text -notmatch '^[+-]?\d+([.,]\d+)?$') { return "'" + $Text }
    $Text
}

function Format-FieldValue {
    param([AllowNull()][object]$Value, [Parameter(Mandatory)][object]$Field)
    if ($null -eq $Value) { return '' }
    $displayName = Get-Prop -InputObject $Value -Name 'displayName'
    if ($null -ne $displayName) { return [string]$displayName }
    $type = [string](Get-Prop -InputObject $Field -Name 'type')
    switch ($type) {
        'dateTime' { return ConvertTo-DateText -Value $Value -AsUtc:$script:UseUtc }
        'html' { if ($script:KeepHtmlMarkup) { return [string]$Value } return ConvertFrom-Html -Html ([string]$Value) }
        'history' { if ($script:KeepHtmlMarkup) { return [string]$Value } return ConvertFrom-Html -Html ([string]$Value) }
        'boolean' { if ([string]$Value -in 'True', 'true', '1') { return 'True' } return 'False' }
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return (@($Value | ForEach-Object { if ($null -ne (Get-Prop $_ 'displayName')) { $_.displayName } else { [string]$_ } }) -join '; ')
    }
    if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) { return ([double]$Value).ToString([Globalization.CultureInfo]::InvariantCulture) }
    [string]$Value
}

function Get-WorkItemIdFromUrl {
    param([AllowNull()][string]$Url)
    if ($Url -match '(?i)/_apis/wit/workItems/(\d+)/?$') { return [int]$Matches[1] }
    $null
}

function Format-ArtifactLink {
    param([Parameter(Mandatory)][object]$Relation)
    $name = [string](Get-Prop (Get-Prop $Relation 'attributes') 'name')
    $url = [string]$Relation.url
    $decoded = [uri]::UnescapeDataString($url)
    $label = $decoded
    if ($decoded -match '(?i)^vstfs:///Git/PullRequestId/[^/]+/[^/]+/(\d+)$') { $label = "Pull Request $($Matches[1])" }
    elseif ($decoded -match '(?i)^vstfs:///Git/Commit/[^/]+/[^/]+/([0-9a-f]{7,40})$') { $label = "Commit $($Matches[1].Substring(0, [Math]::Min(8, $Matches[1].Length)))" }
    elseif ($decoded -match '(?i)^vstfs:///Git/Ref/[^/]+/[^/]+/GB(.+)$') { $label = "Branch $($Matches[1])" }
    elseif ($decoded -match '(?i)^vstfs:///Build/Build/(\d+)$') { $label = "Build $($Matches[1])" }
    if ([string]::IsNullOrWhiteSpace($name)) { return $label }
    "${name}: $label"
}

function Format-RelatedWork {
    param([AllowNull()][object[]]$Relations, [Parameter(Mandatory)][hashtable]$Lookup, [Parameter(Mandatory)][hashtable]$RelationNames)
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($Relations)) {
        if ($null -eq $r) { continue }
        $attrs = Get-Prop $r 'attributes'
        $comment = [string](Get-Prop $attrs 'comment')
        $suffix = if ([string]::IsNullOrWhiteSpace($comment)) { '' } else { " (comment: $comment)" }
        $targetId = Get-WorkItemIdFromUrl -Url ([string]$r.url)
        if ($null -ne $targetId) {
            $linkName = [string](Get-Prop $attrs 'name')
            if ([string]::IsNullOrWhiteSpace($linkName)) { $linkName = if ($RelationNames.ContainsKey([string]$r.rel)) { $RelationNames[[string]$r.rel] } else { [string]$r.rel } }
            $info = $Lookup[$targetId]
            $text = if ($info) { "{0}: #{1} {2}: {3} [{4}]" -f $linkName, $targetId, $info.Type, $info.Title, $info.State } else { "{0}: #{1}" -f $linkName, $targetId }
            $entries.Add([pscustomobject]@{ Order = 0; Key = $linkName; Id = $targetId; Text = $text + $suffix })
        }
        elseif ($r.rel -eq 'Hyperlink') {
            $entries.Add([pscustomobject]@{ Order = 1; Key = 'Hyperlink'; Id = 0; Text = "Hyperlink: $($r.url)$suffix" })
        }
    }
    (@($entries | Sort-Object Order, Key, Id | ForEach-Object { $_.Text }) -join "`n")
}

function Format-DevelopmentLink {
    param([AllowNull()][object[]]$Relations)
    (@(@($Relations) | Where-Object { $null -ne $_ -and $_.rel -eq 'ArtifactLink' } | ForEach-Object { Format-ArtifactLink -Relation $_ }) -join "`n")
}

function Get-WorkItemComment {
    param([Parameter(Mandatory)][string]$ProjectApi, [Parameter(Mandatory)][int]$Id, [Parameter(Mandatory)][string]$CommentsApiVersion)
    $all = [System.Collections.Generic.List[object]]::new()
    $token = $null
    do {
        $uri = "$ProjectApi/_apis/wit/workItems/$Id/comments?`$top=200&`$expand=renderedText&api-version=$CommentsApiVersion"
        if ($token) { $uri += '&continuationToken=' + [uri]::EscapeDataString([string]$token) }
        $page = Invoke-Ado -Uri $uri
        foreach ($c in @(Get-Prop $page 'comments')) { if ($null -ne $c) { $all.Add($c) } }
        $token = Get-Prop $page 'continuationToken'
    } while ($token)
    $all
}

function Format-Discussion {
    param([AllowNull()][object[]]$Comments)
    $sorted = @(@($Comments) | Where-Object { $null -ne $_ -and -not (Get-Prop $_ 'isDeleted') } |
            Sort-Object @{ Expression = { $d = ConvertTo-DateOffset -Value (Get-Prop $_ 'createdDate'); if ($d) { $d.UtcTicks } else { 0 } } }, @{ Expression = { [int](Get-Prop $_ 'id') } })
    $blocks = foreach ($c in $sorted) {
        $author = [string](Get-Prop (Get-Prop $c 'createdBy') 'displayName')
        $when = ConvertTo-DateText -Value (Get-Prop $c 'createdDate') -AsUtc:$script:UseUtc
        $rendered = [string](Get-Prop $c 'renderedText')
        $raw = if (-not [string]::IsNullOrWhiteSpace($rendered)) { $rendered } else { [string](Get-Prop $c 'text') }
        $body = if ($script:KeepHtmlMarkup) { $raw } else { ConvertFrom-Html -Html $raw }
        "[$when] ${author}: $body"
    }
    (@($blocks) -join "`n`n")
}

function Get-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)
    # Windows-invalid characters, so a file produced anywhere opens on Windows.
    ($Name -replace '[<>:"/\\|?*\x00-\x1F]', '_').Trim().TrimEnd('.')
}

function Get-OutputPath {
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$BaseName, [switch]$Overwrite)
    $path = Join-Path $Directory "$BaseName.csv"
    if ($Overwrite -or -not (Test-Path -LiteralPath $path)) { return $path }
    for ($i = 2; ; $i++) {
        $candidate = Join-Path $Directory "$BaseName ($i).csv"
        if (-not (Test-Path -LiteralPath $candidate)) {
            Write-Warning "'$BaseName.csv' already exists; writing '$BaseName ($i).csv' instead (use -Force to overwrite)."
            return $candidate
        }
    }
}

# =============================================================================================
# Main
# =============================================================================================

function Invoke-AdoWorkItemExtract {
    $script:UseUtc = [bool]$Utc
    $script:KeepHtmlMarkup = [bool]$KeepHtml
    $script:DisableFormulaGuard = [bool]$NoFormulaGuard

    if ($PSVersionTable.PSVersion.Major -lt 6) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }

    if ([string]::IsNullOrWhiteSpace($ProjectUrl)) { $ProjectUrl = Read-RequiredInput -Prompt 'Azure DevOps project URL (https://dev.azure.com/{organization}/{project})' -NoPrompt:$NonInteractive }
    $ctx = ConvertFrom-AdoProjectUrl -Url $ProjectUrl

    if ($null -eq $Pat) { $Pat = Read-RequiredInput -Prompt 'Azure DevOps PAT (input hidden)' -AsSecureString -NoPrompt:$NonInteractive }
    $plain = ConvertFrom-SecureStringPlain -SecureString $Pat
    if ([string]::IsNullOrWhiteSpace($plain)) { throw 'A non-empty PAT is required.' }
    $script:AuthHeaders = @{
        Authorization            = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$plain"))
        'X-TFS-FedAuthRedirect'  = 'Suppress'   # return 401 instead of a 203 sign-in page for a bad PAT
    }
    $plain = $null

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = (Get-Location).ProviderPath }
    if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) { throw "OutputDirectory '$OutputDirectory' does not exist." }
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath

    $commentsApiVersion = if ($ApiVersion -eq '7.1') { '7.1-preview.4' } else { '7.0-preview.3' }

    # 1. Project (validates URL, PAT and access; gives canonical project name)
    Write-Host "Connecting to $($ctx.CollectionUrl) / $($ctx.Project) ..."
    try {
        $project = Invoke-Ado -Uri ("{0}/_apis/projects/{1}?api-version={2}" -f $ctx.CollectionUrl, [uri]::EscapeDataString($ctx.Project), $ApiVersion)
    }
    catch [System.Collections.Generic.KeyNotFoundException] {
        throw "Project '$($ctx.Project)' was not found in '$($ctx.CollectionUrl)' (or the PAT cannot see it)."
    }
    $projectName = [string]$project.name
    $projectApi = '{0}/{1}' -f $ctx.CollectionUrl, [uri]::EscapeDataString($projectName)

    # 2. Fields and column mapping
    $fields = @((Invoke-Ado -Uri "$projectApi/_apis/wit/fields?api-version=$ApiVersion").value)
    $columns = @(Resolve-ExportColumn -Fields $fields -Overrides $FieldMap)

    Write-Host ''
    Write-Host 'Column mapping:'
    $columns | Select-Object Name, Match,
        @{ n = 'Field'; e = { if ($_.Field) { "$($_.Field.name) [$($_.Field.referenceName)]" } else { '' } } },
        @{ n = 'Note'; e = { $_.Note } } | Format-Table -AutoSize -Wrap | Out-String -Width 4096 | Write-Host

    $unresolved = @($columns | Where-Object { $_.Match -eq 'UNRESOLVED' })
    $mappedRefs = @($columns | Where-Object { $_.Field } | ForEach-Object { $_.Field.referenceName })
    if ($unresolved.Count -gt 0) {
        Write-Warning ("{0} column(s) did not match a field and will be empty: {1}" -f $unresolved.Count, (($unresolved | ForEach-Object { $_.Name }) -join ', '))
        $unmapped = @($fields | Where-Object { $_.referenceName -notmatch '^(System|Microsoft)\.' -and $mappedRefs -notcontains $_.referenceName } | Sort-Object name)
        if ($unmapped.Count -gt 0) {
            Write-Host 'Unmapped non-system fields available for -FieldMap:'
            $unmapped | Select-Object name, referenceName, type | Format-Table -AutoSize | Out-String -Width 4096 | Write-Host
        }
    }
    if ($ResolveFieldsOnly) { Write-Host 'ResolveFieldsOnly: no export performed.'; return }

    # 3. Work item IDs (WIQL is capped at 20,000 rows per call, so page by ID)
    $ids = [System.Collections.Generic.List[int]]::new()
    $typeClause = ''
    if ($WorkItemType) { $typeClause = " AND [System.WorkItemType] IN (" + (($WorkItemType | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', ') + ')' }
    $lastId = 0
    do {
        $wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.TeamProject] = @project AND [System.Id] > $lastId$typeClause ORDER BY [System.Id] ASC"
        $result = Invoke-Ado -Uri "$projectApi/_apis/wit/wiql?`$top=$WiqlPageSize&api-version=$ApiVersion" -Method Post -Body @{ query = $wiql }
        $page = @(@(Get-Prop $result 'workItems') | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_.id })
        foreach ($i in $page) { $ids.Add($i) }
        if ($page.Count -gt 0) { $lastId = ($page | Measure-Object -Maximum).Maximum }
    } while ($page.Count -ge $WiqlPageSize)
    Write-Host "Found $($ids.Count) work item(s) in '$projectName'."

    # 4. Work items with all fields + relations, in batches of up to 200
    $items = [System.Collections.Generic.List[object]]::new()
    for ($offset = 0; $offset -lt $ids.Count; $offset += $BatchSize) {
        $chunk = @($ids.GetRange($offset, [Math]::Min($BatchSize, $ids.Count - $offset)))
        Write-Progress -Activity 'Reading work items' -Status "$offset of $($ids.Count)" -PercentComplete ([int](100 * $offset / [Math]::Max(1, $ids.Count)))
        $batch = Invoke-Ado -Uri "$projectApi/_apis/wit/workitemsbatch?api-version=$ApiVersion" -Method Post -Body @{ ids = $chunk; '$expand' = 'Relations'; errorPolicy = 'Omit' }
        foreach ($wi in @(Get-Prop $batch 'value')) { if ($null -ne $wi) { $items.Add($wi) } }
    }
    Write-Progress -Activity 'Reading work items' -Completed
    if ($items.Count -ne $ids.Count) { Write-Warning "$($ids.Count - $items.Count) work item(s) could not be read (deleted or no permission) and are skipped." }

    # 5. Related work: titles/types/states for link targets (fetch any not already in the export, e.g. other projects)
    $lookup = @{}
    foreach ($wi in $items) {
        $f = $wi.fields
        $lookup[[int]$wi.id] = [pscustomobject]@{ Type = Get-Prop $f 'System.WorkItemType'; Title = Get-Prop $f 'System.Title'; State = Get-Prop $f 'System.State' }
    }
    $needsRelations = @($columns | Where-Object { $_.Kind -in 'RelatedWork', 'DevelopmentLinks' }).Count -gt 0
    $relationNames = @{}
    if ($needsRelations) {
        try {
            foreach ($rt in @((Invoke-Ado -Uri "$($ctx.CollectionUrl)/_apis/wit/workitemrelationtypes?api-version=$ApiVersion").value)) { $relationNames[[string]$rt.referenceName] = [string]$rt.name }
        }
        catch { Write-Warning "Could not read link type names; raw link types will be shown. $($_.Exception.Message)" }

        $missing = [System.Collections.Generic.List[int]]::new()
        foreach ($wi in $items) {
            foreach ($r in @(Get-Prop $wi 'relations')) {
                if ($null -eq $r) { continue }
                $tid = Get-WorkItemIdFromUrl -Url ([string]$r.url)
                if ($null -ne $tid -and -not $lookup.ContainsKey($tid) -and -not $missing.Contains($tid)) { $missing.Add($tid) }
            }
        }
        for ($offset = 0; $offset -lt $missing.Count; $offset += $BatchSize) {
            $chunk = @($missing.GetRange($offset, [Math]::Min($BatchSize, $missing.Count - $offset)))
            try {
                $batch = Invoke-Ado -Uri "$($ctx.CollectionUrl)/_apis/wit/workitemsbatch?api-version=$ApiVersion" -Method Post -Body @{ ids = $chunk; fields = @('System.Id', 'System.WorkItemType', 'System.Title', 'System.State'); errorPolicy = 'Omit' }
                foreach ($wi in @(Get-Prop $batch 'value')) {
                    if ($null -eq $wi) { continue }
                    $lookup[[int]$wi.id] = [pscustomobject]@{ Type = Get-Prop $wi.fields 'System.WorkItemType'; Title = Get-Prop $wi.fields 'System.Title'; State = Get-Prop $wi.fields 'System.State' }
                }
            }
            catch { Write-Warning "Could not read details for linked work items outside the project: $($_.Exception.Message)" }
        }
    }

    # 6. Build rows (comments fetched per work item; skipped when System.CommentCount is 0)
    $wantDiscussion = @($columns | Where-Object { $_.Kind -eq 'Discussion' }).Count -gt 0
    $rows = [System.Collections.Generic.List[object]]::new()
    $commentErrors = 0; $oversized = [System.Collections.Generic.List[string]]::new()
    $n = 0
    foreach ($wi in ($items | Sort-Object { [int]$_.id })) {
        $n++
        $id = [int]$wi.id
        Write-Progress -Activity 'Building rows / reading discussions' -Status "Work item $id ($n of $($items.Count))" -PercentComplete ([int](100 * $n / [Math]::Max(1, $items.Count)))
        $f = $wi.fields
        $relations = @(Get-Prop $wi 'relations')

        $discussion = ''
        if ($wantDiscussion) {
            $commentCount = Get-Prop $f 'System.CommentCount'
            if ($null -eq $commentCount -or [int]$commentCount -gt 0) {
                try { $discussion = Format-Discussion -Comments @(Get-WorkItemComment -ProjectApi $projectApi -Id $id -CommentsApiVersion $commentsApiVersion) }
                catch { $commentErrors++; $discussion = "[ERROR reading discussion: $($_.Exception.Message)]"; Write-Warning "Work item ${id}: discussion could not be read. $($_.Exception.Message)" }
            }
        }

        $row = [ordered]@{}
        foreach ($col in $columns) {
            $value = switch ($col.Kind) {
                'Field' { if ($col.Field) { if ($col.Field.referenceName -eq 'System.Id') { [string]$id } else { Format-FieldValue -Value (Get-Prop $f $col.Field.referenceName) -Field $col.Field } } else { '' } }
                'RelatedWork' { Format-RelatedWork -Relations $relations -Lookup $lookup -RelationNames $relationNames }
                'DevelopmentLinks' { Format-DevelopmentLink -Relations $relations }
                'Discussion' { $discussion }
            }
            $value = Protect-CsvText -Text ([string]$value)
            if ($value.Length -gt $script:ExcelCellLimit) { $oversized.Add("#$id '$($col.Name)' ($($value.Length) chars)") }
            $row[$col.Name] = $value
        }
        $rows.Add([pscustomobject]$row)
    }
    Write-Progress -Activity 'Building rows / reading discussions' -Completed

    # 7. Write CSV (UTF-8 with BOM so Excel shows non-ASCII correctly); write to temp then rename
    $baseName = Get-SafeFileName -Name ('ADO Extract {0}-{1}-{2}' -f $ctx.Org, $projectName, (Get-Date -Format 'yyyy-MM-dd'))
    $outPath = Get-OutputPath -Directory $OutputDirectory -BaseName $baseName -Overwrite:$Force
    $tempPath = "$outPath.partial"
    $encoding = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
    if ($rows.Count -gt 0) {
        $rows | Export-Csv -LiteralPath $tempPath -NoTypeInformation -Encoding $encoding
    }
    else {
        # Header-only file when the project has no work items
        $header = (($columns | ForEach-Object { '"' + ($_.Name -replace '"', '""') + '"' }) -join ',')
        [IO.File]::WriteAllText($tempPath, $header + [Environment]::NewLine, [Text.UTF8Encoding]::new($true))
    }
    Move-Item -LiteralPath $tempPath -Destination $outPath -Force

    if ($oversized.Count -gt 0) {
        Write-Warning ("{0} cell(s) exceed Excel's {1}-character cell limit; the CSV has the full text but Excel will truncate them: {2}" -f $oversized.Count, $script:ExcelCellLimit, (($oversized | Select-Object -First 20) -join '; '))
    }
    if ($commentErrors -gt 0) { Write-Warning "$commentErrors work item(s) have '[ERROR reading discussion ...]' in the discussion column." }
    Write-Host ''
    Write-Host "Exported $($rows.Count) work item(s) to: $outPath"
    [pscustomobject]@{ Path = $outPath; WorkItems = $rows.Count; UnresolvedColumns = @($unresolved | ForEach-Object { $_.Name }); DiscussionErrors = $commentErrors }
}

# Run unless dot-sourced (dot-sourcing loads the functions for testing).
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AdoWorkItemExtract
}
