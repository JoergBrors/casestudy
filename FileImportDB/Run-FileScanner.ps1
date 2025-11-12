param(
    [Parameter(Mandatory=$true)][string[]] $Roots,
    [string] $DbPath = "fileindex.db",
    [int] $Workers = 10,
    [switch] $Hash,
    [int] $BatchSize = 500,
    [switch] $FollowSymlinks,
    [string] $Include,
    [string] $Exclude
    ,
    [string] $MssqlServer,
    [string] $MssqlDatabase,
    [string] $MssqlUser,
    [string] $MssqlPassword,
    [string] $MssqlDriver = 'ODBC Driver 17 for SQL Server'
)

Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$py = "python"
try {
    & $py -V > $null 2>&1
} catch {
    Write-Error "Python is not found on PATH. Install Python 3 and retry."
    exit 1
}

$pyArgs = [System.Collections.Generic.List[string]]::new()
$pyArgs.Add('--roots')
foreach ($r in $Roots) { $pyArgs.Add($r) }
$pyArgs.Add('--db')
$pyArgs.Add($DbPath)
if ($Workers -gt 0) { $pyArgs.Add('--workers'); $pyArgs.Add([string]$Workers) }
if ($Hash) { $pyArgs.Add('--hash') }
if ($BatchSize -ne 500) { $pyArgs.Add('--batch-size'); $pyArgs.Add([string]$BatchSize) }
if ($FollowSymlinks) { $pyArgs.Add('--follow-symlinks') }
if ($Include) { $pyArgs.Add('--include'); $pyArgs.Add($Include) }
if ($Exclude) { $pyArgs.Add('--exclude'); $pyArgs.Add($Exclude) }
if ($MssqlServer) { $pyArgs.Add('--mssql-server'); $pyArgs.Add($MssqlServer) }
if ($MssqlDatabase) { $pyArgs.Add('--mssql-database'); $pyArgs.Add($MssqlDatabase) }
if ($MssqlUser) { $pyArgs.Add('--mssql-user'); $pyArgs.Add($MssqlUser) }
if ($MssqlPassword) { $pyArgs.Add('--mssql-password'); $pyArgs.Add($MssqlPassword) }
if ($MssqlDriver) { $pyArgs.Add('--mssql-driver'); $pyArgs.Add($MssqlDriver) }

$scanner = Join-Path $scriptDir 'scanner.py'
if (-not (Test-Path $scanner)) { Write-Error "scanner.py not found in $scriptDir"; exit 1 }

Write-Host "Running scanner with args: $($pyArgs -join ' ')"
& $py $scanner $pyArgs
