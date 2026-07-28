$org = "PASTE-ORG-HERE"
$pat = "PASTE-PAT-HERE"

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
        $secureValue = Read-Host -Prompt $Prompt -AsSecureString
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

    return Read-Host -Prompt $Prompt
}

function Normalize-AdoOrganization {
    param(
        [Parameter(Mandatory)]
        [string]$OrganizationInput
    )

    $trimmedInput = $OrganizationInput.Trim()

    if ($trimmedInput -match '^[a-z]+://') {
        $uri = [Uri]$trimmedInput
        $pathSegments = $uri.AbsolutePath.Trim('/') -split '/'

        if ($uri.Host -ieq 'dev.azure.com' -and $pathSegments.Count -ge 1) {
            return $pathSegments[0]
        }

        if ($uri.Host -match '^[^.]+\.visualstudio\.com$') {
            return ($uri.Host -split '\.')[0]
        }
    }

    return $trimmedInput.Trim('/')
}

$org = Get-RequiredValue -Value $org -Prompt "Enter the source Azure DevOps organization name or URL" -Placeholder "PASTE-ORG-HERE"
$pat = Get-RequiredValue -Value $pat -Prompt "Enter the source Azure DevOps PAT" -Placeholder "PASTE-PAT-HERE" -Secure
$org = Normalize-AdoOrganization -OrganizationInput $org

$base64AuthInfo = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":$pat")
)

$url = "https://dev.azure.com/$org/_apis/work/processes?api-version=7.1-preview.2"

$response = Invoke-RestMethod -Uri $url -Method Get -Headers @{
    Authorization = "Basic $base64AuthInfo"
}

$response.value | Format-Table name, typeId, description
