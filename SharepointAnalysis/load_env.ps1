<#
PowerShell helper to load environment variables from a .env-style file into the current session.

Usage:
  # load default .env.local
  . .\SharepointAnalysis\load_env.ps1
  Load-Env -Path .\SharepointAnalysis\.env.local

  # or specify a different file
  Load-Env -Path .\SharepointAnalysis\.env.template

Security note: this sets environment variables in your current PowerShell session only. The file should be kept local and excluded from source control.
#>
function Load-Env {
    [CmdletBinding()]
    param(
            [Parameter(Mandatory=$false)][string]$Path = "./SharepointAnalysis/.env.local",
            [switch]$ShowVerbose
    )
    if (-not (Test-Path $Path)) {
        Write-Error "Env file not found: $Path"
        return
    }

    Get-Content -Path $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { return }
        if ($line -notmatch '^(?<k>[^=]+)=(?<v>.*)$') { return }
        $k = $matches['k'].Trim()
        $v = $matches['v'].Trim('"')
        # set as session environment variable
            if ($ShowVerbose) { Write-Host "Setting env $k" -ForegroundColor DarkGray }
        Set-Item -Path Env:$k -Value $v
    }
    Write-Host "Environment variables loaded from $Path" -ForegroundColor Green

    # Convenience mapping: if CLIENT_SECRET is present, also set GRAPH_CLIENT_SECRET
    try {
        $clientSecretVar = Get-Item -Path Env:CLIENT_SECRET -ErrorAction SilentlyContinue
        if ($clientSecretVar -and -not (Get-Item -Path Env:GRAPH_CLIENT_SECRET -ErrorAction SilentlyContinue)) {
            $val = $clientSecretVar.Value
            Set-Item -Path Env:GRAPH_CLIENT_SECRET -Value $val
            if ($ShowVerbose) { Write-Host "Mapped CLIENT_SECRET -> GRAPH_CLIENT_SECRET" -ForegroundColor DarkGray }
        }
    } catch {
        # ignore mapping errors
    }

}


