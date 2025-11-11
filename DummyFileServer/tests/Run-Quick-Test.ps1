param()

$base = (Resolve-Path (Join-Path $PSScriptRoot '..') | Select-Object -ExpandProperty Path)
$script = Join-Path $base 'Generate-DummyFiles.ps1'
$verify = Join-Path $base 'verify-output.ps1'
$out = Join-Path $base 'test-output'
Remove-Item -Path $out -Recurse -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $script)) { Write-Error "Main script not found"; exit 1 }

# Create a label config that forces injection
$labelCfg = @{
    BIS = @{
        Test = @{
            displayName = 'TEST'
            detectionStrings = @('TEST-DETECT-111')
            insertionRate = 100
        }
    }
}
$testLabelPath = Join-Path $PSScriptRoot 'test_labels.json'
$labelCfg | ConvertTo-Json -Depth 4 | Out-File $testLabelPath -Encoding utf8

Write-Host "Running generation (1 top-level, 1 sub-level, 2 files)"
PowerShell -ExecutionPolicy Bypass -File $script -RootPath $out -DirectoryConfig (Join-Path $base 'config\dir_structure.json') -FileTypesConfig (Join-Path $base 'config\file_types.json') -FileNamesConfig (Join-Path $base 'config\file_names.json') -SensitiveLabelsConfig $testLabelPath -TopLevelCount 1 -SubLevelCount 1 -TotalOfficeFiles 2 -UseFsutil:$false -Seed 42

Write-Host "Verifying output"
$verifyOut = PowerShell -ExecutionPolicy Bypass -File $verify -Path $out -SensitiveLabelsConfig $testLabelPath

if ($verifyOut -match 'Found sensitive occurrences in') {
    Write-Host "Test PASSED"
    exit 0
}
else {
    Write-Error "Test FAILED - no sensitive occurrences found"
    exit 2
}
