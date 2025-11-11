# Dummy FileServer — Dummy file generator for DLP testing

Dieses Repository enthält ein PowerShell-Skript, das zufällige Dummy-Dateien und Verzeichnisse erzeugt. Ziel ist das Erzeugen realistischer Testdaten für File-Server-Tests und DLP (z. B. Microsoft Purview).

## Wichtige Artefakte

### Haupt-Skripte
- `Generate-DummyFiles.ps1`: Hauptskript für sequentielle Generierung
- `Start-ParallelGeneration.ps1`: Controller für parallele Generierung mit mehreren Jobs
- `Start-ParallelGeneration.cmd`: Batch-Datei zum einfachen Starten der parallelen Generierung
- `Manage-Jobs.ps1`: Hilfsskript zum Verwalten, Überwachen und Stoppen von Jobs

### Konfigurationsdateien
- `config/dir_structure.json`: Verzeichnisvorlagen (Top/Ebene, Subebene)
- `config/file_types.json`: Dateitypen mit Größen (minKB, maxKB)
- `config/file_names.json`: Dateinamens-Vorlagen und Beispielwerte
- `config/sensitive_labels.json`: BIS Ampel (Rot/Gelb/Grün) mit Detektionsmustern

### Weitere Skripte
- `verify-output.ps1`: Prüfung und Statistik der erzeugten Dateien
- `sample-run.ps1`: Beispielaufruf für einfache Generierung
- `tests/Run-Quick-Test.ps1`: Schneller Test der Funktionalität

## Grundlegendes Verhalten
- Das Skript erzeugt Top-Level-Verzeichnisse (Default 10) und Subverzeichnisse (Default 5)
- Standard Office Dateien (docx/xlsx/pptx) werden bevorzugt erzeugt; insgesamt werden standardmäßig ~100 Office-Dateien generiert
- Das Skript erzeugt echte, minimal valide `.docx` Dateien für Office-Dokumente. Dadurch sind sensible Inhalte in `word/document.xml` enthalten und DLP-Scanner, die in ZIP/OOXML-Dateien suchen, können diese erkennen
- Optional wird `fsutil file createnew` verwendet, um Dateien einer bestimmten Größe zu erstellen. Falls `fsutil` nicht verfügbar ist oder nicht funktioniert, fällt das Skript auf einen PowerShell-Fallback zurück, der die Datei mit zufälligen Bytes schreibt
- Es gibt eine Möglichkeit, sensitive Strings in Dateien zu injizieren, gemäß den BIS Ampel Vorgaben (Rot/Gelb/Grün). Diese dienen dazu, DLP-Policies zu testen
- **NEU**: Parallele Generierung mit mehreren Jobs für schnellere Erzeugung großer Datenmengen

## Schnellstart

### Einfache Verwendung (Sequentiell)
```powershell
PowerShell -ExecutionPolicy Bypass -File .\Generate-DummyFiles.ps1 -RootPath C:\share\testme -TopLevelCount 10 -SubLevelCount 5 -TotalOfficeFiles 100 -UseFsutil:$false
```

### Parallele Verwendung (Empfohlen für große Datenmengen)

**Mit CMD-Datei (einfachste Methode):**
```cmd
Start-ParallelGeneration.cmd
```
oder mit eigenen Parametern:
```cmd
Start-ParallelGeneration.cmd "C:\share\testme" 10 5 100 4
```
Parameter: RootPath, TotalDirs, SubLevels, FilesPerJob, MaxJobs

**Mit PowerShell direkt:**
```powershell
PowerShell -ExecutionPolicy Bypass -File .\Start-ParallelGeneration.ps1 -RootPath "C:\share\testme" -TotalTopLevelDirs 10 -SubLevelCount 5 -FilesPerJob 100 -MaxParallelJobs 4
```

### Job-Verwaltung

**Jobs auflisten:**
```powershell
PowerShell -ExecutionPolicy Bypass -File .\Manage-Jobs.ps1 -Action List
```

**Jobs überwachen (Live):**
```powershell
PowerShell -ExecutionPolicy Bypass -File .\Manage-Jobs.ps1 -Action Monitor
```

**Einzelnen Job stoppen:**
```powershell
PowerShell -ExecutionPolicy Bypass -File .\Manage-Jobs.ps1 -Action Stop -JobName Job1
```

**Alle Jobs stoppen:**
```powershell
PowerShell -ExecutionPolicy Bypass -File .\Manage-Jobs.ps1 -Action StopAll
```

**Jobs aufräumen:**
```powershell
PowerShell -ExecutionPolicy Bypass -File .\Manage-Jobs.ps1 -Action CleanUp
```

**Job-Logs exportieren:**
```powershell
PowerShell -ExecutionPolicy Bypass -File .\Manage-Jobs.ps1 -Action Export -ExportPath "C:\logs"
```

Optionen (ausführliche)
- `-RootPath` Zielverzeichnis
- `-DirectoryConfig` Pfad zur JSON-Datei mit Templates für Verzeichnisnamen
- `-FileTypesConfig` Datei mit Dateitypen und Größen
- `-FileNamesConfig` Datei mit Beispielen/ Vorlagen für Dateinamen
- `-SensitiveLabelsConfig` JSON mit Sensitivity (BIS Ampel) - detection strings
- `-TopLevelCount`, `-SubLevelCount` Anzahl Level erzeugen
- `-TotalOfficeFiles` Ungefähr gewünschte Anzahl Office-Dateien
- `-UseFsutil` (Switch) Nutze fsutil falls vorhanden, sonst fallback
- `-Seed` Reproduzierbares Seed
- `-DryRun` Keine Dateien erstellen, nur ausgeben

Hinweise
- `fsutil` erfordert auf Windows oft Administratorrechte. Falls Sie keine Admin-Rechte haben oder `fsutil` nicht verfügbar ist, nutzt das Skript einen Fallback. Filesize wird dabei ebenfalls exakt eingehalten.
- DLP Detection: Putzen Sie die config/sensitive_labels.json nach Bedarf; fügen Sie Muster/Zeichenfolgen hinzu, die Ihre DLP-Policies erkennen sollen.

Tests
- `tests/Run-Quick-Test.ps1` - ein kleiner Testlauf, der das Skript einmal mit einem Label ausführt, welches garantiert in mindestens einer Datei injiziert wird, und anschliessend prüft, ob die verify-Script-Scan-Funktion sensitve Strings findet.
Run-Quick-Test verwenden:
```
PowerShell -ExecutionPolicy Bypass -File .\tests\Run-Quick-Test.ps1
```

Vorschläge / Nächste Schritte
- Sie möchten mehr realistische Inhalte in Office-Dateien (z. B. echte .docx text), dann könnte das Skript erweitert werden, indem man docx Text-Templates mit c#-lib oder python-Docx einbindet.
- Add Pester tests to verify file counts and naming patterns (optional)
