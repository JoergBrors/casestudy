# Microsoft Purview Setup Anleitung

Diese Anleitung beschreibt, wie Sie Microsoft Purview für BIS Ampel Sensitivity Labels und DLP konfigurieren.

## Voraussetzungen

### Berechtigungen
- **Global Administrator** oder **Compliance Administrator** Rolle in Microsoft 365
- Zugriff auf Microsoft Purview Compliance Portal

### PowerShell Module
Das Setup-Skript installiert automatisch:
- `ExchangeOnlineManagement`
- `Microsoft.Graph`
- `PnP.PowerShell`

## Schnellstart

### 1. PowerShell Skript ausführen

```powershell
cd C:\Repo\casestudy\DummyFileServer
.\Setup-PurviewLabels.ps1 -AdminEmail "admin@ihredomain.com"
```

Das Skript führt folgende Aktionen aus:
- ✅ Verbindung zu Security & Compliance Center
- ✅ Erstellt Custom Sensitive Information Types (SITs)
- ✅ Erstellt Sensitivity Labels (Rot/Gelb/Grün)
- ✅ Konfiguriert Auto-Labeling Policies
- ✅ Erstellt DLP Policies

### 2. Manuelle Schritte im Purview Portal

Nach Ausführung des Skripts:

#### Schritt A: Sensitivity Labels veröffentlichen
1. Öffnen Sie: https://compliance.microsoft.com
2. Navigation: **Information Protection** > **Labels**
3. Klicken Sie auf **Publish labels**
4. Wählen Sie die erstellten Labels aus:
   - BIS Rot - Hoch Vertraulich
   - BIS Gelb - Vertraulich
   - BIS Grün - Intern
5. Wählen Sie Benutzer/Gruppen aus (z.B. "All users")
6. Konfigurieren Sie Policy-Einstellungen:
   - ☑ Users must provide justification to remove a label
   - ☑ Require users to apply a label to emails and documents
7. Geben Sie einen Namen ein: "BIS Ampel Label Policy"
8. Klicken Sie auf **Submit**

#### Schritt B: Custom Sensitive Information Types erstellen

Da die PowerShell-API für SITs begrenzt ist, erstellen Sie diese manuell:

1. Navigation: **Data Classification** > **Classifiers** > **Sensitive info types**
2. Klicken Sie auf **+ Create sensitive info type**

**Beispiel: German IBAN**
- Name: `Custom German IBAN`
- Description: `Detects German and European IBAN numbers`
- Pattern:
  ```regex
  \b(?:DE|AT|CH)\d{2}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{4}\s?\d{2}\b
  ```
- Confidence Level: **High** (85%)

**Beispiel: German Tax ID**
- Name: `Custom German Tax ID`
- Pattern:
  ```regex
  (?:DE\d{9}|USt-IdNr:?\s*DE\d{9}|Steuernummer:?\s*\d{2,3}[\/\s]\d{3,4}[\/\s]\d{4,5})
  ```
- Confidence Level: **High** (85%)

**Beispiel: German Phone Numbers**
- Name: `Custom German Phone Numbers`
- Pattern:
  ```regex
  (?:\+49\s?\d{2,4}\s?\d{4,10}|0\d{2,4}[\s/-]?\d{4,10})
  ```
- Confidence Level: **Medium** (75%)

**Beispiel: Employee ID**
- Name: `Custom Employee ID`
- Pattern:
  ```regex
  (?:EMP|MA|Personalnummer|Mitarbeiter-ID)[\s:-]*\d{4,10}
  ```
- Confidence Level: **Medium** (75%)

**Beispiel: Internal Project Codes**
- Name: `Custom Project Codes`
- Pattern:
  ```regex
  (?:PRJ|ProjectCode|Projekt-ID)[\s:-]*[A-Z0-9-]{4,15}
  ```
- Confidence Level: **Low** (65%)

#### Schritt C: Auto-Labeling Policies konfigurieren

1. Navigation: **Information Protection** > **Auto-labeling**
2. Klicken Sie auf **+ Create auto-labeling policy**

**Policy 1: BIS Rot (Hochvertraulich)**
- Name: `Auto-Label BIS Rot`
- Locations: SharePoint sites, OneDrive accounts, Exchange email
- Conditions:
  - Content contains sensitive info types:
    - Credit Card Number (min 1)
    - IBAN (min 1)
    - Custom German Tax ID (min 1)
    - International Banking Account Number (min 1)
- Actions:
  - Apply label: **BIS Rot - Hoch Vertraulich**
- Mode: **Simulation mode** (zum Testen)

### Hinweise & Warnungen vom Setup-Skript

Das Setup-Skript schreibt Hinweise und Warnungen nach Laufzeit in die Datei `purview-setup-warnings.log` im selben Ordner wie das Skript. Typische Einträge:

- "Note: Label priority (...) is not set via PowerShell..." — Die PowerShell-Module unterstützen nicht das Setzen der Label-Priorität; bitte konfigurieren Sie die Reihenfolge im Purview-Portal.
- "[Note: Use Compliance Center UI or detailed XML for full implementation of custom Sensitive Information Types]" — Die Erstellung von Custom Sensitive Information Types (SIT) per PowerShell ist komplex; das Skript protokolliert die Notwendigkeit manueller Schritte.

Sie können die Warnungen ansehen mit:

```powershell
Get-Content -Path "$(Join-Path $PSScriptRoot 'purview-setup-warnings.log')" -ErrorAction SilentlyContinue
```

Wenn Sie die Auto-Labeling Policy manuell per PowerShell erstellen möchten (z. B. weil das Skript den Label-Identifier nicht automatisch ermittelt), verwenden Sie die folgenden Schritte, um die Label-Id zu ermitteln und die Policy mit `-ApplySensitivityLabel` anzulegen:

```powershell
# 1. Label-Details anzeigen
$label = Get-Label -Identity "BIS Rot - Hoch Vertraulich"
$label | Format-List *

# 2. Extrahieren der Id (Eigenschaft kann je nach Modul 'Id' oder 'Identity' heißen)
$labelId = $label.Id
if (-not $labelId) { $labelId = $label.Identity }

# 3. Erstellen der Auto-Labeling Policy mit ApplySensitivityLabel
New-AutoSensitivityLabelPolicy -Name "Auto-Label BIS Rot Policy" -Comment "Applies BIS Rot" -ApplySensitivityLabel $labelId -SharePointLocation All -OneDriveLocation All -ExchangeLocation All -Mode Simulate
```

Hinweis: Das Skript versucht, die Label-Id zu ermitteln; falls das fehlschlägt, erscheint eine Warnung und Sie müssen die Policy manuell anlegen oder die Id selbst bestimmen.

**Policy 2: BIS Gelb (Vertraulich)**
- Name: `Auto-Label BIS Gelb`
- Conditions:
  - Content contains sensitive info types:
    - Email Address (min 2)
    - Custom German Phone Numbers (min 1)
    - Custom Employee ID (min 1)
- Actions:
  - Apply label: **BIS Gelb - Vertraulich**

**Policy 3: BIS Grün (Intern)**
- Name: `Auto-Label BIS Grün`
- Conditions:
  - Content contains sensitive info types:
    - Custom Project Codes (min 1)
  - OR Content contains keywords:
    - "Company Confidential"
    - "Internal Use Only"
    - "Nur für internen Gebrauch"
- Actions:
  - Apply label: **BIS Grün - Intern**

#### Schritt D: DLP Policies aktivieren

1. Navigation: **Data Loss Prevention** > **Policies**
2. Suchen Sie die Policy: **BIS Ampel DLP Policy**
3. Bearbeiten Sie die Policy:
   - Mode: **Test it out with policy tips** → **Turn it on immediately**
4. Fügen Sie zusätzliche Rules hinzu:

**Rule: Block External Sharing - BIS Rot**
- Conditions:
  - Content contains label: **BIS Rot - Hoch Vertraulich**
  - Content is shared with people outside my organization
- Actions:
  - Block access to content
  - Send incident reports to: admin@ihredomain.com
  - Notify users with policy tips

**Rule: Warn External Sharing - BIS Gelb**
- Conditions:
  - Content contains label: **BIS Gelb - Vertraulich**
  - Content is shared externally
- Actions:
  - Allow with justification
  - Notify users

## Testen der Konfiguration

### 1. Dummy-Dateien generieren
```cmd
cd C:\Repo\casestudy\DummyFileServer
Start-ParallelGeneration.cmd
```

### 2. Dateien nach SharePoint/OneDrive hochladen
```powershell
# Beispiel: Upload zu SharePoint
Connect-PnPOnline -Url "https://ihretenant.sharepoint.com/sites/testsite" -Interactive
Add-PnPFile -Path "C:\share\Job1\Finance\Contracts\*.docx" -Folder "Shared Documents"
```

### 3. Überprüfung

**Activity Explorer**
1. Navigation: **Data Classification** > **Activity explorer**
2. Filtern Sie nach:
   - Activity: `Sensitivity label applied`
   - Label: `BIS Rot`, `BIS Gelb`, `BIS Grün`
3. Überprüfen Sie, ob Dateien automatisch gelabelt wurden

**Content Explorer**
1. Navigation: **Data Classification** > **Content explorer**
2. Filtern Sie nach Sensitivity Labels
3. Sehen Sie, welche Inhalte klassifiziert wurden

**DLP Alerts**
1. Navigation: **Data Loss Prevention** > **Alerts**
2. Überprüfen Sie Incidents und Policy Matches

## Wichtige Hinweise

### Propagation Zeit
- **Sensitivity Labels**: 24 Stunden für vollständige Propagation
- **Auto-Labeling**: Läuft im Hintergrund, kann 7 Tage dauern
- **DLP Policies**: Wirksam innerhalb von 1-2 Stunden

### Best Practices
1. **Simulation Mode**: Testen Sie Auto-Labeling zuerst im Simulation Mode
2. **Schrittweise Rollout**: Beginnen Sie mit Pilot-Gruppen
3. **User Training**: Schulen Sie Benutzer über Label-Bedeutungen
4. **Monitoring**: Überwachen Sie Activity Explorer regelmäßig
5. **Refinement**: Passen Sie SIT-Patterns basierend auf False Positives an

### Troubleshooting

**Labels werden nicht angewendet**
- Überprüfen Sie, ob Label Policy veröffentlicht ist
- Prüfen Sie Activity Explorer für Fehler
- Warten Sie 24h für Propagation

**Auto-Labeling funktioniert nicht**
- Prüfen Sie, ob Policy im "Enable" Mode ist
- Überprüfen Sie Conditions und Patterns
- Testen Sie mit Content Explorer

**DLP blockiert nicht**
- Prüfen Sie Policy Mode (Test vs. Enforce)
- Überprüfen Sie Rule Conditions
- Testen Sie mit bekannten SIT-Patterns

## Weitere Ressourcen

## Preview: Sensitivity labels for Teams, groups and sites

If you want sensitivity labels to be visible and applied to Teams, Microsoft 365 groups and SharePoint sites, there is a Purview preview feature "Sensitivity labels for Teams, groups and sites (preview)" that must be enabled in the Compliance portal. Enabling this preview allows labels and some publishing options to propagate to Teams/Groups/Sites.

Steps to enable and verify the preview (portal):

1. Open the Microsoft Purview compliance portal: https://compliance.microsoft.com
2. Go to **Solutions > Information protection** (or search for "Sensitivity labels").
3. Look for the preview toggle named "Sensitivity labels for Teams, groups and sites (preview)" and enable it. This option may be under a Preview or Settings area depending on your tenant UI.
4. After enabling, create or publish a label and then assign or publish that label to groups/sites via the label policy UI. Label propagation may take some time to sync.

Verification checklist:

- Use `Get-Label` (PowerShell) or the portal to confirm the label exists and note its Id.
- Create a small test Team or site and check its settings to see the sensitivity label listed.
- Wait 10-15 minutes and check a test file in the Teams/SharePoint site for automatic labeling or label visibility.

If the preview toggle is not visible, your tenant may not yet have the preview features enabled by Microsoft. In that case, use the portal to create and publish labels manually and follow Microsoft documentation for the most current steps.

## Programmatic automation (Graph API) — scaffold and guidance

Full programmatic automation to create and publish sensitivity labels and policies can be done but requires:

- An Azure AD app registration with admin consent.
- The correct Graph API permissions (application-level permissions such as `InformationProtectionPolicy.ReadWrite.All` or the least-privilege set required).
- Careful testing in a dev tenant — some Graph label endpoints are in `beta` and might change.

I added a scaffold script: `Publish-Labels-Graph.ps1` in this repo. It contains helper functions to:

- Acquire an OAuth token using the client-credentials flow.
- List existing labels via the Graph API.
- Build a minimal label payload scaffold you can review before creating.

How to register an app and get credentials (summary):

1. In Azure AD, register a new app (App registrations > New registration).
2. Add a client secret (Certificates & secrets > New client secret).
3. Under API permissions, add the Microsoft Graph application permission `InformationProtectionPolicy.ReadWrite.All` and any other needed permissions. Click "Grant admin consent".
4. Save the Tenant ID, Client ID and Client Secret for use with the scaffold script.

Quick example (PowerShell) to get a token and list labels using the scaffold:

```powershell
# Update with your tenant/app values
$tenant = 'YOUR_TENANT_ID_OR_DOMAIN'
$clientId = 'YOUR_CLIENT_ID'
$clientSecret = 'YOUR_CLIENT_SECRET'

# dot-source or import the scaffold script
. .\Publish-Labels-Graph.ps1

$token = Get-GraphToken-ClientCredential -TenantId $tenant -ClientId $clientId -ClientSecret $clientSecret
$labels = Get-Graph-Labels -AccessToken $token -UseBeta
$labels.value | Select-Object id, displayName
```

To create a label from the scaffold, review the scaffold payload and then call the POST endpoint. The scaffold intentionally prints the payload and requires you to uncomment the create call after review.

Important notes:

- The script in this repo is a scaffold to help automation. Confirm endpoint URIs and payloads against Microsoft Graph docs for the exact Graph version you plan to use.
- Publishing labels to Teams/Groups/Sites may still require the preview toggle to be enabled and label policies to be configured via the portal or additional API calls. The Graph-based publishing surface can be complex and tenant-dependent.

If you want, I can now:

- a) Flesh out `Publish-Labels-Graph.ps1` to include label-publishing payloads and examples for creating auto-label policies (I will add cautionary dry-run flags and require explicit confirmation before write operations), or
- b) Keep the scaffold as-is and add a small runner script that: (1) creates a label, (2) waits for creation, (3) creates a sample auto-labeling policy referencing the label ID — I will implement safe confirmations and logging.

Tell me which you'd prefer and I will implement it next.

### Microsoft Learn
- [Sensitivity Labels Overview](https://learn.microsoft.com/en-us/purview/sensitivity-labels)
- [Auto-Labeling Policies](https://learn.microsoft.com/en-us/purview/apply-sensitivity-label-automatically)
- [DLP Policies](https://learn.microsoft.com/en-us/purview/dlp-learn-about-dlp)
- [Custom SIT](https://learn.microsoft.com/en-us/purview/create-a-custom-sensitive-information-type)

### Compliance Center
- [Purview Portal](https://compliance.microsoft.com)
- [Activity Explorer](https://compliance.microsoft.com/dataclassification?viewid=activities)
- [Content Explorer](https://compliance.microsoft.com/dataclassification?viewid=overview)

### Support
- Microsoft Support: https://support.microsoft.com
- Purview Community: https://techcommunity.microsoft.com/t5/security-compliance-and-identity/bd-p/MicrosoftSecurityandCompliance
