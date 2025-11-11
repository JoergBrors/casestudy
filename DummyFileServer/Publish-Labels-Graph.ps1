<#
.SYNOPSIS
  Graph API scaffold to list/create sensitivity labels and (scaffold) publish steps.

DESCRIPTION
  This script is a scaffold (starter) to help automate sensitivity label operations
  using Microsoft Graph. It contains helper functions to acquire a token via
  client credentials and to call Graph endpoints. It intentionally avoids
  performing destructive actions without review. The Graph Information Protection
  endpoints are in /beta and may change; test in a dev tenant first.

USAGE
  1) Register an Azure AD app and give it the Application permission:
       - InformationProtectionPolicy.ReadWrite.All
       - (or least-privilege set required for your scenario)
     Then grant admin consent.

  2) Set these variables and call the functions below. Example shown at the end.

NOTES
  - This is a scaffold. Confirm API payload shapes against the Microsoft Graph
    documentation for your tenant's Graph version (beta/stable) before running in prod.
  - For many label-publishing tasks there's also a portal UI (Purview / Compliance)
    which may be easier. This script is provided for automation when appropriate.
#>

param()

function Get-GraphToken-ClientCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $TenantId,
        [Parameter(Mandatory=$true)] [string] $ClientId,
        [Parameter(Mandatory=$true)] [string] $ClientSecret
    )

    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        client_id     = $ClientId
        scope         = "https://graph.microsoft.com/.default"
        client_secret = $ClientSecret
        grant_type    = "client_credentials"
    }

    $resp = Invoke-RestMethod -Method Post -Uri $tokenEndpoint -Body $body -ContentType 'application/x-www-form-urlencoded'
    if (-not $resp.access_token) {
        throw "Failed to acquire token: $($resp | ConvertTo-Json -Depth 3)"
    }
    return $resp.access_token
}

function Invoke-Graph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $AccessToken,
        [Parameter(Mandatory=$true)][string] $Method,
        [Parameter(Mandatory=$true)][string] $Uri,
        [object] $Body = $null
    )

    $headers = @{ Authorization = "Bearer $AccessToken" }
    if ($Body) {
        $json = $Body | ConvertTo-Json -Depth 10
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -Body $json -ContentType 'application/json'
    } else {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
}

function Get-Graph-Labels {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $AccessToken,
        [switch] $UseBeta
    )
    $base = if ($UseBeta) { 'https://graph.microsoft.com/beta' } else { 'https://graph.microsoft.com/v1.0' }
    # Information Protection label listing is often under /informationProtection or /informationProtection/policy
    $uri = "$base/informationProtection/policy/labels"
    return Invoke-Graph -AccessToken $AccessToken -Method Get -Uri $uri
}

function New-Graph-Label-Scaffold {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string] $AccessToken,
        [Parameter(Mandatory=$true)] [string] $DisplayName,
        [string] $Description = '',
        [switch] $UseBeta
    )

    $base = if ($UseBeta) { 'https://graph.microsoft.com/beta' } else { 'https://graph.microsoft.com/v1.0' }
    $uri = "$base/informationProtection/policy/labels"

    # Minimal payload scaffold. The Graph schema for labels is complex; consult docs and extend as needed.
    $payload = @{
        displayName = $DisplayName
        description = $Description
        isActive    = $true
        # Additional properties such as assignmentMethod, actions, and protection can be added here.
    }

    Write-Host "[INFO] Posting new label scaffold to $uri (confirm payload before running)"
    Write-Host ($payload | ConvertTo-Json -Depth 8)

    # Return the payload for review. The script intentionally does not POST by default.
    return $payload
}

function Confirm-And-Execute {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $ActionDescription,
        [Parameter(Mandatory=$true)][scriptblock] $Action,
        [switch] $Force,
        [switch] $WhatIf
    )

    Write-Host "Action: $ActionDescription"
    if ($WhatIf) {
        Write-Host "WhatIf: action not executed."
        return
    }

    if (-not $Force) {
        $yn = Read-Host "Run this action? (Y/N)"
        if ($yn -notin @('Y','y')) {
            Write-Host "Cancelled by user."
            return
        }
    }

    & $Action
}

function New-Graph-CreateFromFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $AccessToken,
        [Parameter(Mandatory=$true)][string] $Uri,
        [Parameter(Mandatory=$true)][string] $JsonFile,
        [switch] $Force,
        [switch] $WhatIf
    )

    if (-not (Test-Path $JsonFile)) { throw "Json file not found: $JsonFile" }
    $body = Get-Content -Raw -Path $JsonFile | ConvertFrom-Json

    $action = { Invoke-Graph -AccessToken $using:AccessToken -Method Post -Uri $using:Uri -Body $using:body }
    Confirm-And-Execute -ActionDescription "POST $Uri using $JsonFile" -Action $action -Force:$Force -WhatIf:$WhatIf
}

function New-Label-FromJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $AccessToken,
        [Parameter(Mandatory=$true)][string] $JsonFile,
        [switch] $UseBeta = $true,
        [switch] $Force,
        [switch] $WhatIf
    )
    $base = if ($UseBeta) { 'https://graph.microsoft.com/beta' } else { 'https://graph.microsoft.com/v1.0' }
    $uri = "$base/informationProtection/policy/labels"
    New-Graph-CreateFromFile -AccessToken $AccessToken -Uri $uri -JsonFile $JsonFile -Force:$Force -WhatIf:$WhatIf
}

function New-AutoPolicy-FromJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string] $AccessToken,
        [Parameter(Mandatory=$true)][string] $JsonFile,
        [switch] $UseBeta = $true,
        [switch] $Force,
        [switch] $WhatIf
    )
    # Auto-label policies endpoints vary; use a JSON payload and the correct endpoint for your tenant/version.
    $base = if ($UseBeta) { 'https://graph.microsoft.com/beta' } else { 'https://graph.microsoft.com/v1.0' }
    # Common locations: /informationProtection/policy/labels or other endpoints. Adjust as needed.
    $uri = "$base/informationProtection/policy/autoLabelingPolicies"
    New-Graph-CreateFromFile -AccessToken $AccessToken -Uri $uri -JsonFile $JsonFile -Force:$Force -WhatIf:$WhatIf
}

<#
Example usage (replace placeholders with real values):

    $tenant = 'contoso.onmicrosoft.com'  # or tenant GUID
    $clientId = 'YOUR_APP_ID'
    $clientSecret = 'YOUR_SECRET'

    $token = Get-GraphToken-ClientCredential -TenantId $tenant -ClientId $clientId -ClientSecret $clientSecret

    # List labels (beta recommended for label creation scenarios)
    $labels = Get-Graph-Labels -AccessToken $token -UseBeta
    $labels.value | Select-Object id, displayName

    # To create from a JSON file (dry-run):
    New-Label-FromJson -AccessToken $token -JsonFile .\scaffold-label.json -WhatIf

    # To actually create (skip prompt):
    New-Label-FromJson -AccessToken $token -JsonFile .\scaffold-label.json -Force

    # To create an auto-label policy from JSON (example endpoint):
    New-AutoPolicy-FromJson -AccessToken $token -JsonFile .\scaffold-auto-policy.json -WhatIf

#>

# If the user runs the script directly, show the example usage help.
if ($MyInvocation.InvocationName -eq '.') {
    Write-Host "Publish-Labels-Graph.ps1 is a scaffold — call the functions from another script or dot-source it. See PURVIEW-SETUP.md for guidance."
}
