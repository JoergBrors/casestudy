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
