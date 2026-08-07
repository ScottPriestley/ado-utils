# ================================
# CONFIGURATION
# ================================
[CmdletBinding()]
param(
    [string]$Organization,
    [SecureString]$Pat,
    [string]$ProcessId,
    [string]$OutputPath,
    [string]$LogDirectory,
    [switch]$NonInteractive
)

# $PSScriptRoot is empty in parameter defaults for a [CmdletBinding()] script
# started with powershell.exe -File, so this default is resolved here instead.
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot 'ADO_Process_Fields.csv'
}

$commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'AdoUtils.Common.psm1'
Import-Module $commonModulePath -Force
$adoRun = Initialize-AdoScriptRun -ScriptPath $PSCommandPath -LogDirectory $LogDirectory -NonInteractive:$NonInteractive
trap { Complete-AdoScriptRun -Outcome failed -ErrorRecord $_ -Operation 'process-fields'; throw }

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
$processId = Get-RequiredValue -Value $ProcessId -Prompt 'Enter the source Azure DevOps process ID' -Placeholder ''
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
$csvPath = $OutputPath
$allFields | Sort-Object ReferenceName | Export-Csv -Path $csvPath -NoTypeInformation
Write-Host "CSV export complete: $csvPath"
Complete-AdoScriptRun -Outcome succeeded -Operation 'process-fields' -Target $csvPath
