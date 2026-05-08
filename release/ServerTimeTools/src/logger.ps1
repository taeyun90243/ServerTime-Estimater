. "$PSScriptRoot\anchor.ps1"

$script:LogRoot = $null

function Initialize-Logger {
    param([Parameter(Mandatory)][string]$LogDir)
    if (-not (Test-Path $LogDir)) { [void](New-Item -ItemType Directory -Path $LogDir -Force) }
    $script:LogRoot = $LogDir
    Remove-OldLogs
}

function Get-CurrentLogPath {
    $today = (Get-PcUtcNow).ToString('yyyyMMdd')
    return Join-Path $script:LogRoot "probe-$today.jsonl"
}

function Write-LogEvent {
    param([Parameter(Mandatory)][hashtable]$Event)
    if (-not $script:LogRoot) { return }
    $Event['ts'] = (Get-PcUtcNow).ToString('o')
    $line = ($Event | ConvertTo-Json -Compress -Depth 5)
    Add-Content -Path (Get-CurrentLogPath) -Value $line -Encoding UTF8
}

function Remove-OldLogs {
    if (-not $script:LogRoot) { return }
    $cutoff = (Get-PcUtcNow).AddDays(-25)
    Get-ChildItem -Path $script:LogRoot -Filter 'probe-*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
