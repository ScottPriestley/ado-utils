$org = "PASTE-ORG-HERE"
$pat = "PASTE-PAT-HERE"

$base64AuthInfo = [Convert]::ToBase64String(
    [Text.Encoding]::ASCII.GetBytes(":$pat")
)

$url = "https://dev.azure.com/$org/_apis/work/processes?api-version=7.1-preview.2"

$response = Invoke-RestMethod -Uri $url -Method Get -Headers @{
    Authorization = "Basic $base64AuthInfo"
}

$response.value | Format-Table name, typeId, description
