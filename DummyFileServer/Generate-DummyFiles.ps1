# Generate-DummyFiles.ps1
# Creates a directory structure and generates dummy files for DLP and file server testing.

param(
    [string]$RootPath = "./DummyFileServer-Output",
    [string]$DirectoryConfig = "./config/dir_structure.json",
    [string]$FileTypesConfig = "./config/file_types.json",
    [string]$FileNamesConfig = "./config/file_names.json",
    [string]$SensitiveLabelsConfig = "./config/sensitive_labels.json",
    [int]$TopLevelCount = 10,
    [int]$SubLevelCount = 5,
    [int]$TotalOfficeFiles = 100,
    [switch]$UseFsutil = $true,
    [int]$Seed = 0,
    [switch]$DryRun = $false
)

<#
.SYNOPSIS
Creates a directory structure and generates dummy files for DLP and file server testing.

.DESCRIPTION
Usage examples:
  .\Generate-DummyFiles.ps1 -RootPath C:\Temp\DummyServer -TopLevelCount 10 -SubLevelCount 5 -TotalOfficeFiles 100

Parameters:
  -RootPath: Output root for generated directories/files
  -DirectoryConfig: JSON file to describe dir templates and counts
  -FileTypesConfig: JSON file describing file types and size ranges
  -FileNamesConfig: JSON file with filename examples and templates
  -SensitiveLabelsConfig: JSON file with BIS Ampel label examples
  -TopLevelCount / -SubLevelCount / -TotalOfficeFiles: override counts
  -UseFsutil: Use fsutil file createnew when available
  -Seed: Random seed for reproducible generation
  -DryRun: do not create files just list operations
#>


function Load-JsonFile {
    param([string]$Path)
    if (Test-Path $Path) {
        return Get-Content $Path -Raw | ConvertFrom-Json
    }
    else {
        Write-Verbose "JSON file not found: $Path"
        return $null
    }
}

function Test-Fsutil {
    try {
        $fs = Get-Command fsutil -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function New-DummyFileFsutil {
    param([string]$FilePath, [int64]$SizeBytes)
    $dir = Split-Path $FilePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $cmd = "fsutil file createnew `"$FilePath`" $SizeBytes"
    $proc = Start-Process -FilePath fsutil -ArgumentList @('file','createnew',$FilePath,$SizeBytes) -Wait -PassThru -NoNewWindow -ErrorAction SilentlyContinue
    if ($proc -and $proc.ExitCode -ne 0) { throw "fsutil exec failed (exitCode $($proc.ExitCode))" }
}

function New-DummyFileFallback {
    param([string]$FilePath, [int64]$SizeBytes, [string]$SensitiveContent = $null)
    $dir = Split-Path $FilePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    
    # Write sensitive content at the beginning if provided
    $headerBytes = 0
    if ($SensitiveContent) {
        $header = "--- SENSITIVE DATA ---`n$SensitiveContent`n--- END SENSITIVE DATA ---`n`n"
        [System.IO.File]::WriteAllText($FilePath, $header, [System.Text.Encoding]::UTF8)
        $headerBytes = (Get-Item $FilePath).Length
    }
    
    # Fill rest with random data
    $blockSize = 8192
    $block = New-Object byte[] $blockSize
    $rand = New-Object System.Random
    $rand.NextBytes($block)
    
    $stream = [System.IO.File]::Open($FilePath, [System.IO.FileMode]::Append)
    try {
        $remaining = $SizeBytes - $headerBytes
        while ($remaining -gt 0) {
            $write = [Math]::Min($remaining, $block.Length)
            $stream.Write($block, 0, $write)
            $remaining -= $write
        }
    }
    finally { $stream.Close() }
}

function Set-RandomFileTimestamps {
    param(
        [string]$FilePath,
        [int]$MinDaysAgo = 730,  # Default: up to 2 years ago
        [int]$MaxDaysAgo = 1
    )
    
    if (-not (Test-Path $FilePath)) { return }
    
    $rand = New-Object System.Random
    $now = Get-Date
    
    # Random creation time (older)
    $createdDaysAgo = $rand.Next($MaxDaysAgo, $MinDaysAgo + 1)
    $createdTime = $now.AddDays(-$createdDaysAgo).AddHours(-$rand.Next(0,24)).AddMinutes(-$rand.Next(0,60))
    
    # Random modified time (between creation and now)
    $modifiedDaysAgo = $rand.Next($MaxDaysAgo, $createdDaysAgo + 1)
    $modifiedTime = $now.AddDays(-$modifiedDaysAgo).AddHours(-$rand.Next(0,24)).AddMinutes(-$rand.Next(0,60))
    
    # Random access time (between modified and now)
    $accessedDaysAgo = $rand.Next($MaxDaysAgo, $modifiedDaysAgo + 1)
    $accessedTime = $now.AddDays(-$accessedDaysAgo).AddHours(-$rand.Next(0,24)).AddMinutes(-$rand.Next(0,60))
    
    try {
        $file = Get-Item $FilePath
        $file.CreationTime = $createdTime
        $file.LastWriteTime = $modifiedTime
        $file.LastAccessTime = $accessedTime
    }
    catch {
        Write-Verbose "Could not set timestamps for $FilePath : $_"
    }
}

function New-DocxFile {
    param([string]$FilePath, [string]$BodyText, [int64]$SizeBytes = 8192)
    # Create a minimal set of files for a docx package
    $tempDir = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([System.Guid]::NewGuid().ToString())) -Force
    try {
        $wordDir = Join-Path $tempDir.FullName 'word'
        New-Item -ItemType Directory -Path $wordDir | Out-Null
        
        # Build body with sensitive content at the start
        $body = $BodyText
        $currentBytes = ([System.Text.Encoding]::UTF8.GetByteCount($body))
        
        # Pad to reach desired size
        if ($SizeBytes -gt $currentBytes) {
            $repeat = [Math]::Ceiling(($SizeBytes - $currentBytes) / 50)
            $pad = "`n" + ('Lorem ipsum dolor sit amet consectetur ' * 3)
            $body = $body + ($pad * $repeat)
        }

        # Escape special XML characters
        $escapedBody = $body -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'","&apos;"
        $docXml = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body>
<w:p>
<w:r>
<w:t>$escapedBody</w:t>
</w:r>
</w:p>
</w:body>
</w:document>
"@
        $documentPath = Join-Path $wordDir 'document.xml'
        $docXml | Out-File -FilePath $documentPath -Encoding utf8

        # Minimal _rels/.rels
        $relsDir = Join-Path $tempDir.FullName '_rels'
        New-Item -ItemType Directory -Path $relsDir | Out-Null
        $relsXml = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>
"@
        $relsPath = Join-Path $relsDir '.rels'
        $relsXml | Out-File -FilePath $relsPath -Encoding utf8

        # Minimal [Content_Types].xml
        $contentTypes = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>
"@
        $contentPath = Join-Path $tempDir.FullName 'Content_Types.xml'
        $contentTypes | Out-File -FilePath $contentPath -Encoding utf8
        # Rename to [Content_Types].xml after creation
        Rename-Item -Path $contentPath -NewName '[Content_Types].xml' -Force

        # Now zip it into docx
        $zipPath = $FilePath + '.zip'
        # Use Compress-Archive with LiteralPath to handle special characters
        $itemsToZip = Get-ChildItem -Path $tempDir.FullName -Force
        Compress-Archive -LiteralPath $itemsToZip.FullName -DestinationPath $zipPath -Force
        # Move .zip to .docx
        $docxPath = [System.IO.Path]::ChangeExtension($zipPath, '.docx')
        if (Test-Path $docxPath) { Remove-Item $docxPath -Force }
        Move-Item -Path $zipPath -Destination $docxPath -Force
        if ($FilePath -ne $docxPath) { Move-Item -Path $docxPath -Destination $FilePath -Force }
    }
    finally {
        # cleanup
        if (Test-Path $tempDir.FullName) { Remove-Item -Path $tempDir.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Random-FromList {
    param([array]$List)
    if ($List -eq $null -or $List.Count -eq 0) { return $null }
    return $List[(Get-Random -Minimum 0 -Maximum $List.Count)]
}

function Expand-Template {
    param([string]$Template, [hashtable]$Vars)
    $res = $Template
    foreach ($k in $Vars.Keys) {
        $res = $res -replace ('\{' + [regex]::Escape($k) + '\}'), [string]$Vars[$k]
    }
    return $res
}

Write-Host "Starting Dummy File Server generator"
if ($Seed -ne 0) { Set-Random -Seed $Seed }

$dirCfg = Load-JsonFile $DirectoryConfig
$typesCfg = Load-JsonFile $FileTypesConfig
$namesCfg = Load-JsonFile $FileNamesConfig
$labelsCfg = Load-JsonFile $SensitiveLabelsConfig

if (-not $dirCfg) { Write-Warning "Directory config not found, using defaults" }
if (-not $typesCfg) { Write-Warning "File types config not found, using built-ins" }
if (-not $namesCfg) { Write-Warning "File names config not found, using built-ins" }
if (-not $labelsCfg) { Write-Warning "Sensitive labels config not found, using built-ins" }

# Default templates
if (-not $dirCfg) {
    $dirCfg = @{
        topLevel = @{
            templates = @('Sales','Finance','HR','IT','Legal','Operations','Marketing','R&D','Admin','Support')
        }
        subLevel = @{
            templates = @('Contracts','Reports','Drafts','Exports','Archive')
        }
    }
}
if (-not $typesCfg) {
    # simpler defaults inlined to avoid complex nested literal parsing
    $typesCfg = @{
        Office = @(@{ ext = '.docx'; minKB = 10; maxKB = 1024 })
        Text   = @(@{ ext = '.txt' ; minKB = 1; maxKB = 300  })
        VSC    = @(@{ ext = '.zip' ; minKB = 10; maxKB = 102400 })
        Other  = @(@{ ext = '.pdf' ; minKB = 50; maxKB = 4096 })
    }
}
if (-not $namesCfg) {
    $namesCfg = @{
        examples = @('Annual_Report_2024','Customer_Contract','Invoice_2024_1001')
        templates = @('Customer_{CustomerId}_Contract','Invoice_{Year}_{InvoiceNumber}','Project_{ProjectCode}_Specs')
        placeholders = @{
            CustomerId = @('CUST1001','CUST2002')
            Year = @(2022,2023)
            InvoiceNumber = @(1001,1002)
            ProjectCode = @('KAM-Alpha','KAM-Beta')
            FirstName = @('John','Anna')
            LastName = @('Muller','Schmidt')
            PO = @('PO1001','PO2222')
        }
    }
}
if (-not $labelsCfg) {
    $labelsCfg = @{
        BIS = @{
            Rot = @{
                displayName = 'Hoch (Rot)'
                detectionStrings = @('4111 1111 1111 1111','SSN: 123-45-6789')
                insertionRate = 8
            }
            Gelb = @{
                displayName = 'Mittel (Gelb)'
                detectionStrings = @('john.doe@example.com','+49 171 1234567')
                insertionRate = 12
            }
            Gruen = @{
                displayName = 'Niedrig (Grün)'
                detectionStrings = @('Internal Project','Company Confidential')
                insertionRate = 30
            }
        }
    }
}

$useFs = $UseFsutil.IsPresent -and (Test-Fsutil)
if ($UseFsutil.IsPresent -and -not $useFs) { Write-Warning "fsutil is not available; falling back to pure PowerShell file creation" }

[int]$createdDirs=0
[int]$createdFiles=0

if ($DryRun) { Write-Host "Dry-run: no changes will be made" }

# Prepare top-level names
$topTemplates = $dirCfg.topLevel.templates
$subTemplates = $dirCfg.subLevel.templates

<# Resolve/prepare root directory - create it if it doesn't exist #>
$absRoot = (Resolve-Path -LiteralPath $RootPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path -ErrorAction SilentlyContinue)
if (-not $absRoot) { $newRoot = New-Item -ItemType Directory -Path $RootPath -Force; $absRoot = $newRoot.FullName }
$dirList = New-Object System.Collections.Generic.List[System.String]

# Get sublevel config parameters
$subMinCount = if ($dirCfg.subLevel.minCount) { $dirCfg.subLevel.minCount } else { $SubLevelCount }
$subMaxCount = if ($dirCfg.subLevel.maxCount) { $dirCfg.subLevel.maxCount } else { $SubLevelCount }
$useParentPrefix = if ($dirCfg.subLevel.useParentPrefix) { $dirCfg.subLevel.useParentPrefix } else { $false }
$parentPrefixProb = if ($dirCfg.subLevel.parentPrefixProbability) { [int]($dirCfg.subLevel.parentPrefixProbability * 100) } else { 0 }

for ($i=0; $i -lt $TopLevelCount; $i++) {
    $t = if ($i -lt $topTemplates.Count) { $topTemplates[$i] } else { $topTemplates[(Get-Random -Maximum $topTemplates.Count)] }
    $topName = "$t"
    $topPath = Join-Path $absRoot $topName
    if (-not $DryRun) { New-Item -Path $topPath -ItemType Directory -Force | Out-Null }
    $createdDirs++
    
    # Random number of sublevels for this department
    $numSubLevels = Get-Random -Minimum $subMinCount -Maximum ($subMaxCount + 1)
    
    for ($j=0; $j -lt $numSubLevels; $j++) {
        $s = $subTemplates[(Get-Random -Maximum $subTemplates.Count)]
        
        # Decide whether to use parent prefix (e.g., "Sales-Team-Alpha")
        if ($useParentPrefix -and (Get-Random -Minimum 0 -Maximum 100) -lt $parentPrefixProb) {
            $subName = "$topName-$s"
        } else {
            $subName = $s
        }
        
        $subPath = Join-Path $topPath $subName
        if (-not $DryRun) { New-Item -Path $subPath -ItemType Directory -Force | Out-Null }
        $createdDirs++
        $dirList.Add($subPath)
    }
}

Write-Host "Created/Prepared $createdDirs directories. Will create files across $($dirList.Count) directories."

# Build list of all file type entries
$allTypes = @()
foreach ($k in $typesCfg.psobject.Properties.Name) {
    foreach ($entry in $typesCfg.$k) {
        $obj = [PSCustomObject]@{ category = $k; ext = $entry.ext; minKB = $entry.minKB; maxKB = $entry.maxKB }
        $allTypes += $obj
    }
}

# Decide number of files per directory
$perDir = [Math]::Ceiling($TotalOfficeFiles / [double]$dirList.Count)
Write-Host "Target total office files: $TotalOfficeFiles => approx $perDir per directory across $($dirList.Count) dirs"

foreach ($dir in $dirList) {
    $dirFiles = Get-Random -Minimum ([Math]::Max(1, $perDir-2)) -Maximum ($perDir+3)
    for ($f=0; $f -lt $dirFiles; $f++) {
        # Choose a type (prefer Office for initial sets)
        $t = Get-Random -Minimum 0 -Maximum $allTypes.Count
        $ty = $allTypes[$t]
        # Random size for EACH file to ensure variety
        $sizeKB = Get-Random -Minimum $ty.minKB -Maximum ($ty.maxKB + 1)
        $sizeBytes = $sizeKB * 1024

        # Build filename
        $useTemplate = (Get-Random -Minimum 0 -Maximum 100) -lt 70
        if ($useTemplate -and $namesCfg.templates) {
            $tmpl = Random-FromList $namesCfg.templates
            if ($tmpl) {
                $vars = @{}
                if ($namesCfg.placeholders) {
                    # Convert PSCustomObject to hashtable for easier access
                    $placeholderHash = @{}
                    foreach ($prop in $namesCfg.placeholders.PSObject.Properties) {
                        $placeholderHash[$prop.Name] = $prop.Value
                    }
                    
                    foreach ($k in $placeholderHash.Keys) { 
                        $list = $placeholderHash[$k]
                        if ($list -is [array]) {
                            $val = Random-FromList $list
                        } else {
                            $val = $list
                        }
                        if ($val) { $vars[$k] = $val }
                    }
                }
                if ($vars.Count -gt 0) {
                    $filenameBase = Expand-Template $tmpl $vars
                }
                else {
                    # No valid placeholders, use example instead
                    $filenameBase = Random-FromList $namesCfg.examples
                }
            }
            else {
                $filenameBase = Random-FromList $namesCfg.examples
            }
        }
        else {
            $filenameBase = Random-FromList $namesCfg.examples
            if (-not $filenameBase) { $filenameBase = "File-$((Get-Random -Minimum 1 -Maximum 99999))" }
        }
        $filename = "$filenameBase$($ty.ext)"
        $fullPath = Join-Path $dir $filename

        $injectedString = $null
        # Decide whether to inject sensitive content
        foreach ($level in $labelsCfg.BIS.psobject.Properties.Name) {
            $cfg = $labelsCfg.BIS.$level
            $rate = $cfg.insertionRate
            if ($rate -is [array]) { $rate = $rate[0] }
            if ($null -ne $rate -and $rate -is [int] -and (Get-Random -Minimum 1 -Maximum 101) -le $rate) {
                $injectedString = Random-FromList $cfg.detectionStrings
                break
            }
        }

        # Create file
        if ($DryRun) { Write-Output "[DRY] Create: $fullPath ($sizeKB KB) - injected: $injectedString"; continue }
        try {
            # Ensure parent directory exists
            $parentDir = Split-Path $fullPath -Parent
            if (-not (Test-Path $parentDir)) { New-Item -ItemType Directory -Path $parentDir -Force | Out-Null }
            
            if ($ty.ext -eq '.docx') {
                # Create docx with sensitive content in body text at the beginning
                $body = ""
                if ($injectedString) { 
                    $body = "=== SENSITIVE INFORMATION ===`n$injectedString`n=== END SENSITIVE ===`n`n"
                }
                $body += "Document: $filenameBase`nGenerated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n`n"
                New-DocxFile -FilePath $fullPath -BodyText $body -SizeBytes $sizeBytes
            }
            elseif ($ty.ext -in @('.txt')) {
                # Text files: write sensitive content at the beginning
                $content = ""
                if ($injectedString) {
                    $content = "=== SENSITIVE INFORMATION ===`n$injectedString`n=== END SENSITIVE ===`n`n"
                }
                $content += "File: $filenameBase`nCreated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')`n`n"
                
                # Pad to reach desired size
                $currentSize = [System.Text.Encoding]::UTF8.GetByteCount($content)
                if ($sizeBytes -gt $currentSize) {
                    $padding = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. "
                    $repeat = [Math]::Ceiling(($sizeBytes - $currentSize) / $padding.Length)
                    $content += ($padding * $repeat)
                }
                
                [System.IO.File]::WriteAllText($fullPath, $content, [System.Text.Encoding]::UTF8)
            }
            else {
                # Binary files (xlsx, pptx, pdf, zip, tar.gz): use fallback with sensitive header
                if ($useFs -and -not $injectedString) { 
                    # fsutil doesn't support prepending text, so use fallback for sensitive files
                    New-DummyFileFsutil -FilePath $fullPath -SizeBytes $sizeBytes
                } 
                else { 
                    New-DummyFileFallback -FilePath $fullPath -SizeBytes $sizeBytes -SensitiveContent $injectedString
                }
            }

            # Set random file timestamps for realism
            Set-RandomFileTimestamps -FilePath $fullPath -MinDaysAgo 730 -MaxDaysAgo 1

            $createdFiles++
        }
        catch {
            Write-Warning "Failed to create $fullPath - $_"
        }
    }
}

Write-Host "Created $createdFiles files. Done."
