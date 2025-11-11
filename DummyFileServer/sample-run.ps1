param()

# Sample-run script (PowerShell) to execute Generate-DummyFiles.ps1 with defaults.
$script = "$PSScriptRoot\Generate-DummyFiles.ps1"

if (-not (Test-Path $script)) { Write-Error "Main script not found at: $script"; exit 1 }

Write-Host "Running sample generation: 10 top-level, 5 sub-levels, ~100 office files"
PowerShell -ExecutionPolicy Bypass -File $script -RootPath "$PSScriptRoot\Output" -DirectoryConfig "$PSScriptRoot\config\dir_structure.json" -FileTypesConfig "$PSScriptRoot\config\file_types.json" -FileNamesConfig "$PSScriptRoot\config\file_names.json" -SensitiveLabelsConfig "$PSScriptRoot\config\sensitive_labels.json" -TopLevelCount 10 -SubLevelCount 5 -TotalOfficeFiles 100 -UseFsutil:$false
