# ================================
# CONFIGURATION
# ================================
$org = "PASTE-ORG-HERE"
$pat = "PASTE-PAT-HERE"
$processId = "PASTE-PROCESS-ID-HERE"

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

$org = Get-RequiredValue -Value $org -Prompt 'Source Azure DevOps organization name or URL (for example, contoso or https://dev.azure.com/contoso)' -Placeholder "PASTE-ORG-HERE"
$pat = Get-RequiredValue -Value $pat -Prompt "Enter the source Azure DevOps PAT" -Placeholder "PASTE-PAT-HERE" -Secure
$processId = Get-RequiredValue -Value $processId -Prompt "Enter the source Azure DevOps process ID" -Placeholder "PASTE-PROCESS-ID-HERE"
$org = Normalize-AdoOrganization -OrganizationInput $org

# ================================
# AUTH SETUP
# ================================
$base64AuthInfo = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":$pat")
)
# ================================
# GET ALL WORK ITEM TYPES IN PROCESS
# ================================
$witUrl = "https://dev.azure.com/$org/_apis/work/processes/$processId/workItemTypes?api-version=7.1-preview.2"
$witResponse = Invoke-RestMethod -Uri $witUrl -Method Get -Headers @{
    Authorization = "Basic $base64AuthInfo"
}
$witList = $witResponse.value
Write-Host "Found $($witList.Count) Work Item Types in this process."
# ================================
# GET FIELDS FOR EACH WIT
# ================================
$allFields = @()
foreach ($wit in $witList) {
    $fieldsUrl = "https://dev.azure.com/$org/_apis/work/processes/$processId/workItemTypes/$($wit.referenceName)/fields?api-version=7.1-preview.2"
$fieldsResponse = Invoke-RestMethod -Uri $fieldsUrl -Method Get -Headers @{
        Authorization = "Basic $base64AuthInfo"
    }
foreach ($field in $fieldsResponse.value) {
        $allFields += [PSCustomObject]@{
            WorkItemType  = $wit.name
            FieldName     = $field.name
            ReferenceName = $field.referenceName
            Type          = $field.type
            Required      = $field.required
            ReadOnly      = $field.readOnly
            Inherited     = $field.inherited
        }
    }
}
# ================================
# OUTPUT CONSOLIDATED FIELD LIST
# ================================
$allFields | Sort-Object ReferenceName | Format-Table -AutoSize
# ================================
# EXPORT TO CSV
# ================================
$csvPath = ".\ADO_Process_Fields.csv"
$allFields | Sort-Object ReferenceName | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "CSV export complete: $csvPath"
