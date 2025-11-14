<#
    SQL Query Runner v2
    Lädt alle JSON Query Definitionen aus einem Plugin-Verzeichnis
    Führt jede Query aus
    Exportiert Ergebnisse als UTF8 CSV mit Semikolon
    Stabil, robust, mit Fehlerbehandlung
#>

param(
    [string]$SqlServer = "localhost",
    [string]$Database = "FileImportDB",
    [string]$PluginPath = ".\plugins",
    [string]$OutputPath = "$PSScriptRoot\output",

    # Optional: SQL Auth
    [switch]$UseSqlAuth,
    [string]$SqlUser,
    [string]$SqlPassword
)

Write-Host "`nSQL Query Runner v2 gestartet..." -ForegroundColor Cyan

# -----------------------------
# 1. Verzeichnisprüfungen
# -----------------------------
if (!(Test-Path $PluginPath)) {
    Write-Host "FEHLER: Plugin-Verzeichnis nicht gefunden: $PluginPath" -ForegroundColor Red
    exit 1
}

if (!(Test-Path $OutputPath)) {
    Write-Host "Output-Verzeichnis wird erstellt: $OutputPath" -ForegroundColor Yellow
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

# -----------------------------
# 2. SQL-Verbindung aufbauen
# -----------------------------
if ($UseSqlAuth) {
    $connectionString = "Server=$SqlServer;Database=$Database;User ID=$SqlUser;Password=$SqlPassword;Encrypt=Yes;TrustServerCertificate=Yes;Timeout=30;"
}
else {
    $connectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;Encrypt=Yes;TrustServerCertificate=Yes;Timeout=30;"
}

Write-Host "Verbindungsstring: Server=$SqlServer, Database=$Database" -ForegroundColor Gray

$connection = New-Object System.Data.SqlClient.SqlConnection $connectionString

try {
    Write-Host "Verbinde mit SQL Server..." -ForegroundColor Gray
    $connection.Open()
    Write-Host "Verbunden mit SQL Server: $SqlServer / $Database" -ForegroundColor Green
}
catch {
    Write-Host "`nFEHLER: SQL-Login fehlgeschlagen!" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

# -----------------------------
# 3. JSON-Plugins laden
# -----------------------------
$jsonFiles = Get-ChildItem -Path $PluginPath -Filter *.json

if ($jsonFiles.Count -eq 0) {
    Write-Host "Keine Plugin-Dateien gefunden!" -ForegroundColor Yellow
    exit 0
}

# -----------------------------
# 4. Plugin-Loop
# -----------------------------
foreach ($jsonFile in $jsonFiles) {

    Write-Host "`n-------------------------------------------"
    Write-Host "Lade Plugin: $($jsonFile.Name)" -ForegroundColor Yellow

    # JSON lesen & validieren
    try {
        $plugin = Get-Content $jsonFile.FullName -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "FEHLER: JSON ungültig → Datei wird übersprungen." -ForegroundColor Red
        continue
    }

    if (-not $plugin.query -or -not $plugin.output) {
        Write-Host "FEHLER: JSON-Definition unvollständig → 'query' oder 'output' fehlt." -ForegroundColor Red
        continue
    }

    $queryName  = $plugin.name
    $querySql   = $plugin.query
    $outputFile = Join-Path $OutputPath $plugin.output
    
    # CSV-Einstellungen aus JSON (Defaults: Semikolon + UTF8)
    $delimiter = if ($plugin.delimiter) { $plugin.delimiter } else { ";" }
    $encoding = if ($plugin.encoding) { $plugin.encoding } else { "UTF8" }
    $useQuotes = if ($null -ne $plugin.useQuotes) { $plugin.useQuotes } else { $true }

    # Stelle sicher, dass Output-Verzeichnis existiert (falls relativer Pfad in output)
    $outputDir = Split-Path $outputFile -Parent
    if (!(Test-Path $outputDir)) {
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    Write-Host "Query: $queryName"
    Write-Host "Output: $outputFile (Delimiter: '$delimiter', Encoding: $encoding)"

    # SQL Kommando vorbereiten
    $command = $connection.CreateCommand()
    $command.CommandText = $querySql

    $table = New-Object System.Data.DataTable
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command

    # -----------------------------
    # 5. Query ausführen mit Fehlerbehandlung
    # -----------------------------
    try {
        $adapter.Fill($table) | Out-Null
    }
    catch {
        Write-Host "SQL-Fehler: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "→ Plugin wird übersprungen." -ForegroundColor DarkYellow
        continue
    }

    # -----------------------------
    # 6. Keine Daten? → überspringen
    # -----------------------------
    if ($table.Rows.Count -eq 0) {
        Write-Host "WARNUNG: Query lieferte keine Daten → CSV wird NICHT erstellt." -ForegroundColor Yellow
        continue
    }

    # -----------------------------
    # 7. CSV exportieren (mit konfigurierbarem Delimiter + Encoding)
    # -----------------------------
    try {
        if ($useQuotes) {
            # Standard CSV mit Quotes
            $csvContent = $table | ConvertTo-Csv -NoTypeInformation -Delimiter $delimiter
        }
        else {
            # Migration Manager Format: Keine Quotes, nur Kommas
            # Erstelle Header mit leeren Spaltennamen für Column2 und Column3
            $headerParts = @()
            foreach ($col in $table.Columns) {
                if ($col.ColumnName -eq 'Column2' -or $col.ColumnName -eq 'Column3') {
                    $headerParts += ''
                }
                else {
                    $headerParts += $col.ColumnName
                }
            }
            $header = $headerParts -join $delimiter
            $csvLines = @($header)
            foreach ($row in $table.Rows) {
                $line = ($row.ItemArray | ForEach-Object { 
                    if ($null -eq $_ -or $_ -eq [DBNull]::Value) { "" } else { $_.ToString() }
                }) -join $delimiter
                $csvLines += $line
            }
            $csvContent = $csvLines
        }
        
        # Encoding-Objekt erstellen basierend auf Konfiguration
        $encodingObj = switch ($encoding.ToUpper()) {
            "UTF8"    { [System.Text.UTF8Encoding]::new($false) }
            "UTF8BOM" { [System.Text.UTF8Encoding]::new($true) }
            "ASCII"   { [System.Text.ASCIIEncoding]::new() }
            "UNICODE" { [System.Text.UnicodeEncoding]::new() }
            default   { [System.Text.UTF8Encoding]::new($false) }
        }
        
        [System.IO.File]::WriteAllLines($outputFile, $csvContent, $encodingObj)
        Write-Host "Exportiert: $outputFile ($($table.Rows.Count) Zeilen)" -ForegroundColor Green
    }
    catch {
        Write-Host "FEHLER beim Schreiben der CSV-Datei!" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        continue
    }
}

# -----------------------------
# 8. Verbindung schließen
# -----------------------------
$connection.Close()

Write-Host "`nAlle Queries erfolgreich verarbeitet!" -ForegroundColor Cyan
Write-Host "-------------------------------------------"
