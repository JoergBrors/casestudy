<#
.SYNOPSIS
  Runner for safe label creation using Publish-Labels-Graph.ps1 scaffold.

DESCRIPTION
  This script helps you get a token, list labels and perform dry-run or confirmed
  create operations from JSON payload files. It is intentionally protective:
  - Default is WhatIf/dry-run
  - Writes require -Force

USAGE
  . .\Publish-Labels-Graph.ps1
  . .\Run-Publish-Labels.ps1

  # Example (dry-run):
  .\Run-Publish-Labels.ps1 -TenantId YOUR_TENANT -ClientId YOUR_APP -ClientSecret 'secret' -ListOnly

  # Create label from JSON (dry-run):
  .\Run-Publish-Labels.ps1 -TenantId ... -ClientId ... -ClientSecret '...' -CreateLabelJson .\scaffold-label.json -WhatIf

  # Create label from JSON (execute):
  .\Run-Publish-Labels.ps1 -TenantId ... -ClientId ... -ClientSecret '...' -CreateLabelJson .\scaffold-label.json -Force
#>

param(
    [Parameter(Mandatory=$true)] [string] $TenantId,
    [Parameter(Mandatory=$true)] [string] $ClientId,
    [Parameter(Mandatory=$true)] [string] $ClientSecret,
    [string] $CreateLabelJson = '',
    [string] $CreateAutoPolicyJson = '',
    [switch] $ListOnly,
    [switch] $WhatIf,
    [switch] $Force
)

Set-StrictMode -Version Latest

# Dot-source the scaffold functions (assumes script is in same folder)
if (-not (Get-Command -Name Get-GraphToken-ClientCredential -ErrorAction SilentlyContinue)) {
    $scriptPath = Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath 'Publish-Labels-Graph.ps1'
    if (-not (Test-Path $scriptPath)) { throw "Required scaffold not found: $scriptPath" }
    . $scriptPath
}

Write-Host "Acquiring token for tenant: $TenantId"
$token = Get-GraphToken-ClientCredential -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
if (-not $token) { throw "Failed to get token" }

if ($ListOnly) {
    Write-Host "Listing labels (beta)..."
    $labels = Get-Graph-Labels -AccessToken $token -UseBeta
    $labels.value | Select-Object id, displayName | Format-Table -AutoSize
    return
}

if ($CreateLabelJson) {
    if (-not (Test-Path $CreateLabelJson)) { throw "Label JSON not found: $CreateLabelJson" }
    Write-Host "Preparing to create label from: $CreateLabelJson"
    New-Label-FromJson -AccessToken $token -JsonFile $CreateLabelJson -UseBeta -Force:$Force -WhatIf:$WhatIf
}

if ($CreateAutoPolicyJson) {
    if (-not (Test-Path $CreateAutoPolicyJson)) { throw "Auto-policy JSON not found: $CreateAutoPolicyJson" }
    Write-Host "Preparing to create auto-label policy from: $CreateAutoPolicyJson"
    New-AutoPolicy-FromJson -AccessToken $token -JsonFile $CreateAutoPolicyJson -UseBeta -Force:$Force -WhatIf:$WhatIf
}

if (-not $CreateLabelJson -and -not $CreateAutoPolicyJson -and -not $ListOnly) {
    Write-Host "No action selected. Use -ListOnly, -CreateLabelJson, or -CreateAutoPolicyJson. Use -WhatIf for dry-run or -Force to execute.";
}
