# http-server.ps1 - 127.0.0.1 전용 HttpListener
. "$PSScriptRoot\anchor.ps1"
. "$PSScriptRoot\logger.ps1"

function New-StateStore {
    return [hashtable]::Synchronized(@{
        Host          = ''
        TargetUrl     = ''
        PendingTargetChange = $false
        OffsetMs      = 0.0
        LastMeasureAt = $null
        LastMeasureRequestedAt = $null
        LastRemeasureFinishedAt = $null
        LastRemeasureResult = ''
        LastRemeasureDeltaMs = $null
        LastRemeasureAttempts = 0
        MeasureInProgress = $false
        PageServed    = $false
        RttMedianMs   = 0.0
        SigmaMs       = 0.0
        Ci95Ms        = 0.0
        SampleCount   = 0
        AcceptedCount = 0
        Method        = ''
        IntersectWidthMs = 0.0
        LastSamples   = @()
        LastEdges     = @()
        Status        = 'idle'
        NtpInfo       = $null
    })
}

function Start-LocalHttpServer {
    param(
        [Parameter(Mandatory)]$State,
        [int]$PreferPort = 8765,
        [Parameter(Mandatory)][string]$WebRoot
    )
    # 포트 충돌 시 +1씩 시도 (최대 10)
    $listener = $null
    $port = $PreferPort
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://127.0.0.1:$port/")
            $listener.Start()
            break
        } catch {
            $listener = $null
            $port++
        }
    }
    if ($null -eq $listener) { throw "Failed to bind any port in $PreferPort..$($PreferPort+9)" }

    Write-Host "HTTP 서버: http://127.0.0.1:$port/" -ForegroundColor Cyan

    return @{
        Listener = $listener
        Port     = $port
        Loop     = {
            param($listener, $state, $webRoot)
            while ($listener.IsListening) {
                try {
                    $ctx = $listener.GetContext()
                    $req = $ctx.Request
                    $resp = $ctx.Response
                    $resp.Headers.Add('Cache-Control', 'no-store')
                    Handle-Request $req $resp $state $webRoot
                    $resp.Close()
                } catch [System.Net.HttpListenerException] {
                    break
                } catch {
                    # 개별 요청 실패 무시
                }
            }
        }
    }
}

function Handle-Request {
    param($req, $resp, $state, $webRoot)
    $path = $req.Url.AbsolutePath
    if ($path -eq '/' -or $path -eq '/index.html') {
        if (-not $state.PageServed) {
            $state.PageServed = $true
        } elseif ($state.TargetUrl -and $state.MeasureTimer -and -not $state.MeasureInProgress -and -not $state.MeasureTimer.Enabled) {
            $state.LastMeasureRequestedAt = Get-PcUtcNow
            $state.LastRemeasureResult = ''
            $state.LastRemeasureDeltaMs = $null
            $state.LastRemeasureAttempts = 0
            $state.MeasureInProgress = $true
            $state.Status = 'measuring'
            Write-LogEvent @{ ev = 'remeasure_requested'; path = $path }
            $state.MeasureTimer.Start()
        }
        Write-StaticFile $resp (Join-Path $webRoot 'index.html') 'text/html; charset=utf-8'
    } elseif ($path -eq '/clock.css') {
        Write-StaticFile $resp (Join-Path $webRoot 'clock.css') 'text/css; charset=utf-8'
    } elseif ($path -eq '/clock.js') {
        Write-StaticFile $resp (Join-Path $webRoot 'clock.js') 'application/javascript; charset=utf-8'
    } elseif ($path -eq '/api/state') {
        Write-StateJson $resp $state
    } elseif ($path -eq '/api/samples') {
        Write-SamplesJson $resp $state
    } elseif ($path -eq '/api/target') {
        if ($req.HttpMethod -ne 'POST') {
            $resp.StatusCode = 405
            Write-JsonResponse $resp @{ ok = $false; error = 'Method Not Allowed' }
            return
        }
        Set-TargetFromRequest $req $resp $state
    } else {
        $resp.StatusCode = 404
        $bytes = [Text.Encoding]::UTF8.GetBytes('Not Found')
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    }
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

    $uri = [Uri]$Url
    $isSameMeasuredTarget = (-not $ForceInitialMeasure) -and $State.TargetUrl -and $State.TargetUrl -eq $Url -and $State.LastMeasureAt

    $State.Host = $uri.Host
    $State.TargetUrl = $Url
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

        Write-LogEvent @{ ev = 'target_changed'; host = $state.Host; url = $state.TargetUrl }
        if ($state.MeasureTimer) { $state.MeasureTimer.Start() }
        Write-JsonResponse $resp @{ ok = $true; host = $state.Host; targetUrl = $state.TargetUrl }
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
        offsetMs       = $state.OffsetMs
        lastMeasureAt  = if ($state.LastMeasureAt) { $state.LastMeasureAt.ToString('o') } else { $null }
        lastMeasureRequestedAt = if ($state.LastMeasureRequestedAt) { $state.LastMeasureRequestedAt.ToString('o') } else { $null }
        lastRemeasureFinishedAt = if ($state.LastRemeasureFinishedAt) { $state.LastRemeasureFinishedAt.ToString('o') } else { $null }
        lastRemeasureResult = $state.LastRemeasureResult
        lastRemeasureDeltaMs = $state.LastRemeasureDeltaMs
        lastRemeasureAttempts = $state.LastRemeasureAttempts
        rttMedianMs    = $state.RttMedianMs
        sigmaMs        = $state.SigmaMs
        ci95Ms         = $state.Ci95Ms
        sampleCount    = $state.SampleCount
        acceptedCount  = $state.AcceptedCount
        edgeCount      = @($state.LastEdges).Count
        method         = $state.Method
        intersectWidthMs = $state.IntersectWidthMs
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
        lastMeasureAt = if ($state.LastMeasureAt) { $state.LastMeasureAt.ToString('o') } else { $null }
        method        = $state.Method
        offsetMs      = $state.OffsetMs
        rttMedianMs   = $state.RttMedianMs
        sigmaMs       = $state.SigmaMs
        ci95Ms        = $state.Ci95Ms
        sampleCount   = $state.SampleCount
        acceptedCount = $state.AcceptedCount
        intersectWidthMs = $state.IntersectWidthMs
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
