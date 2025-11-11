@echo off
REM ========================================
REM Parallel Dummy File Generation Launcher
REM ========================================

setlocal enabledelayedexpansion

echo.
echo ================================================
echo   Dummy FileServer - Parallel Generation
echo ================================================
echo.

REM Configuration
set "ROOT_PATH=C:\share\"
set "TOTAL_DIRS=100"
set "SUB_LEVELS=5"
set "FILES_PER_JOB=500"
set "MAX_JOBS=10"

REM Check if parameters are provided
if not "%~1"=="" set "ROOT_PATH=%~1"
if not "%~2"=="" set "TOTAL_DIRS=%~2"
if not "%~3"=="" set "SUB_LEVELS=%~3"
if not "%~4"=="" set "FILES_PER_JOB=%~4"
if not "%~5"=="" set "MAX_JOBS=%~5"

echo Configuration:
echo   Root Path:          %ROOT_PATH%
echo   Total Directories:  %TOTAL_DIRS%
echo   Sub-Levels:         %SUB_LEVELS%
echo   Files Per Job:      %FILES_PER_JOB%
echo   Max Parallel Jobs:  %MAX_JOBS%
echo.

REM Get script directory
set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Start-ParallelGeneration.ps1"

REM Check if PowerShell script exists
if not exist "%PS_SCRIPT%" (
    echo ERROR: PowerShell script not found: %PS_SCRIPT%
    pause
    exit /b 1
)

echo Starting parallel generation...
echo.

REM Run PowerShell script
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '%PS_SCRIPT%' -RootPath '%ROOT_PATH%' -TotalTopLevelDirs %TOTAL_DIRS% -SubLevelCount %SUB_LEVELS% -FilesPerJob %FILES_PER_JOB% -MaxParallelJobs %MAX_JOBS% -UseFsutil:$false"

set "EXIT_CODE=%ERRORLEVEL%"

echo.
if %EXIT_CODE% EQU 0 (
    echo ================================================
    echo   Generation completed successfully!
    echo ================================================
) else (
    echo ================================================
    echo   Generation failed with error code: %EXIT_CODE%
    echo ================================================
)

echo.
echo Press any key to view job status and logs...
pause >nul

REM Show job info
echo.
echo ================================================
echo   Job Status Information
echo ================================================
echo.

REM List PowerShell jobs
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Job | Format-Table -AutoSize"

echo.
echo Would you like to see job details? (Y/N)
set /p "SHOW_DETAILS="

if /i "%SHOW_DETAILS%"=="Y" (
    echo.
    echo ================================================
    echo   Detailed Job Information
    echo ================================================
    echo.
    
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Job | ForEach-Object { Write-Host 'Job:' $_.Name '-' $_.State; if ($_.State -eq 'Completed') { Receive-Job -Job $_ | Select-Object -First 50 }; Write-Host '' }"
)

echo.
echo Would you like to clean up completed jobs? (Y/N)
set /p "CLEANUP="

if /i "%CLEANUP%"=="Y" (
    echo.
    echo Cleaning up jobs...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-Job | Remove-Job -Force"
    echo Jobs cleaned up.
)

echo.
echo ================================================
echo   Output Location: %ROOT_PATH%
echo ================================================
echo.

REM Open output folder option
echo Would you like to open the output folder? (Y/N)
set /p "OPEN_FOLDER="

if /i "%OPEN_FOLDER%"=="Y" (
    if exist "%ROOT_PATH%" (
        explorer "%ROOT_PATH%"
    ) else (
        echo Output folder does not exist: %ROOT_PATH%
    )
)

echo.
pause
