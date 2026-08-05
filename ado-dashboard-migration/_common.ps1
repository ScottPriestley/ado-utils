# Shared helpers for ADO dashboard migration scripts. Dot-source from each script.

function Get-AdoAuthHeader {
    param(
        [Parameter(Mandatory)][string]$EnvVarName,
        [string]$Purpose = "",
        [SecureString]$Pat
    )
    $role = if ($EnvVarName -eq 'ADO_SOURCE_PAT') { 'Source' } elseif ($EnvVarName -eq 'ADO_TARGET_PAT') { 'Target' } else { 'Default' }
    $resolvedPat = Resolve-AdoPat -Pat $Pat -Role $role
    return New-AdoAuthorizationHeaders -Pat $resolvedPat
}

function Invoke-Ado {
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [object]$Body = $null,
        [int]$MaxRetries = 6   # for transient ADO errors (throttling / circuit breaker / 5xx)
    )
    # Explicit charset: Windows PowerShell 5.1 and PowerShell < 7.4 encode a string
    # -Body as ASCII/ISO-8859-1 unless Content-Type carries charset=utf-8, silently
    # corrupting non-ASCII dashboard/query names, team names, or WIQL on POST.
    $args = @{ Uri = $Uri; Method = $Method; Headers = $Headers; ContentType = 'application/json; charset=utf-8' }
    if ($null -ne $Body) { $args.Body = ($Body | ConvertTo-Json -Depth 50) }
    for ($attempt = 0; ; $attempt++) {
        try {
            return Invoke-RestMethod @args
        }
        catch {
            $status = $_.Exception.Response.StatusCode.value__
            # Invoke-RestMethod puts the API's JSON error body in ErrorDetails.Message, not
            # Exception.Message. Fold it in so callers can pattern-match on things like TF237018.
            $detail = $_.ErrorDetails.Message

            # Transient: throttling (429), server errors (5xx), or ADO circuit breaker /
            # "services currently unavailable" (TF10216). Back off and retry.
            $isTransient = ($status -in 429,500,502,503,504) -or
                           ($detail -match 'TF10216|CircuitBreaker|currently unavailable|TF400733|throttl')
            if ($isTransient -and $attempt -lt $MaxRetries) {
                $wait = [math]::Min(30, [math]::Pow(2, $attempt))   # 1s,2s,4s,8s (cap 30s)
                Write-Host "  transient ADO error (status $status) - retry $($attempt + 1)/$MaxRetries in ${wait}s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
                continue
            }
            if ($status -eq 302 -or $status -eq 401 -or $status -eq 203) {
                throw "Auth failed calling $Uri - check the PAT (scope, expiry, correct org)."
            }
            if ($detail) { throw "ADO API error (status $status) calling $Uri`: $detail" }
            throw
        }
    }
}

# Every GUID-shaped token found anywhere in a widget's settings/artifact strings.
function Get-GuidsInText {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return ([regex]::Matches($Text, '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}') |
        ForEach-Object { $_.Value.ToLowerInvariant() } | Sort-Object -Unique)
}

function UrlEnc { param([string]$s) [uri]::EscapeDataString($s) }

function Read-Utf8Text {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    return [System.IO.File]::ReadAllText($resolved, [System.Text.Encoding]::UTF8)
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowEmptyString()][string]$Text
    )
    # Resolve via PowerShell's own current location, not raw .NET GetFullPath: the
    # two can silently diverge (ISE, "Run with PowerShell", detached invocations),
    # which previously made this write to a directory New-Item never created.
    $absolute = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    # Emit a BOM so Windows PowerShell 5.1 and PowerShell 7 decode artifacts
    # consistently when query names, WIQL, or dashboard settings contain Unicode.
    $encoding = [System.Text.UTF8Encoding]::new($true)
    [System.IO.File]::WriteAllText($absolute, $Text, $encoding)
}

# Accept an organization name or URL and return the bare organization name.
# Supported URL forms are https://dev.azure.com/contoso and
# https://contoso.visualstudio.com.
function Get-OrgName {
    param(
        [Parameter(Mandatory)]
        [string]$Org
    )

    $value = $Org.Trim().TrimEnd('/')
    if ($value -match '^https?://dev\.azure\.com/([^/?#]+)$') {
        return $Matches[1]
    }
    if ($value -match '^https?://([^.]+)\.visualstudio\.com$') {
        return $Matches[1]
    }
    if ($value -match '^[^/\s]+$') {
        return $value
    }

    throw "Azure DevOps organization must be an organization name or URL (for example, contoso or https://dev.azure.com/contoso)."
}
