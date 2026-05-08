param(
    [string]$TargetUrl = ''
)

$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\anchor.ps1"
. "$PSScriptRoot\measurement.ps1"
. "$PSScriptRoot\http-server.ps1"
. "$PSScriptRoot\ntp.ps1"
. "$PSScriptRoot\logger.ps1"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "PowerShell 5.1 이상 필요" -ForegroundColor Red; exit 1
}

Initialize-Anchor
Initialize-Logger -LogDir (Join-Path $PSScriptRoot '..\logs')

$url = if ($TargetUrl) { Normalize-TargetUrl -Url $TargetUrl } else { '' }
$webRoot = Join-Path $PSScriptRoot 'web'

$state = New-StateStore
$state.TargetUrl = $url
if ($url) {
    $state.Host = ([Uri]$url).Host
    $state.Status = 'measuring'
    Write-Host "초기 측정 (적응형, 약 6초): $url"
    try {
        $result = Invoke-AdaptiveMultiSample -Url $url
        $state.OffsetMs      = $result.OffsetMs
        $state.RttMedianMs   = $result.RttMedianMs
        $state.SigmaMs       = $result.SigmaMs
        $state.Ci95Ms        = $result.Ci95Ms
        $state.LastMeasureAt = Get-PcUtcNow
        $state.Status        = 'ok'
        Write-Host "초기 오프셋: $([Math]::Round($result.OffsetMs,1)) ms (±$([Math]::Round($result.Ci95Ms,1)))"
        Write-LogEvent @{
            ev = 'measure'; host = $state.Host
            offsetMs = $result.OffsetMs; sigmaMs = $result.SigmaMs
            rttMedianMs = $result.RttMedianMs
            sampleCount = $result.SampleCount; acceptedCount = $result.AcceptedCount
            method = $result.Method
        }
    } catch {
        Write-Host "초기 측정 실패: $_" -ForegroundColor Red
        $state.Status = 'failed'
        Write-LogEvent @{ ev = 'measure_failed'; reason = "$_" }
    }
} else {
    Write-Host "브라우저에서 측정할 URL을 입력하세요." -ForegroundColor Cyan
}

try {
    $ntp = Get-NtpInfo
    $state.NtpInfo = @{ skewMs = $ntp.SkewMs; rttMs = $ntp.RttMs; at = $ntp.At.ToString('o') }
    Write-Host "NTP skew: $([Math]::Round($ntp.SkewMs,1)) ms (RTT $([Math]::Round($ntp.RttMs,1)) ms)"
    Write-LogEvent @{ ev = 'ntp'; skewMs = $ntp.SkewMs; rttMs = $ntp.RttMs }
} catch {
    Write-Host "NTP 점검 불가 (정보 표시 생략)" -ForegroundColor DarkGray
    $state.NtpInfo = $null
    Write-LogEvent @{ ev = 'ntp_failed'; reason = "$_" }
}

# HTTP 서버 시작
$server = Start-LocalHttpServer -State $state -PreferPort 8765 -WebRoot $webRoot

$measureTimer = New-Object System.Timers.Timer
$measureTimer.Interval = 100
$measureTimer.AutoReset = $false

$measureSubscription = Register-ObjectEvent `
    -InputObject $measureTimer `
    -EventName Elapsed `
    -SourceIdentifier 'MeasureTick' `
    -MessageData $state `
    -Action {
        $s = $Event.MessageData
        if (-not $s.TargetUrl) {
            $s.Status = 'idle'
            $s.MeasureInProgress = $false
            return
        }
        if ($s.Status -eq 'measuring' -and -not $s.MeasureInProgress) { return }
        $s.MeasureInProgress = $true
        $s.Status = 'measuring'
        Write-LogEvent @{ ev = 'measure_started'; host = $s.Host }
        try {
            $previousOffsetMs = [double]$s.OffsetMs
            $isTargetChange = [bool]$s.PendingTargetChange -or (-not $s.LastMeasureAt)
            $accepted = $false
            $lastResult = $null
            $lastDeltaMs = $null

            for ($attempt = 1; $attempt -le 2; $attempt++) {
                $r = Invoke-AdaptiveMultiSample -Url $s.TargetUrl
                $lastResult = $r
                $lastDeltaMs = [Math]::Abs([double]$r.OffsetMs - $previousOffsetMs)
                $s.LastRemeasureAttempts = $attempt
                $s.LastRemeasureDeltaMs = $lastDeltaMs

                if ($isTargetChange -or $lastDeltaMs -le 100) {
                    $accepted = $true
                    break
                }

                Write-LogEvent @{
                    ev = 'remeasure_retry'; host = $s.Host
                    attempt = $attempt; deltaMs = $lastDeltaMs
                    previousOffsetMs = $previousOffsetMs; newOffsetMs = $r.OffsetMs
                    thresholdMs = 100
                }
            }

            if ($accepted) {
                $s.OffsetMs      = $lastResult.OffsetMs
                $s.RttMedianMs   = $lastResult.RttMedianMs
                $s.SigmaMs       = $lastResult.SigmaMs
                $s.Ci95Ms        = $lastResult.Ci95Ms
                $s.LastMeasureAt = Get-PcUtcNow
                $s.LastRemeasureResult = 'accepted'
                $s.PendingTargetChange = $false
                $s.Status        = 'ok'
                Write-LogEvent @{
                    ev = 'measure'; host = $s.Host
                    offsetMs = $lastResult.OffsetMs; sigmaMs = $lastResult.SigmaMs
                    rttMedianMs = $lastResult.RttMedianMs
                    sampleCount = $lastResult.SampleCount; acceptedCount = $lastResult.AcceptedCount
                    attempt = $s.LastRemeasureAttempts; deltaMs = $lastDeltaMs
                    method = $lastResult.Method
                }
            } else {
                $s.LastRemeasureResult = 'rejected'
                $s.Status = 'ok'
                Write-LogEvent @{
                    ev = 'remeasure_rejected'; host = $s.Host
                    attempts = $s.LastRemeasureAttempts; deltaMs = $lastDeltaMs
                    previousOffsetMs = $previousOffsetMs; newOffsetMs = $lastResult.OffsetMs
                    thresholdMs = 100
                }
            }
            $s.LastRemeasureFinishedAt = Get-PcUtcNow
            $s.MeasureInProgress = $false
        } catch {
            $s.MeasureInProgress = $false
            $s.Status = 'failed'
            Write-LogEvent @{ ev = 'measure_failed'; reason = "$_" }
        }
    }
$state.MeasureTimer = $measureTimer

$ntpTimer = New-Object System.Timers.Timer
$ntpTimer.Interval = 600000
$ntpTimer.AutoReset = $true
$ntpSubscription = Register-ObjectEvent `
    -InputObject $ntpTimer `
    -EventName Elapsed `
    -SourceIdentifier 'NtpTick' `
    -MessageData $state `
    -Action {
        $s = $Event.MessageData
        try {
            $n = Get-NtpInfo
            $s.NtpInfo = @{ skewMs = $n.SkewMs; rttMs = $n.RttMs; at = $n.At.ToString('o') }
            Write-LogEvent @{ ev = 'ntp'; skewMs = $n.SkewMs; rttMs = $n.RttMs }
        } catch {
            $s.NtpInfo = $null
            Write-LogEvent @{ ev = 'ntp_failed'; reason = "$_" }
        }
    }
$ntpTimer.Start()

# 브라우저 자동 오픈
Start-Process "http://127.0.0.1:$($server.Port)/"

Write-Host ""
Write-Host "Ctrl+C로 종료" -ForegroundColor Yellow

try {
    & $server.Loop $server.Listener $state $webRoot
} finally {
    Write-Host ""
    Write-Host "타이머 정리..." -ForegroundColor Yellow
    if ($measureTimer) {
        $measureTimer.Stop()
        $measureTimer.Dispose()
    }
    if ($ntpTimer) {
        $ntpTimer.Stop()
        $ntpTimer.Dispose()
    }

    Write-Host "진행 중 측정 완료 대기 (max 10s)..."
    $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($state.Status -eq 'measuring' -and $waitSw.Elapsed.TotalSeconds -lt 10) {
        Start-Sleep -Milliseconds 200
    }

    if ($measureSubscription) {
        Unregister-Event -SourceIdentifier 'MeasureTick' -ErrorAction SilentlyContinue
        Remove-Job -Id $measureSubscription.Id -Force -ErrorAction SilentlyContinue
    }
    if ($ntpSubscription) {
        Unregister-Event -SourceIdentifier 'NtpTick' -ErrorAction SilentlyContinue
        Remove-Job -Job $ntpSubscription -Force -ErrorAction SilentlyContinue
    }

    Write-Host "HTTP 서버 정리..."
    Stop-LocalHttpServer $server.Listener

    Write-LogEvent @{ ev = 'shutdown' }
    Write-Host "종료 완료" -ForegroundColor Green
}
