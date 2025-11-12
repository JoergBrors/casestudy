@echo off
REM ===================================================================
REM File Scanner - SQL Server Import (MIT HASH-Berechnung)
REM Scannt Verzeichnisse inkl. SHA256 + MD5 Hash
REM ACHTUNG: Hash-Berechnung ist langsam bei vielen/großen Dateien!
REM ===================================================================

setlocal

REM Konfiguration
set SCAN_ROOT=C:\Repo\casestudy\DummyFileServer-Output
set SQL_SERVER=localhost
set SQL_DATABASE=FileImportDB
set BATCH_SIZE=100
set WORKERS=8

REM Prüfe ob Scan-Root angegeben wurde
if "%~1" neq "" set SCAN_ROOT=%~1

echo ========================================
echo File Scanner - SQL Server Import
echo MIT HASH-BERECHNUNG (SHA256 + MD5)
echo ========================================
echo.
echo Scan-Verzeichnis: %SCAN_ROOT%
echo SQL Server:       %SQL_SERVER%
echo Datenbank:        %SQL_DATABASE%
echo Batch-Größe:      %BATCH_SIZE%
echo Worker:           %WORKERS%
echo Hash:             SHA256 + MD5 aktiviert
echo.
echo HINWEIS: Hash-Berechnung kann bei vielen Dateien
echo          mehrere Minuten dauern!
echo.

REM Aktiviere virtuelle Umgebung falls vorhanden
if exist "%~dp0..\.venv\Scripts\activate.bat" (
    echo Aktiviere Python Virtual Environment...
    call "%~dp0..\.venv\Scripts\activate.bat"
)

REM Starte Scanner mit Hash
echo Starte File Scanner mit Hash-Berechnung...
echo.

python "%~dp0scanner.py" ^
    --roots "%SCAN_ROOT%" ^
    --mssql-server "%SQL_SERVER%" ^
    --mssql-database "%SQL_DATABASE%" ^
    --batch-size %BATCH_SIZE% ^
    --workers %WORKERS% ^
    --hash

if %ERRORLEVEL% equ 0 (
    echo.
    echo ========================================
    echo Scan erfolgreich abgeschlossen!
    echo ========================================
    echo.
    echo SQL Abfragen:
    echo.
    echo Statistiken:
    echo sqlcmd -S %SQL_SERVER% -d %SQL_DATABASE% -E -Q "SELECT COUNT(*) as files, SUM(size)/1024/1024 as total_MB, AVG(path_length) as avg_path, MAX(path_length) as max_path FROM dbo.files"
    echo.
    echo Dateien mit Hash:
    echo sqlcmd -S %SQL_SERVER% -d %SQL_DATABASE% -E -Q "SELECT TOP 5 name, LEFT(sha256,16) as sha256, LEFT(md5,16) as md5 FROM dbo.files WHERE sha256 IS NOT NULL"
) else (
    echo.
    echo ========================================
    echo FEHLER: Scanner ist fehlgeschlagen!
    echo Error Code: %ERRORLEVEL%
    echo ========================================
)

endlocal
pause
