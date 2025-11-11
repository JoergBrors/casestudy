param([string]$Path = "$PSScriptRoot\Output", [string]$SensitiveLabelsConfig = "$PSScriptRoot\config\sensitive_labels.json")

if (-not (Test-Path $Path)) { Write-Error "Path not found: $Path"; exit 1 }

$dirs = Get-ChildItem -Path $Path -Directory -Recurse
$files = Get-ChildItem -Path $Path -File -Recurse
$labels = @{}
if (Test-Path $SensitiveLabelsConfig) { $labels = (Get-Content $SensitiveLabelsConfig -Raw | ConvertFrom-Json).BIS }
Write-Host "Directories: $($dirs.Count)"
Write-Host "Files: $($files.Count)"

if ($files.Count -gt 0) {
    $extGroups = $files | Group-Object -Property Extension | Sort-Object Count -Descending
    Write-Host "Top file types by count:"
    $extGroups | Select-Object -First 10 | ForEach-Object { Write-Host " $($_.Name): $($_.Count)" }
}

# Scan files for sensitive strings
Write-Host "Scanning files for sensitive strings..."
$found = @{}
foreach ($file in $files) {
    $contentCandidates = @()
    try {
        if ($file.Extension -eq '.docx') {
            $tmp = Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())
            New-Item -ItemType Directory -Path $tmp -Force | Out-Null
            try { Expand-Archive -Path $file.FullName -DestinationPath $tmp -Force -ErrorAction Stop } catch { }
            $docPath = Join-Path $tmp 'word\document.xml'
            if (Test-Path $docPath) { $contentCandidates += Get-Content $docPath -Raw -ErrorAction SilentlyContinue }
            Remove-Item -Path $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            # try reading text content; if binary, this may fail or be empty
            $txt = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
            if ($txt) { $contentCandidates += $txt }
            else {
                # read as bytes and decode as ASCII
                $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
                $contentCandidates += [System.Text.Encoding]::ASCII.GetString($bytes)
                $contentCandidates += [System.Text.Encoding]::UTF8.GetString($bytes)
            }
        }
    }
    catch {
        # Could not read file
    }

    foreach ($levelName in $labels.psobject.Properties.Name) {
        $level = $labels.$levelName
        foreach ($pattern in $level.detectionStrings) {
            foreach ($cand in $contentCandidates) {
                if ($cand -and $cand.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    if (-not $found.ContainsKey($file.FullName)) { $found[$file.FullName] = @() }
                    $found[$file.FullName] += @{level=$levelName; pattern=$pattern}
                }
            }
        }
    }
}

Write-Host "Found sensitive occurrences in $($found.Count) files"
foreach ($k in $found.Keys) {
    Write-Host "File: $k"
    foreach ($hit in $found[$k]) { Write-Host " - $($hit.level): $($hit.pattern)" }
}


Write-Host "Done"
