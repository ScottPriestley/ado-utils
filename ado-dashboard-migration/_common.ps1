# Shared helpers for ADO dashboard migration scripts. Dot-source from each script.

function Get-AdoAuthHeader {
    param(
        [Parameter(Mandatory)][string]$EnvVarName,
        [string]$Purpose = ""   # e.g. "source org 360sg" — shown in the prompt
    )
    $pat = [Environment]::GetEnvironmentVariable($EnvVarName)
    if ([string]::IsNullOrWhiteSpace($pat)) {
        $label = if ($Purpose) { "$EnvVarName ($Purpose)" } else { $EnvVarName }
        Write-Host "Environment variable `$env:$EnvVarName is not set." -ForegroundColor Yellow
        $secure = Read-Host -Prompt "Enter the Azure DevOps PAT for $label (input hidden)" -AsSecureString
        $pat = [System.Net.NetworkCredential]::new('', $secure).Password
        if ([string]::IsNullOrWhiteSpace($pat)) {
            throw "No PAT provided. Set it first:  `$env:$EnvVarName = '<pat>'  — or enter it when prompted."
        }
        # Cache for the rest of this session so later steps don't re-prompt.
        Set-Item -Path "Env:$EnvVarName" -Value $pat | Out-Null
    }
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    return @{ Authorization = "Basic $b64" }
}

function Invoke-Ado {
    param(
        [Parameter(Mandatory)][hashtable]$Headers,
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        [object]$Body = $null,
        [int]$MaxRetries = 6   # for transient ADO errors (throttling / circuit breaker / 5xx)
    )
    $args = @{ Uri = $Uri; Method = $Method; Headers = $Headers; ContentType = 'application/json' }
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
                Write-Host "  transient ADO error (status $status) — retry $($attempt + 1)/$MaxRetries in ${wait}s…" -ForegroundColor DarkYellow
                Start-Sleep -Seconds $wait
                continue
            }
            if ($status -eq 302 -or $status -eq 401 -or $status -eq 203) {
                throw "Auth failed calling $Uri — check the PAT (scope, expiry, correct org)."
            }
            if ($detail) { throw "ADO API error calling $Uri`: $detail" }
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

# Accept an org as a bare name ("360sg") or a full URL
# ("https://dev.azure.com/360sg", "https://360sg.visualstudio.com") and return
# the bare org name. Prevents the double-prefix "dangerous Request.Path" error.
function Get-OrgName {
    param([string]$Org)
    $o = "$Org".Trim().TrimEnd('/')
    if ($o -match '^https?://dev\.azure\.com/([^/]+)')  { return $Matches[1] }
    if ($o -match '^https?://([^.]+)\.visualstudio\.com') { return $Matches[1] }
    return $o
}
