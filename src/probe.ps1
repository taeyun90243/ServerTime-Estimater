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
if ($url) {
    Set-TargetState -State $state -Url $url -ForceInitialMeasure $true
    $state.Status = 'measuring'
    Write-Host "초기 측정 (20초 이내): $($state.TargetUrl)"
    if ($state.MeasurementUrl -ne $state.TargetUrl) {
        Write-Host "측정 경로: $($state.MeasurementUrl)" -ForegroundColor DarkGray
    }
    try {
        $result = Invoke-AdaptiveMultiSample -Url $state.MeasurementUrl -MaxTotalMs 20000
        $state.OffsetMs      = $result.OffsetMs
        $state.RttMedianMs   = $result.RttMedianMs
        $state.SigmaMs       = $result.SigmaMs
        $state.Ci95Ms        = $result.Ci95Ms
        $state.SampleCount   = $result.SampleCount
        $state.AcceptedCount = $result.AcceptedCount
        $state.Method        = $result.Method
        $state.IntersectWidthMs = $result.IntersectWidthMs
        $state.LastSamples   = $result.Samples
        $state.LastEdges     = $result.Edges
        $state.LastMeasureAt = Get-PcUtcNow
        $state.PendingTargetChange = $false
        $state.LastError     = ''
        $state.Status        = 'ok'
        Write-Host "초기 오프셋: $([Math]::Round($result.OffsetMs,1)) ms (±$([Math]::Round($result.Ci95Ms,1)))"
        Write-LogEvent @{
            ev = 'measure'; host = $state.Host
            targetUrl = $state.TargetUrl; measurementUrl = $state.MeasurementUrl; measurementNote = $state.MeasurementNote
            offsetMs = $result.OffsetMs; sigmaMs = $result.SigmaMs
            rttMedianMs = $result.RttMedianMs
            sampleCount = $result.SampleCount; acceptedCount = $result.AcceptedCount
            method = $result.Method
        }
    } catch {
        Write-Host "초기 측정 실패: $_" -ForegroundColor Red
        $state.Status = 'failed'
        Write-LogEvent @{ ev = 'measure_failed'; targetUrl = $state.TargetUrl; measurementUrl = $state.MeasurementUrl; reason = "$_" }
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
        if (-not (Get-Command Invoke-AdaptiveMultiSample -ErrorAction SilentlyContinue)) {
            . "$($s.ScriptRoot)\anchor.ps1"
            . "$($s.ScriptRoot)\measurement.ps1"
            . "$($s.ScriptRoot)\logger.ps1"
        }
        if (-not $s.TargetUrl) {
            $s.Status = 'idle'
            $s.MeasureInProgress = $false
            return
        }
        if ($s.MeasureInProgress) { return }
        $s.MeasureInProgress = $true
        $s.Status = 'measuring'
        try {
            try { Write-LogEvent @{ ev = 'measure_started'; host = $s.Host; targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl } } catch {}
            $previousOffsetMs = [double]$s.OffsetMs
            $isTargetChange = [bool]$s.PendingTargetChange -or (-not $s.LastMeasureAt)
            $accepted = $false
            $keepExisting = $false
            $insufficientEdges = $false
            $lastResult = $null
            $lastDeltaMs = $null

            # 재측정은 10초 하드캡, 첫 측정/타겟 변경은 20초 하드캡.
            # 재측정 캡은 2회 시도 전체에 공유.
            $InitialMeasureBudgetMs = 20000
            $RemeasureBudgetMs = 10000
            $budgetSw = [System.Diagnostics.Stopwatch]::StartNew()

            for ($attempt = 1; $attempt -le 2; $attempt++) {
                if ($isTargetChange) {
                    $maxTotalMs = $InitialMeasureBudgetMs
                } else {
                    $remainingMs = $RemeasureBudgetMs - $budgetSw.Elapsed.TotalMilliseconds
                    # 2회차를 시작할 시간이 부족하면 더 시도 안 함(기존값 유지로 귀결).
                    if ($attempt -gt 1 -and $remainingMs -lt 2000) { break }
                    $maxTotalMs = [int][Math]::Max(0, $remainingMs)
                }

                $measurementUrl = if ($s.MeasurementUrl) { $s.MeasurementUrl } else { $s.TargetUrl }
                $r = Invoke-AdaptiveMultiSample -Url $measurementUrl -MaxTotalMs $maxTotalMs
                $lastResult = $r
                $lastDeltaMs = [Math]::Abs([double]$r.OffsetMs - $previousOffsetMs)
                $s.LastRemeasureAttempts = $attempt
                $s.LastRemeasureDeltaMs = $lastDeltaMs

                $decision = Get-RemeasureAttemptDecision -IsTargetChange $isTargetChange `
                    -AcceptedCount ([int]$r.AcceptedCount) -DeltaMs $lastDeltaMs
                if ($decision -eq 'accept') { $accepted = $true; break }
                if ($decision -eq 'keep-existing') { $keepExisting = $true; break }
                if ($decision -eq 'fail-insufficient') { $insufficientEdges = $true; break }

                # 'delta-exceeded' → 재시도
                Write-LogEvent @{
                    ev = 'remeasure_retry'; host = $s.Host
                    targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl
                    attempt = $attempt; deltaMs = $lastDeltaMs
                    previousOffsetMs = $previousOffsetMs; newOffsetMs = $r.OffsetMs
                    thresholdMs = 100
                }
            }

            if ($lastResult) {
                $s.LastSamples = $lastResult.Samples
                $s.LastEdges = $lastResult.Edges
            }

            if ($accepted) {
                $s.OffsetMs      = $lastResult.OffsetMs
                $s.RttMedianMs   = $lastResult.RttMedianMs
                $s.SigmaMs       = $lastResult.SigmaMs
                $s.Ci95Ms        = $lastResult.Ci95Ms
                $s.SampleCount   = $lastResult.SampleCount
                $s.AcceptedCount = $lastResult.AcceptedCount
                $s.Method        = $lastResult.Method
                $s.IntersectWidthMs = $lastResult.IntersectWidthMs
                $s.LastMeasureAt = Get-PcUtcNow
                $s.LastRemeasureResult = 'accepted'
                $s.PendingTargetChange = $false
                $s.LastError     = ''
                $s.Status        = 'ok'
                Write-LogEvent @{
                    ev = 'measure'; host = $s.Host
                    targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl; measurementNote = $s.MeasurementNote
                    offsetMs = $lastResult.OffsetMs; sigmaMs = $lastResult.SigmaMs
                    rttMedianMs = $lastResult.RttMedianMs
                    sampleCount = $lastResult.SampleCount; acceptedCount = $lastResult.AcceptedCount
                    attempt = $s.LastRemeasureAttempts; deltaMs = $lastDeltaMs
                    method = $lastResult.Method
                }
            } elseif ($keepExisting) {
                # 기존값과 거의 같으면 미세한 측정 흔들림으로 offset을 덮어쓰지 않는다.
                $s.LastRemeasureResult = 'kept-small-delta'
                $s.Status = 'ok'
                Write-LogEvent @{
                    ev = 'remeasure_kept_small_delta'; host = $s.Host
                    targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl
                    attempt = $s.LastRemeasureAttempts; deltaMs = $lastDeltaMs
                    previousOffsetMs = $previousOffsetMs; newOffsetMs = $lastResult.OffsetMs
                    thresholdMs = 30
                }
            } elseif ($insufficientEdges) {
                # edge 부족: 적은 edge로 갱신하지 않고 기존 offset 유지. 실패만 표시.
                $s.LastRemeasureResult = 'failed-insufficient-edges'
                $s.Status = 'ok'
                Write-LogEvent @{
                    ev = 'remeasure_failed_insufficient'; host = $s.Host
                    targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl
                    acceptedCount = [int]$lastResult.AcceptedCount; method = $lastResult.Method
                    previousOffsetMs = $previousOffsetMs; newOffsetMs = $lastResult.OffsetMs
                }
            } else {
                $s.LastRemeasureResult = 'rejected'
                $s.Status = 'ok'
                Write-LogEvent @{
                    ev = 'remeasure_rejected'; host = $s.Host
                    targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl
                    attempts = $s.LastRemeasureAttempts; deltaMs = $lastDeltaMs
                    previousOffsetMs = $previousOffsetMs; newOffsetMs = $lastResult.OffsetMs
                    thresholdMs = 100
                }
            }
            $s.LastRemeasureFinishedAt = Get-PcUtcNow
            $s.MeasureInProgress = $false
        } catch {
            $s.MeasureInProgress = $false
            $s.LastError = "$_"
            if ($s.LastMeasureAt) {
                $s.LastRemeasureResult = 'failed'
                $s.LastRemeasureFinishedAt = Get-PcUtcNow
                $s.Status = 'ok'
            } else {
                $s.Status = 'failed'
            }
            try { Write-LogEvent @{ ev = 'measure_failed'; targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl; reason = "$_" } } catch {}
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
        if (-not (Get-Command Get-NtpInfo -ErrorAction SilentlyContinue)) {
            . "$($s.ScriptRoot)\anchor.ps1"
            . "$($s.ScriptRoot)\ntp.ps1"
            . "$($s.ScriptRoot)\logger.ps1"
        }
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
