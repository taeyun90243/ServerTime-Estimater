param(
    [string]$TargetTime = '',

    [string]$ApiBase = 'http://127.0.0.1:8765',

    [ValidateRange(0, 1000)]
    [int]$LeadMs = 0,

    [int]$ResyncBeforeMs = 3000,

    [ValidateRange(1, 500)]
    [int]$SpinMs = 25,

    [switch]$AllowStale,

    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class MouseClickerNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct INPUT
    {
        public UInt32 type;
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT
    {
        public Int32 dx;
        public Int32 dy;
        public UInt32 mouseData;
        public UInt32 dwFlags;
        public UInt32 time;
        public IntPtr dwExtraInfo;
    }

    [DllImport("user32.dll", SetLastError = true)]
    public static extern UInt32 SendInput(UInt32 nInputs, INPUT[] pInputs, Int32 cbSize);

    public const UInt32 INPUT_MOUSE = 0;
    public const UInt32 MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const UInt32 MOUSEEVENTF_LEFTUP = 0x0004;

    public static void LeftClick()
    {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_MOUSE;
        inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
        inputs[1].type = INPUT_MOUSE;
        inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;

        UInt32 sent = SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
        if (sent != 2)
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}
'@

function Read-TargetTimeIfNeeded {
    param([string]$Value)

    if ($Value.Trim()) { return $Value.Trim() }

    Write-Host ''
    Write-Host 'Target server time format (KST)' -ForegroundColor Cyan
    Write-Host '  20:00:00.000              with milliseconds'
    Write-Host '  20:00:00                  without milliseconds'
    Write-Host '  2026-05-02 20:00:00.000   with date'
    Write-Host ''
    Write-Host 'If date is omitted, today is used. If already passed, tomorrow is used.'
    Write-Host ''

    while ($true) {
        $inputValue = Read-Host 'Target server time'
        if ($inputValue.Trim()) { return $inputValue.Trim() }
        Write-Host 'Enter a value. Example: 20:00:00.000' -ForegroundColor Yellow
    }
}

function Get-NowTick {
    return [System.Diagnostics.Stopwatch]::GetTimestamp()
}

function Convert-TickDeltaToMs {
    param(
        [Parameter(Mandatory = $true)][long]$StartTick,
        [Parameter(Mandatory = $true)][long]$EndTick
    )
    return (($EndTick - $StartTick) / [System.Diagnostics.Stopwatch]::Frequency * 1000.0)
}

function ConvertTo-UnixMs {
    param([Parameter(Mandatory = $true)][DateTime]$UtcDateTime)
    $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    return ($UtcDateTime.ToUniversalTime() - $epoch).TotalMilliseconds
}

function ConvertFrom-UnixMs {
    param([Parameter(Mandatory = $true)][double]$UnixMs)
    $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    return $epoch.AddMilliseconds($UnixMs)
}

function Resolve-TargetServerMs {
    param([Parameter(Mandatory = $true)][string]$Value)

    $tz = [TimeZoneInfo]::FindSystemTimeZoneById('Korea Standard Time')
    [string[]]$formats = @(
        'yyyy-MM-dd HH:mm:ss.fff',
        'yyyy-MM-dd HH:mm:ss',
        'yyyy/MM/dd HH:mm:ss.fff',
        'yyyy/MM/dd HH:mm:ss',
        'HH:mm:ss.fff',
        'HH:mm:ss'
    )

    $parsed = [DateTime]::MinValue
    $ok = [DateTime]::TryParseExact(
        $Value,
        $formats,
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::None,
        [ref]$parsed
    )
    if (-not $ok) {
        throw 'Use TargetTime format "HH:mm:ss.fff" or "yyyy-MM-dd HH:mm:ss.fff".'
    }

    $hasDate = $Value -match '^\d{4}[-/]\d{2}[-/]\d{2}'
    if (-not $hasDate) {
        $nowKst = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz)
        $parsed = [DateTime]::new(
            $nowKst.Year,
            $nowKst.Month,
            $nowKst.Day,
            $parsed.Hour,
            $parsed.Minute,
            $parsed.Second,
            $parsed.Millisecond,
            [DateTimeKind]::Unspecified
        )
        if ($parsed -le $nowKst) {
            $parsed = $parsed.AddDays(1)
        }
    } else {
        $parsed = [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Unspecified)
    }

    $utc = [TimeZoneInfo]::ConvertTimeToUtc($parsed, $tz)
    return ConvertTo-UnixMs -UtcDateTime $utc
}

function Get-StateEstimate {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)

    $url = $BaseUrl.TrimEnd('/') + '/api/state'
    $t0 = Get-NowTick
    $state = Invoke-RestMethod -Uri $url -UseBasicParsing -TimeoutSec 2
    $t1 = Get-NowTick
    $apiRttMs = Convert-TickDeltaToMs -StartTick $t0 -EndTick $t1

    if (-not $state.targetUrl) {
        throw 'No measured target URL. Run run.bat first and complete measurement.'
    }
    if ($state.status -eq 'measuring' -or $state.status -eq 'queued' -or $state.status -eq 'idle') {
        throw "Measurement is not ready yet. status=$($state.status)"
    }
    if ($state.status -eq 'failed') {
        throw 'Server time measurement status is failed. Check the URL in the main tool.'
    }
    if ($state.status -eq 'stale' -and -not $AllowStale) {
        throw 'Measurement is stale. Refresh the browser to remeasure or use -AllowStale.'
    }

    $serverAtLocalTickMs = [double]$state.pcSendTimeAtMs + [double]$state.offsetMs + ($apiRttMs / 2.0)
    return [PSCustomObject]@{
        State               = $state
        BaseTick            = $t1
        BaseServerMs        = $serverAtLocalTickMs
        ApiRttMs            = $apiRttMs
        EstimatedCi95Ms     = [double]($state.ci95Ms)
        EstimatedOffsetMs   = [double]($state.offsetMs)
    }
}

function Get-EstimatedServerNowMs {
    param(
        [Parameter(Mandatory = $true)]$Estimate
    )
    $nowTick = Get-NowTick
    $elapsedMs = Convert-TickDeltaToMs -StartTick $Estimate.BaseTick -EndTick $nowTick
    return ([double]$Estimate.BaseServerMs + $elapsedMs)
}

function Wait-UntilServerMs {
    param(
        [Parameter(Mandatory = $true)]$Estimate,
        [Parameter(Mandatory = $true)][double]$TargetMs,
        [Parameter(Mandatory = $true)][int]$FinalSpinMs
    )

    while ($true) {
        $remainingMs = $TargetMs - (Get-EstimatedServerNowMs -Estimate $Estimate)
        if ($remainingMs -le $FinalSpinMs) { break }

        $sleepMs = [Math]::Max(1, [Math]::Min(100, [int]($remainingMs - $FinalSpinMs)))
        Start-Sleep -Milliseconds $sleepMs
    }

    while ((Get-EstimatedServerNowMs -Estimate $Estimate) -lt $TargetMs) {
        # Final busy-wait for sub-sleep precision.
    }
}

function Invoke-MouseClickOnce {
    [MouseClickerNative]::LeftClick()
}

$ApiBase = $ApiBase.TrimEnd('/')
$TargetTime = Read-TargetTimeIfNeeded -Value $TargetTime
$targetServerMs = Resolve-TargetServerMs -Value $TargetTime
$fireServerMs = $targetServerMs - $LeadMs
$targetKst = (ConvertFrom-UnixMs -UnixMs $targetServerMs).AddHours(9)
$fireKst = (ConvertFrom-UnixMs -UnixMs $fireServerMs).AddHours(9)

Write-Host "State API: $ApiBase/api/state" -ForegroundColor Cyan
Write-Host "Target server time (KST): $($targetKst.ToString('yyyy-MM-dd HH:mm:ss.fff'))"
if ($LeadMs -gt 0) {
    Write-Host "Fire server time (KST): $($fireKst.ToString('yyyy-MM-dd HH:mm:ss.fff')) (LeadMs=$LeadMs)"
}
Write-Host 'Click: current mouse position / left click once'
if ($DryRun) {
    Write-Host "DryRun: no actual click" -ForegroundColor Yellow
}

$estimate = $null
while ($null -eq $estimate) {
    try {
        $estimate = Get-StateEstimate -BaseUrl $ApiBase
    } catch {
        Write-Host "Waiting: $_" -ForegroundColor DarkYellow
        Start-Sleep -Milliseconds 200
    }
}

$remainingMs = $fireServerMs - (Get-EstimatedServerNowMs -Estimate $estimate)
if ($remainingMs -le 0) {
    throw "Fire time has already passed. remainingMs=$([Math]::Round($remainingMs, 3))"
}

Write-Host "Synced: status=$($estimate.State.status), apiRtt=$([Math]::Round($estimate.ApiRttMs, 3))ms, ci95=$([Math]::Round($estimate.EstimatedCi95Ms, 3))ms, remaining=$([Math]::Round($remainingMs, 1))ms" -ForegroundColor Green

if ($remainingMs -gt ($ResyncBeforeMs + 250)) {
    $sleepBeforeResync = [Math]::Max(1, [int]($remainingMs - $ResyncBeforeMs))
    Write-Host "Waiting until $ResyncBeforeMs ms before target, then resyncing"
    Start-Sleep -Milliseconds $sleepBeforeResync

    $estimate = $null
    while ($null -eq $estimate) {
        try {
            $estimate = Get-StateEstimate -BaseUrl $ApiBase
        } catch {
            Write-Host "Waiting for resync: $_" -ForegroundColor DarkYellow
            Start-Sleep -Milliseconds 100
        }
    }
    $remainingMs = $fireServerMs - (Get-EstimatedServerNowMs -Estimate $estimate)
    if ($remainingMs -le 0) {
        throw "Fire time has already passed after resync. remainingMs=$([Math]::Round($remainingMs, 3))"
    }
    Write-Host "Resynced: apiRtt=$([Math]::Round($estimate.ApiRttMs, 3))ms, ci95=$([Math]::Round($estimate.EstimatedCi95Ms, 3))ms, remaining=$([Math]::Round($remainingMs, 1))ms" -ForegroundColor Green
}

Wait-UntilServerMs -Estimate $estimate -TargetMs $fireServerMs -FinalSpinMs $SpinMs
$clickTick = Get-NowTick
$estimatedClickServerMs = Get-EstimatedServerNowMs -Estimate $estimate

if (-not $DryRun) {
    Invoke-MouseClickOnce
}

$afterTick = Get-NowTick
$clickCallMs = Convert-TickDeltaToMs -StartTick $clickTick -EndTick $afterTick
$errorMs = $estimatedClickServerMs - $fireServerMs
$actualKst = (ConvertFrom-UnixMs -UnixMs $estimatedClickServerMs).AddHours(9)

Write-Host "Done: estimated fire time (KST)=$($actualKst.ToString('yyyy-MM-dd HH:mm:ss.fff')), targetError=$([Math]::Round($errorMs, 3))ms, clickCall=$([Math]::Round($clickCallMs, 3))ms" -ForegroundColor Cyan
