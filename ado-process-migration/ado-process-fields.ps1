# ================================
# CONFIGURATION
# ================================
$org = "PASTE-ORG-HERE"
$pat = "PASTE-PAT-HERE"
$processId = "PASTE-PROCESS-ID-HERE"

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
