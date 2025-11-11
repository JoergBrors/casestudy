<#
.SYNOPSIS
    Job management utility for parallel file generation

.DESCRIPTION
    Provides functions to monitor, stop, and clean up parallel generation jobs

.EXAMPLE
    .\Manage-Jobs.ps1 -Action List
    .\Manage-Jobs.ps1 -Action Stop -JobName Job1
    .\Manage-Jobs.ps1 -Action StopAll
    .\Manage-Jobs.ps1 -Action CleanUp
#>

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('List', 'Stop', 'StopAll', 'CleanUp', 'Monitor', 'Export')]
    [string]$Action,
    
    [string]$JobName,
    
    [string]$ExportPath = ".\job-logs"
)

function Show-JobList {
    Write-Host "`n=== Current PowerShell Jobs ===" -ForegroundColor Cyan
    $jobs = Get-Job
    
    if ($jobs.Count -eq 0) {
        Write-Host "No jobs found." -ForegroundColor Yellow
        return
    }
    
    $jobs | Format-Table -AutoSize Id, Name, State, HasMoreData, Location, Command
    
    Write-Host "`nTotal Jobs: $($jobs.Count)" -ForegroundColor Green
    Write-Host "Running: $(($jobs | Where-Object {$_.State -eq 'Running'}).Count)" -ForegroundColor Yellow
    Write-Host "Completed: $(($jobs | Where-Object {$_.State -eq 'Completed'}).Count)" -ForegroundColor Green
    Write-Host "Failed: $(($jobs | Where-Object {$_.State -eq 'Failed'}).Count)" -ForegroundColor Red
}

function Stop-SpecificJob {
    param([string]$Name)
    
    $job = Get-Job -Name $Name -ErrorAction SilentlyContinue
    
    if (-not $job) {
        Write-Host "Job '$Name' not found." -ForegroundColor Red
        return
    }
    
    Write-Host "Stopping job: $Name..." -ForegroundColor Yellow
    Stop-Job -Name $Name -ErrorAction SilentlyContinue
    
    Start-Sleep -Seconds 2
    
    $job = Get-Job -Name $Name
    Write-Host "Job '$Name' state: $($job.State)" -ForegroundColor Cyan
}

function Stop-AllJobs {
    $jobs = Get-Job
    
    if ($jobs.Count -eq 0) {
        Write-Host "No jobs to stop." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Stopping $($jobs.Count) jobs..." -ForegroundColor Yellow
    
    foreach ($job in $jobs) {
        Write-Host "  Stopping: $($job.Name)..." -ForegroundColor Gray
        Stop-Job -Job $job -ErrorAction SilentlyContinue
    }
    
    Start-Sleep -Seconds 2
    
    Write-Host "All jobs stopped." -ForegroundColor Green
    Show-JobList
}

function Clean-UpJobs {
    $jobs = Get-Job
    
    if ($jobs.Count -eq 0) {
        Write-Host "No jobs to clean up." -ForegroundColor Yellow
        return
    }
    
    Write-Host "Cleaning up $($jobs.Count) jobs..." -ForegroundColor Yellow
    
    foreach ($job in $jobs) {
        Write-Host "  Removing: $($job.Name) ($($job.State))..." -ForegroundColor Gray
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    
    Write-Host "All jobs removed." -ForegroundColor Green
}

function Monitor-Jobs {
    Write-Host "`n=== Job Monitor ===" -ForegroundColor Cyan
    Write-Host "Press Ctrl+C to exit monitoring`n" -ForegroundColor Yellow
    
    try {
        while ($true) {
            Clear-Host
            Write-Host "=== Job Monitor [$(Get-Date -Format 'HH:mm:ss')] ===" -ForegroundColor Cyan
            Write-Host ""
            
            $jobs = Get-Job
            
            if ($jobs.Count -eq 0) {
                Write-Host "No jobs found." -ForegroundColor Yellow
                break
            }
            
            foreach ($job in $jobs) {
                $statusColor = switch ($job.State) {
                    'Running' { 'Yellow' }
                    'Completed' { 'Green' }
                    'Failed' { 'Red' }
                    'Stopped' { 'Gray' }
                    default { 'White' }
                }
                
                Write-Host "$($job.Name): " -NoNewline
                Write-Host "$($job.State)" -ForegroundColor $statusColor
                
                if ($job.HasMoreData) {
                    $output = Receive-Job -Job $job -Keep | Select-Object -Last 3
                    if ($output) {
                        $output | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
                    }
                }
            }
            
            Write-Host ""
            $runningCount = ($jobs | Where-Object {$_.State -eq 'Running'}).Count
            if ($runningCount -eq 0) {
                Write-Host "All jobs completed!" -ForegroundColor Green
                break
            }
            
            Write-Host "Running jobs: $runningCount" -ForegroundColor Yellow
            
            Start-Sleep -Seconds 5
        }
    }
    catch {
        Write-Host "`nMonitoring stopped." -ForegroundColor Yellow
    }
}

function Export-JobLogs {
    param([string]$Path)
    
    $jobs = Get-Job
    
    if ($jobs.Count -eq 0) {
        Write-Host "No jobs to export." -ForegroundColor Yellow
        return
    }
    
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    
    Write-Host "Exporting job logs to: $Path" -ForegroundColor Cyan
    
    foreach ($job in $jobs) {
        $logFile = Join-Path $Path "$($job.Name)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        
        $output = Receive-Job -Job $job -Keep
        
        $logContent = @"
=== Job: $($job.Name) ===
State: $($job.State)
Start Time: $($job.PSBeginTime)
End Time: $($job.PSEndTime)

=== Output ===
$($output | Out-String)
"@
        
        $logContent | Out-File -FilePath $logFile -Encoding UTF8
        Write-Host "  Exported: $logFile" -ForegroundColor Green
    }
    
    Write-Host "Export completed." -ForegroundColor Green
}

# Execute action
switch ($Action) {
    'List' {
        Show-JobList
    }
    'Stop' {
        if (-not $JobName) {
            Write-Host "ERROR: -JobName parameter required for Stop action." -ForegroundColor Red
            exit 1
        }
        Stop-SpecificJob -Name $JobName
    }
    'StopAll' {
        Stop-AllJobs
    }
    'CleanUp' {
        Clean-UpJobs
    }
    'Monitor' {
        Monitor-Jobs
    }
    'Export' {
        Export-JobLogs -Path $ExportPath
    }
}
