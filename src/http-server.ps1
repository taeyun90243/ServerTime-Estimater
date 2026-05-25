# =============================================================================
# http-server.ps1 - 로컬 웹 서버 + 공유 상태 저장소
# -----------------------------------------------------------------------------
# [역할] 127.0.0.1:8765 에서만 듣는 작은 HTTP 서버를 돌려, 브라우저에 시계 UI(정적
#        파일)와 측정 상태(API)를 제공한다. 외부에는 열리지 않는다(로컬 전용).
#
# [API 목록]
#   GET  /                → 시계 페이지(index.html)
#   GET  /clock.css, /clock.js → 정적 자원
#   GET  /api/state       → 현재 측정 상태(JSON). 브라우저가 1초마다 폴링.
#   GET  /api/samples     → 측정 상세(샘플/edge 배열) — "측정 상세 보기"용
#   POST /api/target      → 측정할 URL 설정(+초기 측정 시작)
#   POST /api/remeasure   → 같은 대상 재측정(정밀, 최대 15초)
#   POST /api/measure-fast→ 빠른 측정(저정확도, 최대 5초)
# =============================================================================
. "$PSScriptRoot\anchor.ps1"
. "$PSScriptRoot\logger.ps1"

# 모든 측정 상태를 담는 "공유 저장소"를 만든다.
# [hashtable]::Synchronized(...) = 여러 스레드(웹 요청 처리 + 측정 타이머 이벤트)가
# 동시에 같은 해시테이블을 안전하게 읽고 쓰도록 잠금 처리된 버전으로 감싼다.
function New-StateStore {
    return [hashtable]::Synchronized(@{
        Host          = ''        # 현재 대상 호스트(예: den08.inames.kr)
        TargetUrl     = ''        # 화면에 보여줄 대상 URL(정규화됨)
        MeasurementUrl = ''       # 실제로 Date를 재는 URL(캐시버스터 등 포함될 수 있음)
        MeasurementNote = ''      # 사이트별 측정 메모(예: 인터파크 경로)
        PendingTargetChange = $false  # 다음 측정이 "타겟 변경"인가(=비교 없이 새 값 반영)
        MeasureMode   = 'normal'      # 다음에 돌릴 측정 종류: 'normal'(정밀) / 'fast'(빠른)
        LastMeasureMode = 'normal'    # 마지막으로 완료한 측정 종류(UI 라벨용)
        OffsetMs      = 0.0       # 핵심 결과: 서버시각 - PC시각 (밀리초)
        LastMeasureAt = $null     # 마지막 측정이 "반영된" 시각(이게 바뀌면 UI가 시계 갱신)
        LastMeasureRequestedAt = $null   # 측정 "요청" 시각(요청>반영이면 진행/대기 중)
        LastRemeasureFinishedAt = $null  # 재측정/빠른측정이 끝난 시각(성공/실패 무관)
        LastRemeasureResult = ''  # 결과: accepted/kept-small-delta/rejected/failed/fast 등
        LastRemeasureDeltaMs = $null     # 기존값과 새값의 차이(ms)
        LastRemeasureAttempts = 0        # 이번 측정에서 시도한 횟수(1~2)
        LastError     = ''        # 마지막 실패 사유 텍스트
        MeasureInProgress = $false       # 측정 중 잠금(중복 실행 방지)
        PageServed    = $false    # 첫 페이지를 이미 보냈는지
        RttMedianMs   = 0.0       # 샘플 RTT 중앙값
        SigmaMs       = 0.0       # edge 중점 산포
        Ci95Ms        = 0.0       # 보고 ±값(교집합 계열은 일치폭/2)
        SampleCount   = 0         # 사용한 샘플 수
        AcceptedCount = 0         # 채택된(합의된) edge 수
        Method        = ''        # 추정 방법(edge-intersect 등)
        IntersectWidthMs = 0.0    # 교집합 폭
        MeasurementWallElapsedMs = 0.0
        AttemptedProbeCount = 0
        FailedProbeCount = 0
        StopReason = ''
        AdaptiveTimeoutMs = 0
        DefaultTimeoutMs = 0
        ProbeMode = ''
        LastSamples   = @()       # 상세 보기용 샘플 배열(@() = 빈 배열)
        LastEdges     = @()       # 상세 보기용 edge 배열
        Status        = 'idle'    # idle/queued/measuring/ok/failed/stale
        NtpInfo       = $null     # 참고용 NTP 정보
        ScriptRoot    = $PSScriptRoot    # 모듈 재로드용 폴더 경로
    })
}

# HTTP 리스너를 만들어 시작하고, 요청 처리 루프(Loop)를 담은 객체를 돌려준다.
function Start-LocalHttpServer {
    param(
        [Parameter(Mandatory)]$State,
        [int]$PreferPort = 8765,
        [Parameter(Mandatory)][string]$WebRoot
    )
    # 원하는 포트가 이미 쓰이면 +1씩 올려가며 최대 10번 시도.
    $listener = $null
    $port = $PreferPort
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://127.0.0.1:$port/")   # 127.0.0.1 = 이 PC에서만 접근
            $listener.Start()
            break                                                # 성공하면 반복 종료
        } catch {
            $listener = $null
            $port++                                              # 실패하면 다음 포트로
        }
    }
    if ($null -eq $listener) { throw "Failed to bind any port in $PreferPort..$($PreferPort+9)" }

    Write-Host "HTTP 서버: http://127.0.0.1:$port/" -ForegroundColor Cyan

    # 결과 객체. Loop는 "스크립트 블록"(나중에 & 로 실행할 코드 덩어리)으로 담아둔다.
    return @{
        Listener = $listener
        Port     = $port
        Loop     = {
            param($listener, $state, $webRoot)
            # 서버가 살아있는 동안 요청을 하나씩 받아 처리.
            while ($listener.IsListening) {
                try {
                    $ctx = $listener.GetContext()      # 요청이 올 때까지 여기서 대기(블로킹)
                    $req = $ctx.Request                # 들어온 요청
                    $resp = $ctx.Response              # 돌려줄 응답
                    $resp.Headers.Add('Cache-Control', 'no-store')   # 캐시 금지(항상 최신)
                    Handle-Request $req $resp $state $webRoot         # 경로별 처리
                    $resp.Close()                      # 응답 마무리(전송)
                } catch [System.Net.HttpListenerException] {
                    break                              # 서버가 닫히는 중이면 루프 종료
                } catch {
                    # 개별 요청 하나가 실패해도 서버 전체는 죽지 않게 무시하고 계속.
                }
            }
        }
    }
}

# 요청 1건을 경로(path)에 따라 알맞은 처리로 분기하는 라우터.
function Handle-Request {
    param($req, $resp, $state, $webRoot)
    $path = $req.Url.AbsolutePath   # 예: "/", "/api/state", "/api/measure-fast"
    # 정적 파일들: 시계 페이지와 그 자원.
    if ($path -eq '/' -or $path -eq '/index.html') {
        $state.PageServed = $true
        Write-StaticFile $resp (Join-Path $webRoot 'index.html') 'text/html; charset=utf-8'
    } elseif ($path -eq '/clock.css') {
        Write-StaticFile $resp (Join-Path $webRoot 'clock.css') 'text/css; charset=utf-8'
    } elseif ($path -eq '/clock.js') {
        Write-StaticFile $resp (Join-Path $webRoot 'clock.js') 'application/javascript; charset=utf-8'
    # API들: 상태/상세 조회(GET)와 측정 트리거(POST).
    } elseif ($path -eq '/api/state') {
        Write-StateJson $resp $state
    } elseif ($path -eq '/api/samples') {
        Write-SamplesJson $resp $state
    } elseif ($path -eq '/api/target') {
        # 측정 트리거는 POST만 허용. GET 등으로 오면 405(Method Not Allowed)로 거절.
        if ($req.HttpMethod -ne 'POST') {
            $resp.StatusCode = 405
            Write-JsonResponse $resp @{ ok = $false; error = 'Method Not Allowed' }
            return
        }
        Set-TargetFromRequest $req $resp $state
    } elseif ($path -eq '/api/remeasure') {
        if ($req.HttpMethod -ne 'POST') {
            $resp.StatusCode = 405
            Write-JsonResponse $resp @{ ok = $false; error = 'Method Not Allowed' }
            return
        }
        Start-RemeasureFromRequest $resp $state
    } elseif ($path -eq '/api/measure-fast') {
        if ($req.HttpMethod -ne 'POST') {
            $resp.StatusCode = 405
            Write-JsonResponse $resp @{ ok = $false; error = 'Method Not Allowed' }
            return
        }
        Start-FastMeasureFromRequest $resp $state
    } else {
        $resp.StatusCode = 404
        $bytes = [Text.Encoding]::UTF8.GetBytes('Not Found')
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    }
}

function Start-RemeasureFromRequest {
    param($resp, $state)

    if (-not $state.TargetUrl -or -not $state.LastMeasureAt) {
        $resp.StatusCode = 409
        Write-JsonResponse $resp @{ ok = $false; error = '먼저 측정을 완료하세요.' }
        return
    }
    if (-not $state.MeasureTimer) {
        $resp.StatusCode = 500
        Write-JsonResponse $resp @{ ok = $false; error = '측정 타이머가 준비되지 않았습니다.' }
        return
    }
    if ($state.MeasureInProgress -or $state.MeasureTimer.Enabled) {
        Write-JsonResponse $resp @{ ok = $true; alreadyRunning = $true }
        return
    }

    $state.LastMeasureRequestedAt = Get-PcUtcNow
    $state.LastRemeasureFinishedAt = $null
    $state.LastRemeasureResult = ''
    $state.LastRemeasureDeltaMs = $null
    $state.LastRemeasureAttempts = 0
    $previousTargetUrl = $state.TargetUrl
    if (Get-Command Resolve-MeasurementTarget -ErrorAction SilentlyContinue) {
        $measurementTarget = Resolve-MeasurementTarget -Url $state.TargetUrl
        $state.TargetUrl = $measurementTarget.TargetUrl
        $state.Host = ([Uri]$measurementTarget.TargetUrl).Host
        $state.MeasurementUrl = $measurementTarget.MeasurementUrl
        $state.MeasurementNote = $measurementTarget.MeasurementNote
    }
    # A remeasure of the same canonical target must still go through the
    # existing delta guard: <=30ms keep existing, <=100ms accept, >100ms retry.
    # Some sites (Interpark) get a fresh cache-busted MeasurementUrl every time,
    # but that is not a target change.
    $state.PendingTargetChange = ($previousTargetUrl -ne $state.TargetUrl)
    $state.MeasureInProgress = $false
    $state.Status = 'queued'
    Write-LogEvent @{ ev = 'remeasure_requested'; source = 'button'; host = $state.Host }
    Restart-MeasureTimer $state.MeasureTimer
    Write-JsonResponse $resp @{ ok = $true }
}

function Start-FastMeasureFromRequest {
    param($resp, $state)

    if (-not $state.TargetUrl) {
        $resp.StatusCode = 409
        Write-JsonResponse $resp @{ ok = $false; error = '먼저 측정 대상을 입력하세요.' }
        return
    }
    if (-not $state.MeasureTimer) {
        $resp.StatusCode = 500
        Write-JsonResponse $resp @{ ok = $false; error = '측정 타이머가 준비되지 않았습니다.' }
        return
    }
    if ($state.MeasureInProgress -or $state.MeasureTimer.Enabled) {
        Write-JsonResponse $resp @{ ok = $true; alreadyRunning = $true }
        return
    }

    $state.LastMeasureRequestedAt = Get-PcUtcNow
    $state.LastRemeasureFinishedAt = $null
    $state.LastRemeasureResult = ''
    $state.LastRemeasureDeltaMs = $null
    $state.LastRemeasureAttempts = 0
    if (Get-Command Resolve-MeasurementTarget -ErrorAction SilentlyContinue) {
        $measurementTarget = Resolve-MeasurementTarget -Url $state.TargetUrl
        $state.TargetUrl = $measurementTarget.TargetUrl
        $state.Host = ([Uri]$measurementTarget.TargetUrl).Host
        $state.MeasurementUrl = $measurementTarget.MeasurementUrl
        $state.MeasurementNote = $measurementTarget.MeasurementNote
    }
    # 타겟 변경이 아니라 명시적 빠른 측정. fast 경로는 게이트/재시도 없이 1회 채택.
    $state.PendingTargetChange = $false
    $state.MeasureMode = 'fast'
    $state.MeasureInProgress = $false
    $state.Status = 'queued'
    Write-LogEvent @{ ev = 'fast_measure_requested'; source = 'button'; host = $state.Host }
    Restart-MeasureTimer $state.MeasureTimer
    Write-JsonResponse $resp @{ ok = $true }
}

function Restart-MeasureTimer {
    param($Timer)
    if (-not $Timer) { return }
    $Timer.Stop()
    $Timer.Start()
}

function Normalize-TargetUrl {
    param([Parameter(Mandatory)][string]$Url)

    $value = $Url.Trim()
    if (-not $value) { throw 'URL을 입력하세요.' }
    if ($value -notmatch '^[a-zA-Z][a-zA-Z0-9+.-]*://') {
        $value = "https://$value"
    }

    $uri = $null
    if (-not [Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$uri)) {
        throw '올바른 URL이 아닙니다.'
    }
    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
        throw 'http 또는 https URL만 지원합니다.'
    }
    if (-not $uri.Host) { throw '호스트가 없는 URL입니다.' }

    return $uri.AbsoluteUri
}

function Set-TargetState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Url,
        [bool]$ForceInitialMeasure = $false
    )

    if (Get-Command Resolve-MeasurementTarget -ErrorAction SilentlyContinue) {
        $measurementTarget = Resolve-MeasurementTarget -Url $Url
    } else {
        $measurementTarget = [PSCustomObject]@{
            TargetUrl = $Url
            MeasurementUrl = $Url
            MeasurementNote = ''
        }
    }
    $uri = [Uri]$measurementTarget.TargetUrl
    $isSameMeasuredTarget = (-not $ForceInitialMeasure) -and $State.TargetUrl -and $State.TargetUrl -eq $measurementTarget.TargetUrl -and $State.LastMeasureAt

    $State.Host = $uri.Host
    $State.TargetUrl = $measurementTarget.TargetUrl
    $State.MeasurementUrl = $measurementTarget.MeasurementUrl
    $State.MeasurementNote = $measurementTarget.MeasurementNote
    $State.PendingTargetChange = -not $isSameMeasuredTarget
    $State.LastMeasureRequestedAt = Get-PcUtcNow
    $State.LastRemeasureFinishedAt = $null
    $State.LastRemeasureResult = ''
    $State.LastRemeasureDeltaMs = $null
    $State.LastRemeasureAttempts = 0

    if (-not $isSameMeasuredTarget) {
        $State.LastMeasureAt = $null
        $State.RttMedianMs = 0.0
        $State.SigmaMs = 0.0
        $State.Ci95Ms = 0.0
        $State.LastError = ''
    }

    $State.MeasureInProgress = $false
    $State.Status = 'queued'
}

function Set-TargetFromRequest {
    param($req, $resp, $state)

    try {
        $reader = New-Object IO.StreamReader($req.InputStream, $req.ContentEncoding)
        $body = $reader.ReadToEnd()
        $payload = if ($body) { $body | ConvertFrom-Json } else { $null }
        $url = Normalize-TargetUrl -Url ([string]$payload.url)
        Set-TargetState -State $state -Url $url -ForceInitialMeasure $true

        Write-LogEvent @{ ev = 'target_changed'; host = $state.Host; url = $state.TargetUrl; measurementUrl = $state.MeasurementUrl; measurementNote = $state.MeasurementNote }
        Restart-MeasureTimer $state.MeasureTimer
        Write-JsonResponse $resp @{ ok = $true; host = $state.Host; targetUrl = $state.TargetUrl; measurementUrl = $state.MeasurementUrl; measurementNote = $state.MeasurementNote }
    } catch {
        $resp.StatusCode = 400
        Write-JsonResponse $resp @{ ok = $false; error = "$_" }
    }
}

function Write-StaticFile {
    param($resp, [string]$path, [string]$contentType)
    if (-not (Test-Path $path)) {
        $resp.StatusCode = 404
        return
    }
    $bytes = [IO.File]::ReadAllBytes($path)
    $resp.ContentType = $contentType
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-StateJson {
    param($resp, $state)
    # Stale 판정 (직렬화 직전)
    if ($state.LastMeasureAt -and $state.Status -ne 'measuring' -and $state.Status -ne 'queued') {
        $ageMin = ((Get-PcUtcNow) - $state.LastMeasureAt).TotalMinutes
        if ($ageMin -gt 5) { $state.Status = 'stale' }
    }
    $pcSendTimeAtMs = ConvertTo-UnixMs -Utc (Get-PcUtcNow)

    $payload = @{
        host           = $state.Host
        targetUrl      = $state.TargetUrl
        measurementUrl = $state.MeasurementUrl
        measurementNote = $state.MeasurementNote
        offsetMs       = $state.OffsetMs
        lastMeasureAt  = if ($state.LastMeasureAt) { $state.LastMeasureAt.ToString('o') } else { $null }
        lastMeasureRequestedAt = if ($state.LastMeasureRequestedAt) { $state.LastMeasureRequestedAt.ToString('o') } else { $null }
        lastRemeasureFinishedAt = if ($state.LastRemeasureFinishedAt) { $state.LastRemeasureFinishedAt.ToString('o') } else { $null }
        lastRemeasureResult = $state.LastRemeasureResult
        lastRemeasureDeltaMs = $state.LastRemeasureDeltaMs
        lastRemeasureAttempts = $state.LastRemeasureAttempts
        lastMeasureMode = $state.LastMeasureMode
        lastError      = $state.LastError
        rttMedianMs    = $state.RttMedianMs
        sigmaMs        = $state.SigmaMs
        ci95Ms         = $state.Ci95Ms
        sampleCount    = $state.SampleCount
        acceptedCount  = $state.AcceptedCount
        edgeCount      = @($state.LastEdges).Count
        method         = $state.Method
        intersectWidthMs = $state.IntersectWidthMs
        measurementWallElapsedMs = $state.MeasurementWallElapsedMs
        attemptedProbeCount = $state.AttemptedProbeCount
        failedProbeCount = $state.FailedProbeCount
        stopReason = $state.StopReason
        adaptiveTimeoutMs = $state.AdaptiveTimeoutMs
        defaultTimeoutMs = $state.DefaultTimeoutMs
        probeMode = $state.ProbeMode
        status         = $state.Status
        pcSendTimeAtMs = $pcSendTimeAtMs
        ntpInfo        = $state.NtpInfo
    }
    Write-JsonResponse $resp $payload
}

function Write-SamplesJson {
    param($resp, $state)
    $payload = @{
        host          = $state.Host
        targetUrl     = $state.TargetUrl
        measurementUrl = $state.MeasurementUrl
        measurementNote = $state.MeasurementNote
        lastMeasureAt = if ($state.LastMeasureAt) { $state.LastMeasureAt.ToString('o') } else { $null }
        method        = $state.Method
        offsetMs      = $state.OffsetMs
        rttMedianMs   = $state.RttMedianMs
        sigmaMs       = $state.SigmaMs
        ci95Ms        = $state.Ci95Ms
        sampleCount   = $state.SampleCount
        acceptedCount = $state.AcceptedCount
        intersectWidthMs = $state.IntersectWidthMs
        measurementWallElapsedMs = $state.MeasurementWallElapsedMs
        attemptedProbeCount = $state.AttemptedProbeCount
        failedProbeCount = $state.FailedProbeCount
        stopReason = $state.StopReason
        adaptiveTimeoutMs = $state.AdaptiveTimeoutMs
        defaultTimeoutMs = $state.DefaultTimeoutMs
        probeMode = $state.ProbeMode
        samples       = @($state.LastSamples)
        edges         = @($state.LastEdges)
    }
    Write-JsonResponse $resp $payload
}

function Write-JsonResponse {
    param($resp, $payload)

    $json = $payload | ConvertTo-Json -Depth 5 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $resp.ContentType = 'application/json; charset=utf-8'
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Stop-LocalHttpServer {
    param($listener)
    if ($listener -and $listener.IsListening) {
        try { $listener.Stop() } catch {}
        try { $listener.Close() } catch {}
    }
}
