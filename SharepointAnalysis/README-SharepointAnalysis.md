SharePoint Analysis Script

Overview
- This script recursively analyzes a SharePoint Drive (document library) and produces ROT classification plus sensitivity/retention label extraction.

New flags (added):
- `-ForceRest` : Prefer using direct REST calls (Invoke-RestMethod) with OAuth token instead of the Microsoft.Graph SDK. If no token present, the script will attempt to obtain one using app credentials.
- `-UseBeta` : Use Microsoft Graph `beta` endpoints for listItem and sensitivityLabel features. Default is `v1.0`.
- `-OnlyListItems` : Only query `listItem?$expand=fields` for ComplianceTag/SensitivityLabel; do not fallback to the driveItem `sensitivityLabel` facet.
- `-Parallelism` : Number of parallel workers used to fetch listItem fields / label info. Defaults to `1` (serial).
- `-RequestDelayMs` : Max random delay in milliseconds introduced per worker to smooth requests and reduce burst throttling.

Token caching
- The script caches access tokens in-memory for the duration of the run. Tokens are refreshed automatically ~60s before expiry.
- On 401 responses the script will optionally force-refresh the token and retry the request once.

Running with App-Only (Client Secret) safely
- It's recommended not to paste secrets into chat. Use an interactive prompt in your shell to run the script without leaving secrets in history:

```powershell
$clientSecret = Read-Host -AsSecureString "ClientSecret"
$plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($clientSecret))
pwsh -NoProfile -Command "& './sharepointexperiance.ps1' -SiteId '<siteId>' -DriveId '<driveId>' -AuthMode AppSecret -ClientId '<clientId>' -TenantId '<tenantId>' -ClientSecret '$plain' -ExportJson -ExportCsv -ForceRest -UseBeta -Parallelism 4 -RequestDelayMs 200"
```

Interactive run
- For interactive delegated auth use `-AuthMode Interactive`. The script will open a browser for login.

Notes
- The script uses beta APIs for listItem expansion and sensitivityLabel extraction when requested — beta APIs may change.
- For very large libraries consider increasing `-Parallelism` and `-RequestDelayMs` to optimize performance while reducing throttling.

Security
- Use KeyVault or CI secret stores for automated runs. Avoid embedding secrets in files checked into source control.
