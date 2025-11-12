<#
    SQL Query Runner v2
    Lädt alle JSON Query Definitionen aus einem Plugin-Verzeichnis
    Führt jede Query aus
    Exportiert Ergebnisse als UTF8 CSV mit Semikolon
    Stabil, robust, mit Fehlerbehandlung
#>

param(
    [string]$SqlServer = "localhost",
    [string]$Database = "FileAnalysis",
    [string]$PluginPath = ".\plugins",
    [string]$OutputPath = ".\output",

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
    New-Item -ItemType Directory -Path $OutputPath | Out-Null
}

# -----------------------------
# 2. SQL-Verbindung aufbauen
# -----------------------------
if ($UseSqlAuth) {
    $connectionString = "Server=$SqlServer;Database=$Database;User ID=$SqlUser;Password=$SqlPassword;TrustServerCertificate=True;"
}
else {
    $connectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;TrustServerCertificate=True;"
}

$connection = New-Object System.Data.SqlClient.SqlConnection $connectionString

try {
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

    Write-Host "Query: $queryName"
    Write-Host "Output: $outputFile"

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
    # 7. CSV exportieren (UTF8, ; - delimiter)
    # -----------------------------
    try {
        $csvContent = $table | ConvertTo-Csv -NoTypeInformation -Delimiter ';'
        [System.IO.File]::WriteAllLines($outputFile, $csvContent, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Exportiert: $outputFile" -ForegroundColor Green
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
