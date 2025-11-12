@echo off
REM ===================================================================
REM File Scanner - SQL Server Import
REM Scannt Verzeichnisse und speichert Metadaten in SQL Server
REM ===================================================================

setlocal

REM Konfiguration
set SCAN_ROOT=C:\Repo\casestudy\DummyFileServer-Output
set SQL_SERVER=localhost
set SQL_DATABASE=FileImportDB
set BATCH_SIZE=500
set WORKERS=4

REM Prüfe ob Scan-Root angegeben wurde
if "%~1" neq "" set SCAN_ROOT=%~1

echo ========================================
echo File Scanner - SQL Server Import
echo ========================================
echo.
echo Scan-Verzeichnis: %SCAN_ROOT%
echo SQL Server:       %SQL_SERVER%
echo Datenbank:        %SQL_DATABASE%
echo Batch-Größe:      %BATCH_SIZE%
echo Worker:           %WORKERS%
echo.
echo Optionen:
echo   Mit Hash (SHA256+MD5):  Füge --hash Parameter hinzu
echo   Ohne Hash (schneller):  Keine zusätzlichen Parameter
echo.

REM Aktiviere virtuelle Umgebung falls vorhanden
if exist "%~dp0..\.venv\Scripts\activate.bat" (
    echo Aktiviere Python Virtual Environment...
    call "%~dp0..\.venv\Scripts\activate.bat"
)

REM Starte Scanner
echo Starte File Scanner...
echo.

python "%~dp0scanner.py" ^
    --roots "%SCAN_ROOT%" ^
    --mssql-server "%SQL_SERVER%" ^
    --mssql-database "%SQL_DATABASE%" ^
    --batch-size %BATCH_SIZE% ^
    --workers %WORKERS% ^
    %2 %3 %4 %5

if %ERRORLEVEL% equ 0 (
    echo.
    echo ========================================
    echo Scan erfolgreich abgeschlossen!
    echo ========================================
    echo.
    echo SQL Abfrage für Statistiken:
    echo sqlcmd -S %SQL_SERVER% -d %SQL_DATABASE% -E -Q "SELECT COUNT(*) as total_files, SUM(size) as total_bytes, AVG(path_length) as avg_path_len, MAX(path_length) as max_path_len FROM dbo.files"
) else (
    echo.
    echo ========================================
    echo FEHLER: Scanner ist fehlgeschlagen!
    echo Error Code: %ERRORLEVEL%
    echo ========================================
)

endlocal
pause
