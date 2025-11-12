<#
.SYNOPSIS
    Parallel file generation controller for DummyFileServer

.DESCRIPTION
    Startet mehrere parallele Jobs zur Erzeugung von Dummy-Dateien.
    Jeder Job arbeitet in einem eigenen Top-Level-Verzeichnis, um Konflikte zu vermeiden.

.PARAMETER RootPath
    Hauptverzeichnis für die Ausgabe

.PARAMETER ConfigPath
    Pfad zum Config-Verzeichnis (Standard: .\config)

.PARAMETER TotalTopLevelDirs
    Gesamtanzahl der Top-Level-Verzeichnisse

.PARAMETER SubLevelCount
    Anzahl der Unterverzeichnisse pro Top-Level

.PARAMETER FilesPerJob
    Anzahl der Dateien pro Job

.PARAMETER MaxParallelJobs
    Maximale Anzahl gleichzeitiger Jobs (Standard: 4)

.PARAMETER UseFsutil
    Ob fsutil verwendet werden soll (Standard: $false)

.EXAMPLE
    .\Start-ParallelGeneration.ps1 -RootPath "C:\share\testme" -TotalTopLevelDirs 10 -SubLevelCount 5 -FilesPerJob 100 -MaxParallelJobs 4
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$RootPath,
    
    [string]$ConfigPath = ".\config",
    
    [int]$TotalTopLevelDirs = 10,
    
    [int]$SubLevelCount = 5,
    
    [int]$FilesPerJob = 100,
    
    [int]$MaxParallelJobs = 4,
    
    [switch]$UseFsutil = $false,
    
    [int]$Seed = 0
)

$ErrorActionPreference = 'Stop'

# Resolve paths
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$generatorScript = Join-Path $scriptDir "Generate-DummyFiles.ps1"
$configPath = Join-Path $scriptDir $ConfigPath

if (-not (Test-Path $generatorScript)) {
    Write-Error "Generator script not found: $generatorScript"
    exit 1
}

Write-Host "=== Parallel File Generation Controller ===" -ForegroundColor Cyan
Write-Host "Root Path: $RootPath"
Write-Host "Total Top-Level Dirs: $TotalTopLevelDirs"
Write-Host "Sub-Level Count: $SubLevelCount"
Write-Host "Files Per Job: $FilesPerJob"
Write-Host "Max Parallel Jobs: $MaxParallelJobs"
Write-Host ""

# Create root directory if it doesn't exist
if (-not (Test-Path $RootPath)) {
    New-Item -ItemType Directory -Path $RootPath -Force | Out-Null
    Write-Host "Created root directory: $RootPath" -ForegroundColor Green
}

# Load directory config to get top-level directory names
$dirConfigPath = Join-Path $configPath "dir_structure.json"
$dirConfig = Get-Content $dirConfigPath -Raw | ConvertFrom-Json

# Get all available department templates
$allDepartments = @()
if ($dirConfig.topLevel.templates) {
    $allDepartments = $dirConfig.topLevel.templates
}

# Ensure we have enough departments - if not, use all available and warn
if ($allDepartments.Count -lt $TotalTopLevelDirs) {
    Write-Warning "Requested $TotalTopLevelDirs departments but only $($allDepartments.Count) available in config. Using all available departments."
    $TotalTopLevelDirs = $allDepartments.Count
}

# Take only the number we need
$departmentsToUse = $allDepartments | Select-Object -First $TotalTopLevelDirs

Write-Host "Available departments: $($departmentsToUse -join ', ')" -ForegroundColor Yellow
Write-Host ""

# Calculate how many top-level dirs per job
$dirsPerJob = [Math]::Ceiling($TotalTopLevelDirs / [double]$MaxParallelJobs)

Write-Host "Directories per job: $dirsPerJob" -ForegroundColor Yellow
Write-Host ""

# Job tracking
$jobs = @()
$jobInfo = @()

# Create jobs - each gets a unique subset of departments
$jobIndex = 0
for ($i = 0; $i -lt $TotalTopLevelDirs; $i += $dirsPerJob) {
    $jobIndex++
    $startIdx = $i
    $endIdx = [Math]::Min($i + $dirsPerJob, $TotalTopLevelDirs)
    $jobDirCount = $endIdx - $startIdx
    
    # Get unique department names for this job
    $jobDepartments = $departmentsToUse[$startIdx..($endIdx-1)]
    
    # Create a unique subdirectory for this job to work in
    $jobName = "Job$jobIndex"
    $jobPath = Join-Path $RootPath $jobName
    
    # Create a temporary config directory for this job with custom department list
    $jobConfigDir = Join-Path $env:TEMP "DummyFileServer-Job$jobIndex-$(Get-Random)"
    New-Item -ItemType Directory -Path $jobConfigDir -Force | Out-Null
    
    # Copy configs and modify dir_structure.json for this job
    Copy-Item (Join-Path $configPath "file_types.json") $jobConfigDir -Force
    Copy-Item (Join-Path $configPath "file_names.json") $jobConfigDir -Force
    Copy-Item (Join-Path $configPath "sensitive_labels.json") $jobConfigDir -Force
    
    # Create custom dir_structure.json with only this job's departments
    $customDirConfig = $dirConfig.PSObject.Copy()
    $customDirConfig.topLevel.templates = $jobDepartments
    $customDirConfig | ConvertTo-Json -Depth 10 | Out-File (Join-Path $jobConfigDir "dir_structure.json") -Encoding utf8
    
    $jobParams = @{
        RootPath = $jobPath
        DirectoryConfig = (Join-Path $jobConfigDir "dir_structure.json")
        FileTypesConfig = (Join-Path $jobConfigDir "file_types.json")
        FileNamesConfig = (Join-Path $jobConfigDir "file_names.json")
        SensitiveLabelsConfig = (Join-Path $jobConfigDir "sensitive_labels.json")
        TopLevelCount = $jobDirCount
        SubLevelCount = $SubLevelCount
        TotalOfficeFiles = $FilesPerJob
        UseFsutil = $UseFsutil.IsPresent
        Seed = if ($Seed -ne 0) { $Seed + $jobIndex } else { 0 }
    }
    
    Write-Host "Starting $jobName (Departments: $($jobDepartments -join ', '), Files: $FilesPerJob)..." -ForegroundColor Cyan
    
    $job = Start-Job -Name $jobName -ScriptBlock {
        param($ScriptPath, $Params, $TempConfigDir)
        
        try {
            # Execute the script directly with splatting to avoid XML parsing issues
            & $ScriptPath @Params | Out-String
        }
        finally {
            # Clean up temp config directory
            if (Test-Path $TempConfigDir) {
                Remove-Item $TempConfigDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
        
    } -ArgumentList $generatorScript, $jobParams, $jobConfigDir
    
    $jobs += $job
    $jobInfo += @{
        Name = $jobName
        Job = $job
        Path = $jobPath
        DirCount = $jobDirCount
        FileCount = $FilesPerJob
        StartTime = Get-Date
        Departments = $jobDepartments
        ConfigDir = $jobConfigDir
    }
}

Write-Host ""
Write-Host "Started $($jobs.Count) parallel jobs." -ForegroundColor Green
Write-Host "Monitoring progress..." -ForegroundColor Yellow
Write-Host ""

# Monitor jobs
$completed = 0
$lastUpdate = Get-Date

while ($completed -lt $jobs.Count) {
    Start-Sleep -Seconds 2
    
    # Update every 5 seconds
    if (((Get-Date) - $lastUpdate).TotalSeconds -ge 5) {
        $lastUpdate = Get-Date
        
        Write-Host "`r[$(Get-Date -Format 'HH:mm:ss')] Job Status:" -ForegroundColor Cyan
        
        foreach ($info in $jobInfo) {
            $job = $info.Job
            $elapsed = ((Get-Date) - $info.StartTime).ToString("mm\:ss")
            
            $status = $job.State
            $statusColor = switch ($status) {
                'Running' { 'Yellow' }
                'Completed' { 'Green' }
                'Failed' { 'Red' }
                default { 'Gray' }
            }
            
            $deptList = if ($info.Departments.Count -le 3) { $info.Departments -join ', ' } else { "$($info.Departments[0]), $($info.Departments[1]), ... ($($info.Departments.Count) total)" }
            Write-Host "  $($info.Name): $status | Departments: $deptList | Elapsed: $elapsed" -ForegroundColor $statusColor
        }
        
        Write-Host ""
    }
    
    # Check completion
    $completed = ($jobs | Where-Object { $_.State -ne 'Running' }).Count
}

Write-Host ""
Write-Host "=== All Jobs Completed ===" -ForegroundColor Green
Write-Host ""

# Collect results
foreach ($info in $jobInfo) {
    $job = $info.Job
    $elapsed = ((Get-Date) - $info.StartTime).ToString("mm\:ss")
    
    Write-Host "Job: $($info.Name) - $($job.State) (Duration: $elapsed)" -ForegroundColor Cyan
    Write-Host "  Departments: $($info.Departments -join ', ')" -ForegroundColor Gray
    
    if ($job.State -eq 'Completed') {
        $output = Receive-Job -Job $job
        if ($output) {
            Write-Host "  Output:" -ForegroundColor Gray
            $output | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }
        }
        
        # Check created files
        if (Test-Path $info.Path) {
            $fileCount = (Get-ChildItem -Path $info.Path -Recurse -File -ErrorAction SilentlyContinue).Count
            $dirCount = (Get-ChildItem -Path $info.Path -Recurse -Directory -ErrorAction SilentlyContinue).Count
            Write-Host "  Created: $dirCount directories, $fileCount files" -ForegroundColor Green
        }
    }
    elseif ($job.State -eq 'Failed') {
        $jobError = Receive-Job -Job $job 2>&1
        Write-Host "  Error:" -ForegroundColor Red
        $jobError | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    }
    
    # Clean up temp config dir if it still exists
    if (Test-Path $info.ConfigDir) {
        Remove-Item $info.ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    
    Remove-Job -Job $job -Force
    Write-Host ""
}

# Final summary
Write-Host ""
Write-Host "=== Final Summary ===" -ForegroundColor Cyan

if (Test-Path $RootPath) {
    $totalDirs = (Get-ChildItem -Path $RootPath -Recurse -Directory -ErrorAction SilentlyContinue).Count
    $totalFiles = (Get-ChildItem -Path $RootPath -Recurse -File -ErrorAction SilentlyContinue).Count
    $totalSizeMB = [math]::Round(((Get-ChildItem -Path $RootPath -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB), 2)
    
    Write-Host "Total Directories: $totalDirs" -ForegroundColor Green
    Write-Host "Total Files: $totalFiles" -ForegroundColor Green
    Write-Host "Total Size: $totalSizeMB MB" -ForegroundColor Green
    Write-Host ""
    Write-Host "Output Path: $RootPath" -ForegroundColor Yellow
}
else {
    Write-Host "Root path not found: $RootPath" -ForegroundColor Red
}

Write-Host ""
Write-Host "Generation completed!" -ForegroundColor Green
