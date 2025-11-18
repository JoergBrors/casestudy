$tenant='dba912b0-8fba-4882-95f0-02e9da476781'
$cid='990bc8ba-4cdb-4152-ac6c-740793084968'
$secret='ZkX8Q~c6pu-T35jtVa_RAO8rc3g6DHBlbAwxtbJR'
$drive='b!47z2fa2kOE-nHqWpGUu8yVsbnC4KYSFDnwdNPUJEe0bQ97qAaQH6RZtvaLyfoK1h'
$item='013YKIC6DKN2E62XAAKZD3E3NQFM7NZRF5'

$site='7df6bce3-a4ad-4f38-a71e-a5a9194bbcc9'

Write-Host "Requesting token..."
$token = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenant/oauth2/v2.0/token" -Body @{client_id=$cid; scope='https://graph.microsoft.com/.default'; client_secret=$secret; grant_type='client_credentials'} -ContentType 'application/x-www-form-urlencoded'
$tok = $token.access_token
$h = @{ Authorization = "Bearer $tok"; Accept = 'application/json' }

Write-Host "=== listItem?$expand=fields ==="
try {
    $r = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/drives/$drive/items/$item/listItem?`$expand=fields" -Headers $h -ErrorAction Stop
    $r | ConvertTo-Json -Depth 6 | Write-Host
} catch {
    Write-Host "listItem failed: $($_.Exception.Message)"
}

function Extract-LabelFromFields($fields) {
    $labelName = $null; $labelId = $null
    foreach ($prop in $fields.PSObject.Properties) {
        $pn = $prop.Name
        $pv = $prop.Value
        if (-not $pv) { continue }
        if ($pn -match '(?i)ComplianceTagId|SensitivityLabelId|_ComplianceTagId') { if (-not $labelId) { $labelId = $pv }; continue }
        if ($pn -match '(?i)ComplianceTag|SensitivityLabel|_ComplianceTag|_SensitivityLabel|DisplayName|_DisplayName') { if (-not $labelName) { $labelName = $pv }; continue }
        if ($pn -match '(?i)label|compliance') { if (-not $labelName) { $labelName = $pv } }
    }
    return @{ id = $labelId; name = $labelName }
}

if ($r -and $r.fields) { Write-Host 'Extracted label (drive-based):'; Extract-LabelFromFields $r.fields | ConvertTo-Json | Write-Host }

Write-Host "=== drive select sensitivityLabel ==="
try {
    $r2 = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/drives/$drive/items/$item?`$select=sensitivityLabel" -Headers $h -ErrorAction Stop
    $r2 | ConvertTo-Json -Depth 6 | Write-Host
} catch {
    Write-Host "sensitivityLabel select failed: $($_.Exception.Message)"
}
Write-Host "=== sites/.../drives/.../listItem (site-scoped) ==="
try {
    $r3 = Invoke-RestMethod -Method Get -Uri "https://graph.microsoft.com/beta/sites/$site/drives/$drive/items/$item/listItem?`$expand=fields" -Headers $h -ErrorAction Stop
    $r3 | ConvertTo-Json -Depth 6 | Write-Host
} catch {
    Write-Host "sites-based listItem failed: $($_.Exception.Message)"
}
if ($r3 -and $r3.fields) { Write-Host 'Extracted label (site-based):'; Extract-LabelFromFields $r3.fields | ConvertTo-Json | Write-Host }
