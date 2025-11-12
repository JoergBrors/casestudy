# File Scanner - SQL Server Import

Scannt Verzeichnisse und speichert alle Datei-Metadaten in einer SQL Server Datenbank.

## Quick Start

### 1. Ohne Hash-Berechnung (schnell)
```cmd
Run-FileScanner.cmd
```
oder mit eigenem Verzeichnis:
```cmd
Run-FileScanner.cmd "C:\MeinVerzeichnis"
```

### 2. Mit Hash-Berechnung SHA256 + MD5 (langsam)
```cmd
Run-FileScanner-WithHash.cmd
```
oder mit eigenem Verzeichnis:
```cmd
Run-FileScanner-WithHash.cmd "C:\MeinVerzeichnis"
```

## Konfiguration

Die CMD-Dateien enthalten folgende Konfigurationsparameter:

### Run-FileScanner.cmd (ohne Hash)
- `SCAN_ROOT`: Standard-Verzeichnis zum Scannen
- `SQL_SERVER`: SQL Server Instanz (Standard: localhost)
- `SQL_DATABASE`: Datenbank-Name (Standard: FileImportDB)
- `BATCH_SIZE`: Anzahl Dateien pro Batch-Insert (Standard: 500)
- `WORKERS`: Anzahl paralleler Worker (Standard: 4)

### Run-FileScanner-WithHash.cmd (mit Hash)
- Gleiche Parameter wie oben
- `WORKERS`: Erhöht auf 8 für parallele Hash-Berechnung
- `BATCH_SIZE`: Reduziert auf 100 wegen höherer Last
- Hash-Algorithmen: SHA256 + MD5

## Datenbank-Schema

Die Tabelle `dbo.files` enthält folgende Felder:

### Basis-Informationen
- `id` - Eindeutige ID (IDENTITY)
- `path` - Vollständiger Dateipfad (UNIQUE)
- `name` - Dateiname
- `dir` - Verzeichnis
- `extension` - Dateierweiterung
- `size` - Dateigröße in Bytes

### Zeitstempel (doppelt gespeichert)
- `mtime_unix`, `ctime_unix`, `atime_unix` - Unix Timestamps (FLOAT)
- `mtime_datetime`, `ctime_datetime`, `atime_datetime` - SQL Server DateTime2

### Attribute
- `is_readonly`, `is_hidden`, `is_system`, `is_archive` - BIT Flags
- `attributes` - Vollständiger Attribut-String

### Hash-Werte (nur mit --hash)
- `sha256` - SHA256 Hash (64 Zeichen)
- `md5` - MD5 Hash (32 Zeichen)

### Zusätzliche Metadaten
- `path_length` - Länge des Pfads
- `path_depth` - Anzahl der Verzeichnisebenen
- `owner` - Dateibesitzer (benötigt pywin32)
- `file_version` - Versionsnummer (Windows PE-Dateien)

### Scan-Information
- `scanned_at_unix` - Scan-Zeitpunkt (Unix)
- `scanned_at_datetime` - Scan-Zeitpunkt (DateTime2)

## SQL Abfragen

### Statistiken anzeigen
```sql
SELECT 
    COUNT(*) as total_files,
    SUM(size)/1024/1024 as total_MB,
    AVG(path_length) as avg_path_length,
    MAX(path_length) as max_path_length,
    COUNT(CASE WHEN path_length > 400 THEN 1 END) as paths_over_400
FROM dbo.files;
```

### Zeitstempel-Analyse
```sql
SELECT 
    name,
    size,
    mtime_datetime as modified,
    ctime_datetime as created,
    DATEDIFF(day, ctime_datetime, GETDATE()) as age_days
FROM dbo.files
ORDER BY age_days DESC;
```

### Dateien nach Extension
```sql
SELECT 
    extension,
    COUNT(*) as count,
    SUM(size)/1024/1024 as total_MB
FROM dbo.files
GROUP BY extension
ORDER BY count DESC;
```

### Längste Pfade
```sql
SELECT TOP 10
    path_length,
    path,
    name
FROM dbo.files
ORDER BY path_length DESC;
```

### Hash-Duplikate finden (nur mit Hash)
```sql
SELECT 
    sha256,
    COUNT(*) as duplicate_count,
    STRING_AGG(name, ', ') as filenames
FROM dbo.files
WHERE sha256 IS NOT NULL
GROUP BY sha256
HAVING COUNT(*) > 1;
```

## Voraussetzungen

### Python Packages
```powershell
pip install pyodbc
pip install pywin32  # Optional für owner und file_version
```

### SQL Server
- SQL Server Developer, Express, Standard oder Enterprise
- Datenbank muss bereits existieren (siehe `setup-database.sql`)

## Troubleshooting

### ODBC Driver nicht gefunden
```
ODBC driver or data source not found
```
**Lösung:** Installiere ODBC Driver 17 oder 18 für SQL Server:
https://learn.microsoft.com/en-us/sql/connect/odbc/download-odbc-driver-for-sql-server

### Verbindungsfehler
```
Cannot open database
```
**Lösung:** Führe zuerst `setup-database.sql` aus:
```cmd
sqlcmd -S localhost -E -i setup-database.sql
```

### Owner/Version Felder sind NULL
**Ursache:** pywin32 ist nicht installiert
**Lösung:** 
```powershell
pip install pywin32
```

## Leistung

### Ohne Hash
- **~1.000 Dateien/Sekunde** (abhängig von Festplatte)
- Empfohlen für initiale Scans großer Verzeichnisse

### Mit Hash
- **~100-500 Dateien/Sekunde** (abhängig von Dateigröße und CPU)
- Hash-Berechnung liest jede Datei komplett
- Bei 10.000 Dateien: 20-100 Sekunden zusätzlich
- Nutze mehr Workers (8-16) für bessere Parallelisierung

## Beispiele

### Standard-Scan des generierten Fileservers
```cmd
Run-FileScanner.cmd "C:\Repo\casestudy\DummyFileServer-Output"
```

### Mehrere Verzeichnisse scannen
```powershell
python scanner.py --roots "C:\share1" "C:\share2" "D:\data" ^
    --mssql-server localhost ^
    --mssql-database FileImportDB ^
    --batch-size 500
```

### Nur bestimmte Dateitypen
```powershell
python scanner.py --roots "C:\share" ^
    --mssql-server localhost ^
    --mssql-database FileImportDB ^
    --include "*.docx" ^
    --hash
```

### Bestimmte Dateien ausschließen
```powershell
python scanner.py --roots "C:\share" ^
    --mssql-server localhost ^
    --mssql-database FileImportDB ^
    --exclude "*.tmp"
```
