[CmdletBinding()]
param(
    [string]$Organization,
    [SecureString]$Pat,
    [string]$LogDirectory,
    [switch]$NonInteractive
)
$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'list-organization-ids'; throw }

function Get-RequiredValue {
    param(
        [string]$Value,
        [string]$Prompt,
        [string]$Placeholder,
        [switch]$Secure
    )

    if (-not [string]::IsNullOrWhiteSpace($Value) -and $Value -ne $Placeholder) {
        return $Value
    }

    if ($Secure) {
        $secureValue = Read-AdoInput -Prompt $Prompt -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureValue)

        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            if ($bstr -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
        }
    }

    return Read-AdoInput -Prompt $Prompt
}

function Normalize-AdoOrganization {
    param(
        [Parameter(Mandatory)]
        [string]$OrganizationInput
    )

    $value = $OrganizationInput.Trim().TrimEnd('/')
    if ($value -match '^https?://dev\.azure\.com/([^/?#]+)$') {
        return $Matches[1]
    }
    if ($value -match '^https?://([^.]+)\.visualstudio\.com$') {
        return $Matches[1]
    }
    if ($value -match '^[^/\s]+$') {
        return $value
    }

    throw 'Azure DevOps organization must be an organization name or URL (for example, contoso or https://dev.azure.com/contoso).'
}

$org = Get-RequiredValue -Value $Organization -Prompt (Get-AdoPrompt SourceOrganization) -Placeholder ''
$Pat = Resolve-AdoPat -Pat $Pat -Role Source
$pat = ConvertFrom-AdoSecureString $Pat
$org = Normalize-AdoOrganization -OrganizationInput $org

$base64AuthInfo = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":$pat")
)

$url = "https://dev.azure.com/$org/_apis/work/processes?api-version=7.1-preview.2"

$response = Invoke-RestMethod -Uri $url -Method Get -Headers @{
    Authorization = "Basic $base64AuthInfo"
}

$response.value | Format-Table name, typeId, description
Complete-AdoScriptRun -Outcome succeeded -Operation 'list-organization-ids'
