# =============================================================================
# probe.ps1 - 앱의 메인 진입점 (ServerTimeProbe.exe / run.bat 가 이 파일을 실행)
# -----------------------------------------------------------------------------
# [전체 흐름]
#   1) 다른 모듈(.ps1)들을 불러온다.
#   2) 시계 기준점(anchor)과 로거를 초기화한다.
#   3) 시작 시 URL이 주어졌으면 1회 초기 측정을 한다(없으면 브라우저에서 입력받음).
#   4) 로컬 HTTP 서버를 띄우고 브라우저를 연다.
#   5) "측정 타이머"를 만들어, 측정/재측정/빠른측정 요청이 오면 백그라운드에서 측정.
#   6) 서버 요청 루프를 돈다(여기서 프로그램이 머문다). Ctrl+C로 빠져나오면 정리.
#
# [알아둘 PowerShell 문법]
#   . "경로.ps1"      → 다른 파일을 "불러오기"(그 안의 함수를 여기서 쓰게 됨). dot-sourcing.
#   $PSScriptRoot     → 지금 이 .ps1이 있는 폴더 경로.
#   $변수 = if (조건) { A } else { B }  → if 자체가 값을 돌려줘 변수에 바로 담을 수 있다.
#   함수 -이름 값      → 함수 호출 시 인자를 "-파라미터이름 값" 으로 준다(named argument).
# =============================================================================

# param(...) : 이 스크립트가 받는 실행 인자. -TargetUrl 'https://...' 처럼 줄 수 있고,
#              안 주면 빈 문자열(''). 비어 있으면 브라우저에서 URL을 입력받는다.
param(
    [string]$TargetUrl = ''
)

# 에러가 나면 그 즉시 멈춘다(조용히 무시하지 않음). 측정 워커가 멈추는 사고 방지.
$ErrorActionPreference = 'Stop'

# 필요한 모듈들을 모두 로드(dot-sourcing). 이 줄들 덕분에 아래에서
# Initialize-Anchor / Invoke-AdaptiveMultiSample / New-StateStore 등을 바로 쓸 수 있다.
. "$PSScriptRoot\anchor.ps1"
. "$PSScriptRoot\measurement.ps1"
. "$PSScriptRoot\http-server.ps1"
. "$PSScriptRoot\ntp.ps1"
. "$PSScriptRoot\logger.ps1"

# PowerShell 5.1 미만이면 동작 보장이 안 돼 종료. -lt = "보다 작다(less than)".
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "PowerShell 5.1 이상 필요" -ForegroundColor Red; exit 1
}

Initialize-Anchor                                              # 시계 기준점 1회 고정(anchor.ps1)
Initialize-Logger -LogDir (Join-Path $PSScriptRoot '..\logs')  # 로그 폴더 준비(logger.ps1)

# 시작 인자로 URL을 받았으면 형식 검증/정규화, 아니면 빈 문자열.
$url = if ($TargetUrl) { Normalize-TargetUrl -Url $TargetUrl } else { '' }
$webRoot = Join-Path $PSScriptRoot 'web'   # 웹 UI(index.html 등)가 있는 폴더

# 모든 측정 상태(현재 offset, 대상 URL, 상태값 등)를 담는 공유 저장소 생성(http-server.ps1).
$state = New-StateStore

# 시작할 때 URL이 주어졌다면 여기서 바로 1회 초기 측정을 한다.
if ($url) {
    Set-TargetState -State $state -Url $url -ForceInitialMeasure $true   # 대상 설정(+측정경로 정규화)
    $state.Status = 'measuring'
    Write-Host "초기 측정 (20초 이내): $($state.TargetUrl)"
    # $(...) = 문자열 안에서 식을 계산해 끼워넣기. -ne = "같지 않다".
    if ($state.MeasurementUrl -ne $state.TargetUrl) {
        Write-Host "측정 경로: $($state.MeasurementUrl)" -ForegroundColor DarkGray
    }
    try {
        # 실제 측정. -MaxTotalMs 20000 = 최대 20초 예산. 핵심 알고리즘은 measurement.ps1.
        $result = Invoke-AdaptiveMultiSample -Url $state.MeasurementUrl -MaxTotalMs 20000
        # 측정 결과의 각 값을 공유 상태에 복사(웹 UI가 /api/state로 이 값들을 읽어감).
        $state.OffsetMs      = $result.OffsetMs
        $state.RttMedianMs   = $result.RttMedianMs
        $state.SigmaMs       = $result.SigmaMs
        $state.Ci95Ms        = $result.Ci95Ms
        $state.SampleCount   = $result.SampleCount
        $state.AcceptedCount = $result.AcceptedCount
        $state.Method        = $result.Method
        $state.IntersectWidthMs = $result.IntersectWidthMs
        Set-MeasurementRuntimeState -State $state -Result $result
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
            defaultTimeoutMs = $result.DefaultTimeoutMs; adaptiveTimeoutMs = $result.AdaptiveTimeoutMs
            probeMode = $result.ProbeMode
            attemptedProbeCount = $result.AttemptedProbeCount; failedProbeCount = $result.FailedProbeCount
            wallElapsedMs = $result.WallElapsedMs; stopReason = $result.StopReason
            method = $result.Method
        }
    } catch {
        # catch 블록: try 안에서 에러가 나면 여기로 온다. $_ = 발생한 에러 객체.
        Write-Host "초기 측정 실패: $_" -ForegroundColor Red
        $state.Status = 'failed'
        Write-LogEvent @{ ev = 'measure_failed'; targetUrl = $state.TargetUrl; measurementUrl = $state.MeasurementUrl; reason = "$_" }
    }
} else {
    # 시작 URL이 없으면 측정은 나중에 브라우저 입력으로.
    Write-Host "브라우저에서 측정할 URL을 입력하세요." -ForegroundColor Cyan
}

# NTP 참고 정보 1회 조회(표시용, 보정엔 미사용). 실패해도 앱은 계속 동작.
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

# 로컬 HTTP 서버 시작(http-server.ps1). 8765 포트가 막혀 있으면 +1씩 다른 포트 시도.
$server = Start-LocalHttpServer -State $state -PreferPort 8765 -WebRoot $webRoot

# --- 측정 타이머 ---
# "재측정/빠른측정 요청이 오면 0.1초 뒤 한 번 측정을 돌리는" 1회성 타이머.
# AutoReset=$false → 한 번 울리고 멈춤(반복 안 함). 매 요청마다 다시 Start()로 깨운다.
$measureTimer = New-Object System.Timers.Timer
$measureTimer.Interval = 100        # 100ms 뒤에 울림(Elapsed 이벤트 발생)
$measureTimer.AutoReset = $false

# Register-ObjectEvent : "타이머가 울리면(Elapsed) 아래 -Action 블록을 실행하라"고 등록.
#   끝의 백틱(`)은 "줄이 다음 줄로 이어진다"는 줄 연결 표시(한 명령을 여러 줄로 씀).
#   -MessageData $state : 핸들러 안으로 공유 상태를 넘겨준다($Event.MessageData로 꺼냄).
#   -Action { ... }     : 타이머가 울릴 때마다 실행되는 본체(측정 로직 전체가 여기 있음).
$measureSubscription = Register-ObjectEvent `
    -InputObject $measureTimer `
    -EventName Elapsed `
    -SourceIdentifier 'MeasureTick' `
    -MessageData $state `
    -Action {
        # $Event = 방금 발생한 이벤트. .MessageData가 위에서 넘긴 $state(공유 상태).
        $s = $Event.MessageData
        # 이벤트 핸들러는 별도 실행 맥락이라, 필요한 함수가 안 보이면 모듈을 다시 로드한다.
        if (-not (Get-Command Invoke-AdaptiveMultiSample -ErrorAction SilentlyContinue)) {
            . "$($s.ScriptRoot)\anchor.ps1"
            . "$($s.ScriptRoot)\measurement.ps1"
            . "$($s.ScriptRoot)\logger.ps1"
        }
        # 측정할 대상이 아직 없으면 그냥 대기(idle) 상태로 두고 끝낸다.
        if (-not $s.TargetUrl) {
            $s.Status = 'idle'
            $s.MeasureInProgress = $false
            return
        }
        # 이미 측정 중이면 중복 실행 방지(겹치면 안 됨).
        if ($s.MeasureInProgress) { return }
        $s.MeasureInProgress = $true    # "측정 중" 표시(잠금)
        $s.Status = 'measuring'

        # 빠른 측정: 게이트/재시도 없이 1회 측정 후 그대로 채택(최대 5초). 정밀 경로와 분리.
        if ($s.MeasureMode -eq 'fast') {
            try {
                try { Write-LogEvent @{ ev = 'measure_started'; mode = 'fast'; host = $s.Host; targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl } } catch {}
                $measurementUrl = if ($s.MeasurementUrl) { $s.MeasurementUrl } else { $s.TargetUrl }
                # DefaultTimeoutMs=2000: RTT probe 단계의 데드라인 reserve를 2초로 낮춰
                # 5초 budget 안에서 probe가 실행되게 한다(기본 5초면 reserve==budget이라
                # 첫 probe도 못 돌리고 "All initial RTT probes failed"로 죽는다). 적응형
                # timeout도 ≤2초로 묶여 5초 cap 유지.
                # MinSampleFraction=0.15: 느리고 들쭉날쭉한 서버(예: den08.inames.kr)에서
                # 짧은 timeout 탓에 샘플 절반이 실패해도 throw하지 말고 적은 샘플로 거친
                # 결과(보통 upper-envelope/소수 edge)라도 낸다. 빠른 측정의 취지(정확도
                # 포기, 일단 빨리 뭐라도)에 맞춤.
                $r = Invoke-AdaptiveMultiSample -Url $measurementUrl -TargetWindowMs 2500 -MinEdgeCount 1 -MaxTotalMs 5000 -DefaultTimeoutMs 2000 -MinSampleFraction 0.15
                $s.OffsetMs = $r.OffsetMs; $s.RttMedianMs = $r.RttMedianMs; $s.SigmaMs = $r.SigmaMs
                $s.Ci95Ms = $r.Ci95Ms; $s.SampleCount = $r.SampleCount; $s.AcceptedCount = $r.AcceptedCount
                $s.Method = $r.Method; $s.IntersectWidthMs = $r.IntersectWidthMs
                Set-MeasurementRuntimeState -State $s -Result $r
                $s.LastSamples = $r.Samples; $s.LastEdges = $r.Edges
                $s.LastMeasureAt = Get-PcUtcNow; $s.LastMeasureMode = 'fast'
                $s.LastRemeasureResult = 'fast'; $s.LastError = ''; $s.Status = 'ok'
                $s.PendingTargetChange = $false
                Write-LogEvent @{
                    ev = 'measure'; mode = 'fast'; host = $s.Host
                    targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl; measurementNote = $s.MeasurementNote
                    offsetMs = $r.OffsetMs; sigmaMs = $r.SigmaMs; rttMedianMs = $r.RttMedianMs
                    sampleCount = $r.SampleCount; acceptedCount = $r.AcceptedCount
                    defaultTimeoutMs = $r.DefaultTimeoutMs; adaptiveTimeoutMs = $r.AdaptiveTimeoutMs
                    probeMode = $r.ProbeMode
                    attemptedProbeCount = $r.AttemptedProbeCount; failedProbeCount = $r.FailedProbeCount
                    wallElapsedMs = $r.WallElapsedMs; stopReason = $r.StopReason
                    method = $r.Method
                }
            } catch {
                $s.LastError = "$_"
                if ($s.LastMeasureAt) { $s.LastRemeasureResult = 'failed'; $s.Status = 'ok' } else { $s.Status = 'failed' }
                try { Write-LogEvent @{ ev = 'measure_failed'; mode = 'fast'; targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl; reason = "$_" } } catch {}
            } finally {
                $s.MeasureMode = 'normal'
                $s.MeasureInProgress = $false
                $s.LastRemeasureFinishedAt = Get-PcUtcNow
            }
            return
        }

        # ---- 정밀(일반) 측정 경로 ----
        # 흐름: 최대 2회까지 측정을 시도하면서, 매 시도의 결과를 기존 offset과 비교해
        #       Get-RemeasureAttemptDecision이 '반영/유지/실패/재시도' 중 무엇인지 판정한다.
        #       (빠른 측정은 위에서 이미 return 했으므로 여기 오지 않는다.)
        try {
            try { Write-LogEvent @{ ev = 'measure_started'; host = $s.Host; targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl } } catch {}
            $s.LastMeasureMode = 'normal'                  # 이번 측정은 정밀(빠른 측정 아님) 표시
            $previousOffsetMs = [double]$s.OffsetMs         # 비교 기준이 될 기존 offset
            # 타겟 변경(또는 첫 측정)인가? 그러면 비교 없이 새 값을 무조건 반영한다.
            $isTargetChange = [bool]$s.PendingTargetChange -or (-not $s.LastMeasureAt)
            # 아래 루프의 결과를 담을 깃발/변수들. $false/$null로 초기화.
            $accepted = $false
            $keepExisting = $false
            $insufficientEdges = $false
            $lastResult = $null
            $lastDeltaMs = $null

            # 재측정은 15초 하드캡, 첫 측정/타겟 변경은 20초 하드캡.
            # 재측정 캡은 2회 시도 전체에 공유.
            # 10초였을 때 edge를 천천히 뱉는 호스트(예: den08.inames.kr)가
            # 초기측정(20초)에선 edge 9개를 뽑으면서 재측정에선 4개에 그쳐
            # fail-insufficient가 반복됨(데이터는 clean, 시간만 부족). cap은 상한이라
            # 빠른 호스트는 일찍 accept하고 빠져나가므로 올려도 그쪽 비용은 없음.
            $InitialMeasureBudgetMs = 20000
            $RemeasureBudgetMs = 15000
            $budgetSw = [System.Diagnostics.Stopwatch]::StartNew()

            # 최대 2회 시도(delta가 너무 크면 한 번 더 확인하기 위함).
            for ($attempt = 1; $attempt -le 2; $attempt++) {
                if ($isTargetChange) {
                    $maxTotalMs = $InitialMeasureBudgetMs   # 첫 측정/타겟 변경: 20초 예산
                } else {
                    # 재측정: 남은 예산 = 15초 - 지금까지 쓴 시간(2회가 예산을 나눠 씀).
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

                # 이번 결과를 어떻게 처리할지 판정(measurement.ps1의 규칙 함수).
                $decision = Get-RemeasureAttemptDecision -IsTargetChange $isTargetChange `
                    -AcceptedCount ([int]$r.AcceptedCount) -DeltaMs $lastDeltaMs
                # break = 반복문 즉시 종료(더 시도 안 함).
                if ($decision -eq 'accept') { $accepted = $true; break }            # 새 값 반영
                if ($decision -eq 'keep-existing') { $keepExisting = $true; break }  # 거의 같음 → 유지
                if ($decision -eq 'fail-insufficient') { $insufficientEdges = $true; break }  # edge<5 → 실패

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
                Set-MeasurementRuntimeState -State $s -Result $lastResult
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
                    defaultTimeoutMs = $lastResult.DefaultTimeoutMs; adaptiveTimeoutMs = $lastResult.AdaptiveTimeoutMs
                    probeMode = $lastResult.ProbeMode
                    attemptedProbeCount = $lastResult.AttemptedProbeCount; failedProbeCount = $lastResult.FailedProbeCount
                    wallElapsedMs = $lastResult.WallElapsedMs; stopReason = $lastResult.StopReason
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
                    attemptedProbeCount = $lastResult.AttemptedProbeCount; failedProbeCount = $lastResult.FailedProbeCount
                    wallElapsedMs = $lastResult.WallElapsedMs; stopReason = $lastResult.StopReason
                }
            } elseif ($insufficientEdges) {
                # edge 부족: 적은 edge로 갱신하지 않고 기존 offset 유지. 실패만 표시.
                $s.LastRemeasureResult = 'failed-insufficient-edges'
                $s.Status = 'ok'
                Write-LogEvent @{
                    ev = 'remeasure_failed_insufficient'; host = $s.Host
                    targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl
                    acceptedCount = [int]$lastResult.AcceptedCount; method = $lastResult.Method
                    attemptedProbeCount = $lastResult.AttemptedProbeCount; failedProbeCount = $lastResult.FailedProbeCount
                    wallElapsedMs = $lastResult.WallElapsedMs; stopReason = $lastResult.StopReason
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
                    attemptedProbeCount = $lastResult.AttemptedProbeCount; failedProbeCount = $lastResult.FailedProbeCount
                    wallElapsedMs = $lastResult.WallElapsedMs; stopReason = $lastResult.StopReason
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
# 만든 타이머를 공유 상태에 보관(http-server.ps1이 재측정 시 이 타이머를 깨움).
$state.MeasureTimer = $measureTimer

# --- NTP 타이머 --- 10분(600000ms)마다 반복(AutoReset=$true)해서 PC 시계 오차를 갱신.
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
$ntpTimer.Start()   # NTP 타이머 가동(10분마다 반복)

# 기본 브라우저로 로컬 시계 페이지를 자동으로 연다.
Start-Process "http://127.0.0.1:$($server.Port)/"

Write-Host ""
Write-Host "Ctrl+C로 종료" -ForegroundColor Yellow

# 여기가 프로그램이 머무는 곳. & 는 "호출 연산자"로, $server.Loop에 담긴 함수를 실행한다.
# 이 루프가 브라우저의 요청을 계속 받아 처리하며, Ctrl+C 등으로 끝나면 finally로 간다.
try {
    & $server.Loop $server.Listener $state $webRoot
} finally {
    # finally: 정상 종료/에러/Ctrl+C 무엇이든 마지막에 반드시 실행 → 자원 정리.
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

    # 측정이 진행 중이면 끝날 때까지 잠깐 기다린다(최대 10초). 중간에 끊기지 않게.
    Write-Host "진행 중 측정 완료 대기 (max 10s)..."
    $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($state.Status -eq 'measuring' -and $waitSw.Elapsed.TotalSeconds -lt 10) {
        Start-Sleep -Milliseconds 200
    }

    # 등록했던 이벤트 구독과 백그라운드 작업을 해제(누수 방지).
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
