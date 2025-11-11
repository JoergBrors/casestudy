# Setup-PurviewLabels.ps1
# Creates Sensitivity Labels and Sensitive Information Types in Microsoft Purview
# Based on BIS Ampel classification (Rot/Gelb/Grün)

<#
.SYNOPSIS
Creates Microsoft Purview Sensitivity Labels and Sensitive Information Types based on BIS Ampel standards.

.DESCRIPTION
This script:
1. Connects to Security & Compliance Center
2. Creates custom Sensitive Information Types (SITs) for German/European data
3. Creates Sensitivity Labels (Rot/Gelb/Grün)
4. Configures auto-labeling policies
5. Enables DLP policies for detection

.PARAMETER TenantId
Your Microsoft 365 Tenant ID

.PARAMETER AdminEmail
Global Admin or Compliance Admin email address

.EXAMPLE
.\Setup-PurviewLabels.ps1 -AdminEmail "admin@contoso.com"

.NOTES
Requires:
- Exchange Online PowerShell Module
- Security & Compliance PowerShell Module
- Global Admin or Compliance Administrator role
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$TenantId,
    
    [Parameter(Mandatory=$true)]
    [string]$AdminEmail
)

# Import required modules
Write-Host "=== Microsoft Purview Label Setup ===" -ForegroundColor Cyan
Write-Host ""

Write-Host "Checking required PowerShell modules..." -ForegroundColor Yellow

# Check and install required modules
$requiredModules = @(
    'ExchangeOnlineManagement',
    'Microsoft.Graph',
    'PnP.PowerShell'
)

foreach ($module in $requiredModules) {
    if (-not (Get-Module -ListAvailable -Name $module)) {
        Write-Host "Installing module: $module" -ForegroundColor Yellow
        Install-Module -Name $module -Force -AllowClobber -Scope CurrentUser
    }
    else {
        Write-Host "Module $module already installed" -ForegroundColor Green
    }
}

# Connect to Security & Compliance Center
Write-Host ""
Write-Host "Connecting to Security & Compliance Center..." -ForegroundColor Yellow
try {
    Connect-IPPSSession -UserPrincipalName $AdminEmail
    Write-Host "Connected successfully!" -ForegroundColor Green
}
catch {
    Write-Error "Failed to connect to Security & Compliance Center: $_"
    exit 1
}

# Load sensitive labels configuration
$scriptPath = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $scriptPath "config\sensitive_labels.json"

if (Test-Path $configPath) {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
    Write-Host "Loaded configuration from: $configPath" -ForegroundColor Green
}
else {
    Write-Error "Configuration file not found: $configPath"
    exit 1
}

Write-Host ""
Write-Host "=== Step 1: Create Custom Sensitive Information Types ===" -ForegroundColor Cyan
Write-Host ""

# Define custom SITs based on detection strings
$sitDefinitions = @()

# Extract unique patterns from config
$allPatterns = @{}
foreach ($level in $config.BIS.PSObject.Properties) {
    $levelName = $level.Name
    $detectionStrings = $level.Value.detectionStrings
    
    foreach ($pattern in $detectionStrings) {
        # Categorize patterns
        if ($pattern -match 'IBAN|DE\d{2}\s?\d{4}') {
            if (-not $allPatterns.ContainsKey('IBAN')) {
                $allPatterns['IBAN'] = @{
                    Name = "Custom German IBAN"
                    Description = "Detects German and European IBAN numbers"
                    Pattern = 'DE\d{2}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{2}|AT\d{2}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{4}'
                    Confidence = 85
                }
            }
        }
        elseif ($pattern -match 'Kreditkarte|Credit|^\d{4}[\s-]?\d{4}') {
            if (-not $allPatterns.ContainsKey('CreditCard')) {
                $allPatterns['CreditCard'] = @{
                    Name = "Custom Credit Card Extended"
                    Description = "Detects credit card numbers with various formats"
                    Pattern = '\b(?:\d{4}[\s-]?){3}\d{4}\b'
                    Confidence = 85
                }
            }
        }
        elseif ($pattern -match 'Steuer|Tax|USt-IdNr') {
            if (-not $allPatterns.ContainsKey('TaxID')) {
                $allPatterns['TaxID'] = @{
                    Name = "Custom German Tax ID"
                    Description = "Detects German tax identification numbers"
                    Pattern = 'DE\d{9}|USt-IdNr:?\s*DE\d{9}|Steuernummer:?\s*\d{2,3}[\/\s]\d{3,4}[\/\s]\d{4,5}'
                    Confidence = 85
                }
            }
        }
        elseif ($pattern -match 'Passport|Reisepass|Personalausweis') {
            if (-not $allPatterns.ContainsKey('IDCard')) {
                $allPatterns['IDCard'] = @{
                    Name = "Custom German ID Documents"
                    Description = "Detects German passport and ID card numbers"
                    Pattern = '(?:Reisepass|Passport)\s?(?:Nr\.?:?)?\s?[A-Z]\d{8}|Personalausweis:?\s?[A-Z]\d{8}'
                    Confidence = 85
                }
            }
        }
        elseif ($pattern -match 'E-?Mail|@') {
            if (-not $allPatterns.ContainsKey('Email')) {
                $allPatterns['Email'] = @{
                    Name = "Custom Email Pattern"
                    Description = "Detects email addresses with German context"
                    Pattern = '\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b'
                    Confidence = 75
                }
            }
        }
        elseif ($pattern -match 'Telefon|Phone|Mobil|\+49') {
            if (-not $allPatterns.ContainsKey('PhoneDE')) {
                $allPatterns['PhoneDE'] = @{
                    Name = "Custom German Phone Numbers"
                    Description = "Detects German phone numbers"
                    Pattern = '\+49\s?\d{2,4}\s?\d{4,10}|0\d{2,4}[\s/-]?\d{4,10}'
                    Confidence = 75
                }
            }
        }
        elseif ($pattern -match 'Personalnummer|Mitarbeiter-ID|EMP-') {
            if (-not $allPatterns.ContainsKey('EmployeeID')) {
                $allPatterns['EmployeeID'] = @{
                    Name = "Custom Employee ID"
                    Description = "Detects employee identification numbers"
                    Pattern = '(?:EMP|MA|Personalnummer|Mitarbeiter-ID)[\s:-]*\d{4,10}'
                    Confidence = 75
                }
            }
        }
        elseif ($pattern -match 'Projekt|ProjectCode|PRJ-') {
            if (-not $allPatterns.ContainsKey('ProjectCode')) {
                $allPatterns['ProjectCode'] = @{
                    Name = "Custom Project Codes"
                    Description = "Detects internal project identification codes"
                    Pattern = '(?:PRJ|ProjectCode|Projekt-ID)[\s:-]*[A-Z0-9-]{4,15}'
                    Confidence = 65
                }
            }
        }
    }
}

# Create Sensitive Information Types
Write-Host "Creating Custom Sensitive Information Types..." -ForegroundColor Yellow

foreach ($sitKey in $allPatterns.Keys) {
    $sit = $allPatterns[$sitKey]
    $sitName = $sit.Name
    
    # Check if SIT already exists
    $existing = Get-DlpSensitiveInformationType -Identity $sitName -ErrorAction SilentlyContinue
    
    if ($existing) {
        Write-Host "  SIT '$sitName' already exists - skipping" -ForegroundColor Gray
    }
    else {
        try {
            # Note: This is a simplified example - actual regex patterns need proper XML format
            Write-Host "  Creating SIT: $sitName" -ForegroundColor Yellow
            
            # For demonstration - actual implementation requires more complex XML definition
            Write-Host "    Pattern: $($sit.Pattern)" -ForegroundColor Gray
            Write-Host "    Confidence: $($sit.Confidence)%" -ForegroundColor Gray
            Write-Host "    [Note: Use Compliance Center UI or detailed XML for full implementation]" -ForegroundColor DarkYellow
            
            # Placeholder - actual command would be:
            # New-DlpSensitiveInformationType -Name $sitName -Description $sit.Description -Regex $sit.Pattern
        }
        catch {
            Write-Warning "Failed to create SIT '$sitName': $_"
        }
    }
}

Write-Host ""
Write-Host "=== Step 2: Create Sensitivity Labels ===" -ForegroundColor Cyan
Write-Host ""

# Define label hierarchy based on BIS Ampel
$labels = @(
    @{
        Name = "BIS Rot - Hoch Vertraulich"
        DisplayName = "Hoch Vertraulich (Rot)"
        Description = "Höchste Schutzstufe - Kreditkarten, Bankdaten, Sozialversicherungsnummern, Pässe"
        Priority = 3
        Color = "#D32F2F"
        ToolTip = "Nur für berechtigte Personen. Weitergabe verboten."
    },
    @{
        Name = "BIS Gelb - Vertraulich"
        DisplayName = "Vertraulich (Gelb)"
        Description = "Mittlere Schutzstufe - PII, Kontaktdaten, Personalnummern"
        Priority = 2
        Color = "#FFA000"
        ToolTip = "Nur für interne Verwendung. Vorsicht bei externer Weitergabe."
    },
    @{
        Name = "BIS Grün - Intern"
        DisplayName = "Intern (Grün)"
        Description = "Interne Schutzstufe - Projektkennungen, interne Codes"
        Priority = 1
        Color = "#388E3C"
        ToolTip = "Für interne Nutzung. Nicht öffentlich."
    }
)

Write-Host "Creating Sensitivity Labels..." -ForegroundColor Yellow

foreach ($label in $labels) {
    $labelName = $label.Name
    
    # Check if label exists
    $existing = Get-Label -Identity $labelName -ErrorAction SilentlyContinue
    
    if ($existing) {
        Write-Host "  Label '$labelName' already exists - skipping" -ForegroundColor Gray
    }
    else {
        try {
            Write-Host "  Creating Label: $labelName" -ForegroundColor Yellow
            
            New-Label `
                -DisplayName $label.DisplayName `
                -Name $labelName `
                -Comment $label.Description `
                -ToolTip $label.ToolTip `
                -Priority $label.Priority
            
            Write-Host "    Created successfully!" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to create label '$labelName': $_"
        }
    }
}

Write-Host ""
Write-Host "=== Step 3: Create Auto-Labeling Policies ===" -ForegroundColor Cyan
Write-Host ""

# Auto-labeling policy for Rot (High)
$policyNameRot = "Auto-Label BIS Rot Policy"
$existingPolicyRot = Get-AutoSensitivityLabelPolicy -Identity $policyNameRot -ErrorAction SilentlyContinue

if ($existingPolicyRot) {
    Write-Host "Auto-labeling policy '$policyNameRot' already exists" -ForegroundColor Gray
}
else {
    Write-Host "Creating auto-labeling policy: $policyNameRot" -ForegroundColor Yellow
    
    try {
        # Get the label GUID
        $labelRot = Get-Label -Identity "BIS Rot - Hoch Vertraulich"
        
        if ($labelRot) {
            New-AutoSensitivityLabelPolicy `
                -Name $policyNameRot `
                -Comment "Automatically applies 'Hoch Vertraulich' label based on sensitive content" `
                -SharePointLocation All `
                -OneDriveLocation All `
                -ExchangeLocation All `
                -Mode Simulate
            
            Write-Host "  Policy created in Simulation mode!" -ForegroundColor Green
            Write-Host "  [Note: Change to 'Enable' mode after testing]" -ForegroundColor DarkYellow
        }
    }
    catch {
        Write-Warning "Failed to create auto-labeling policy: $_"
    }
}

Write-Host ""
Write-Host "=== Step 4: Configure DLP Policies ===" -ForegroundColor Cyan
Write-Host ""

# Create DLP policy for sensitive data
$dlpPolicyName = "BIS Ampel DLP Policy"
$existingDlpPolicy = Get-DlpCompliancePolicy -Identity $dlpPolicyName -ErrorAction SilentlyContinue

if ($existingDlpPolicy) {
    Write-Host "DLP Policy '$dlpPolicyName' already exists" -ForegroundColor Gray
}
else {
    Write-Host "Creating DLP policy: $dlpPolicyName" -ForegroundColor Yellow
    
    try {
        New-DlpCompliancePolicy `
            -Name $dlpPolicyName `
            -Comment "Detects and protects BIS Ampel classified sensitive information" `
            -SharePointLocation All `
            -OneDriveLocation All `
            -ExchangeLocation All `
            -Mode TestWithNotifications
        
        Write-Host "  DLP Policy created!" -ForegroundColor Green
        
        # Add DLP Rule for high sensitivity content
        $dlpRuleName = "Block External Sharing - BIS Rot"
        
        New-DlpComplianceRule `
            -Name $dlpRuleName `
            -Policy $dlpPolicyName `
            -ContentContainsSensitiveInformation @{Name="Credit Card Number"; minCount="1"}, @{Name="International Banking Account Number (IBAN)"; minCount="1"} `
            -BlockAccess $true `
            -NotifyUser Owner `
            -NotifyUserType NotSet
        
        Write-Host "  DLP Rule created!" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to create DLP policy: $_"
    }
}

Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next Steps:" -ForegroundColor Cyan
Write-Host "1. Go to Microsoft Purview Compliance Portal: https://compliance.microsoft.com" -ForegroundColor White
Write-Host "2. Navigate to 'Information Protection' > 'Labels'" -ForegroundColor White
Write-Host "3. Publish the created labels to users" -ForegroundColor White
Write-Host "4. Navigate to 'Data Classification' > 'Sensitive info types'" -ForegroundColor White
Write-Host "5. Review and activate auto-labeling policies (change from Simulate to Enable)" -ForegroundColor White
Write-Host "6. Test with generated dummy files from DummyFileServer" -ForegroundColor White
Write-Host ""
Write-Host "Documentation: https://learn.microsoft.com/en-us/purview/sensitivity-labels" -ForegroundColor Gray
Write-Host ""

# Disconnect
Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
Write-Host "Disconnected from Security & Compliance Center" -ForegroundColor Gray
