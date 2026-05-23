# measurement.ps1 - 측정 알고리즘 (§4)
. "$PSScriptRoot\anchor.ps1"

$script:ProbeUserAgent = 'ServerTimeProbe/1.0 (personal-use)'
$script:NaverPassportKey = $null
$script:NaverBrowserUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'

function Get-NaverPassportKey {
    # 네이버 검색 페이지의 시계 위젯에 박혀 내려오는 passportKey를 추출.
    # 키는 주기적으로 만료되므로 측정 실패 시 다시 호출해서 갱신해야 함.
    $ProgressPreference = 'SilentlyContinue'
    $resp = Invoke-WebRequest `
        -Uri 'https://search.naver.com/search.naver?query=%EC%8B%9C%EA%B0%84' `
        -TimeoutSec 5 -UseBasicParsing -UserAgent $script:NaverBrowserUserAgent
    if ($resp.Content -match 'passportKey=([0-9a-f]{40})') {
        return $Matches[1]
    }
    throw "Naver passportKey not found in search page"
}

function ConvertTo-DateMs {
    param([Parameter(Mandatory)][string]$DateHeader)
    $dt = [DateTime]::ParseExact(
        $DateHeader,
        'ddd, dd MMM yyyy HH:mm:ss \G\M\T',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
            [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )
    return ConvertTo-UnixMs -Utc $dt
}

function ConvertTo-NaverTimeMs {
    param([Parameter(Mandatory)][string]$NaverTime)
    if ($NaverTime -notmatch '^(\d{4})/(\d{2})/(\d{2})/(\d{2})/(\d{2})/(\d{2})/(\d{3})$') {
        throw "Invalid Naver time value: $NaverTime"
    }

    $kst = [DateTime]::new(
        [int]$Matches[1],
        [int]$Matches[2],
        [int]$Matches[3],
        [int]$Matches[4],
        [int]$Matches[5],
        [int]$Matches[6],
        [int]$Matches[7],
        [DateTimeKind]::Unspecified
    )
    $utc = [DateTime]::SpecifyKind($kst.AddHours(-9), [DateTimeKind]::Utc)
    return ConvertTo-UnixMs -Utc $utc
}

function Test-NaverClockUrl {
    param([Parameter(Mandatory)][string]$Url)
    try {
        $u = [Uri]$Url
        return $u.Host -eq 'naver.com'
    } catch {
        return $false
    }
}

function Get-OffsetMs {
    param(
        [Parameter(Mandatory)][double]$ServerDateMs,
        [Parameter(Mandatory)][double]$RttMs,
        [Parameter(Mandatory)][double]$PcAtT2Ms
    )
    return ($ServerDateMs + $RttMs / 2) - $PcAtT2Ms
}

function Invoke-RangeGetDateProbe {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 5
    )

    $request = [System.Net.HttpWebRequest]::CreateHttp($Url)
    $request.Method = 'GET'
    $request.UserAgent = $script:ProbeUserAgent
    $request.Timeout = $TimeoutSec * 1000
    $request.ReadWriteTimeout = $TimeoutSec * 1000
    $request.AllowAutoRedirect = $true
    $request.AddRange(0, 0)

    $response = $null
    try {
        $response = [System.Net.HttpWebResponse]$request.GetResponse()
        return [PSCustomObject]@{
            Headers = @{
                Date = $response.Headers['Date']
            }
        }
    } finally {
        if ($response) { $response.Dispose() }
    }
}

function Invoke-HeadProbe {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 5
    )
    $ProgressPreference = 'SilentlyContinue'
    $t1 = [System.Diagnostics.Stopwatch]::GetTimestamp()
    try {
        $resp = Invoke-WebRequest `
            -Uri $Url `
            -Method Head `
            -TimeoutSec $TimeoutSec `
            -UseBasicParsing `
            -UserAgent $script:ProbeUserAgent
    } catch {
        try {
            $t1 = [System.Diagnostics.Stopwatch]::GetTimestamp()
            $resp = Invoke-RangeGetDateProbe -Url $Url -TimeoutSec $TimeoutSec
        } catch {
            throw "HTTP date probe failed: $_"
        }
    }
    $t2 = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $pcAtT2 = Get-PcUtcNow

    $dateHdr = $resp.Headers.Date
    if (-not $dateHdr) { throw 'Date header missing' }
    # Headers.Date is returned as String[], take the first element
    if ($dateHdr -is [array]) { $dateHdr = $dateHdr[0] }

    $rttMs = Get-StopwatchElapsedMs -StartTicks $t1 -EndTicks $t2
    $serverDateMs = ConvertTo-DateMs $dateHdr
    $pcAtT2Ms = ConvertTo-UnixMs -Utc $pcAtT2
    $rawOffsetMs = Get-OffsetMs -ServerDateMs $serverDateMs -RttMs $rttMs -PcAtT2Ms $pcAtT2Ms

    return [PSCustomObject]@{
        RttMs            = $rttMs
        RawOffsetMs      = $rawOffsetMs
        OffsetMs         = $rawOffsetMs
        ServerDateMs     = $serverDateMs
        PcAtT2Ms         = $pcAtT2Ms
        DateHdr          = $dateHdr
    }
}

function Invoke-NaverTimeProbe {
    param([int]$TimeoutSec = 5)
    $ProgressPreference = 'SilentlyContinue'

    if (-not $script:NaverPassportKey) {
        $script:NaverPassportKey = Get-NaverPassportKey
    }
    $apiUrl = "https://ts-proxy.naver.com/dcontent/util/time.naver?passportKey=$($script:NaverPassportKey)&_format=yyyy/MM/dd/HH/mm/ss/SSS&site=naver"

    $t1 = [System.Diagnostics.Stopwatch]::GetTimestamp()
    try {
        $resp = Invoke-WebRequest `
            -Uri $apiUrl `
            -TimeoutSec $TimeoutSec `
            -UseBasicParsing `
            -UserAgent $script:ProbeUserAgent
    } catch {
        throw "Naver time API failed: $_"
    }
    $t2 = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $pcAtT2 = Get-PcUtcNow

    $body = [string]$resp.Content
    if ($body -match 'Fail to get correct key') {
        # 키 만료. 캐시 무효화 후 재발급. 즉시 throw해서 상위 루프가 다음 시도에 새 키 사용.
        $script:NaverPassportKey = $null
        throw "Naver passportKey expired"
    }
    if ($body -notmatch '"(\d{4}/\d{2}/\d{2}/\d{2}/\d{2}/\d{2}/\d{3})"') {
        throw "Naver time API returned unexpected response: $body"
    }
    $naverTime = $Matches[1]

    $rttMs = Get-StopwatchElapsedMs -StartTicks $t1 -EndTicks $t2
    $serverTimeMs = ConvertTo-NaverTimeMs $naverTime
    $pcAtT2Ms = ConvertTo-UnixMs -Utc $pcAtT2
    $offsetMs = Get-OffsetMs -ServerDateMs $serverTimeMs -RttMs $rttMs -PcAtT2Ms $pcAtT2Ms

    return [PSCustomObject]@{
        RttMs        = $rttMs
        RawOffsetMs  = $offsetMs
        OffsetMs     = $offsetMs
        ServerDateMs = $serverTimeMs
        PcAtT2Ms     = $pcAtT2Ms
        DateHdr      = $naverTime
    }
}

function Get-Median {
    param([Parameter(Mandatory)][double[]]$Values)
    $sorted = $Values | Sort-Object
    $n = $sorted.Count
    if ($n -eq 0) { throw 'Empty array' }
    if ($n % 2 -eq 1) { return [double]$sorted[[int]($n/2)] }
    return ([double]$sorted[$n/2 - 1] + [double]$sorted[$n/2]) / 2.0
}

function Get-StdDev {
    param([Parameter(Mandatory)][double[]]$Values)
    $n = $Values.Count
    if ($n -lt 2) { return 0.0 }
    $mean = ($Values | Measure-Object -Average).Average
    $sumSq = 0.0
    foreach ($v in $Values) { $sumSq += [Math]::Pow($v - $mean, 2) }
    return [Math]::Sqrt($sumSq / ($n - 1))   # Bessel
}

function Get-Ci95Ms {
    param([Parameter(Mandatory)][double[]]$Values)
    $n = $Values.Count
    if ($n -lt 2) { return 0.0 }
    $sigma = Get-StdDev -Values $Values
    # t분포 df=n-1, 95% 양측. n=10 -> 2.262
    $tValue = if ($n -ge 30) { 1.96 } elseif ($n -ge 10) { 2.262 } elseif ($n -ge 5) { 2.776 } else { 4.303 }
    return $tValue * $sigma / [Math]::Sqrt($n)
}

function Select-LowJitterSamples {
    param(
        [Parameter(Mandatory)]$Samples,
        [int]$MinCount = 3
    )
    $rtts = $Samples | ForEach-Object { [double]$_.RttMs }
    $rttMedian = Get-Median -Values $rtts
    $lowJitter = $Samples | Where-Object { [double]$_.RttMs -le ($rttMedian * 1.5 + 2) }
    if ($lowJitter.Count -lt $MinCount) { $lowJitter = $Samples }
    return [PSCustomObject]@{
        Samples     = $lowJitter
        RttMedianMs = $rttMedian
    }
}

function Reduce-PreciseSamples {
    param(
        [Parameter(Mandatory)]$Samples,
        [string]$Method = 'precise'
    )
    $filtered = Select-LowJitterSamples -Samples $Samples -MinCount 3
    $offsets = $filtered.Samples | ForEach-Object { [double]$_.OffsetMs }
    $median = Get-Median -Values $offsets
    $sigma = Get-StdDev -Values $offsets
    $ci95 = Get-Ci95Ms -Values $offsets

    return [PSCustomObject]@{
        OffsetMs       = $median
        SigmaMs        = $sigma
        Ci95Ms         = $ci95
        RttMedianMs    = $filtered.RttMedianMs
        SampleCount    = $Samples.Count
        AcceptedCount  = $offsets.Count
        Method         = $Method
        Samples        = (ConvertTo-SampleSummaries -Samples $Samples)
        Edges          = @()
    }
}

function Select-QuantizedOffsetCandidates {
    param([Parameter(Mandatory)]$Samples)

    $filtered = Select-LowJitterSamples -Samples $Samples -MinCount 5
    $rawOffsets = $filtered.Samples | ForEach-Object { [double]$_.RawOffsetMs }

    $candidateCount = [Math]::Max(3, [Math]::Floor($rawOffsets.Count * 0.08))
    return $rawOffsets | Sort-Object -Descending | Select-Object -First $candidateCount
}

function Select-EdgeOffsetCandidates {
    param([Parameter(Mandatory)]$Samples)
    return (Get-EdgeDetails -Samples $Samples) | ForEach-Object { $_.OffsetMs }
}

function Get-EdgeDetails {
    # GUI 시각화용. 각 edge가 어떤 샘플 쌍 사이에서 검출됐는지 인덱스까지 반환.
    param(
        [Parameter(Mandatory)]$Samples,
        [int]$IntervalMs = 50
    )

    $ordered = @($Samples)
    $edges = New-Object System.Collections.ArrayList

    # RTT 필터: 양 끝 샘플 중 한쪽이라도 RTT median * 1.5 + 2 ms를 넘으면
    # 해당 edge offset의 σ가 폭주하므로 채택 안 함. Select-LowJitterSamples와 동일 기준.
    $rtts = $ordered | ForEach-Object { [double]$_.RttMs }
    if ($rtts.Count -eq 0) { return $edges }
    $rttMedian = Get-Median -Values $rtts
    $rttThreshold = $rttMedian * 1.5 + 2

    # Gap 필터: 실패한 샘플이 사이에 끼어 wall-clock 간격이 크게 벌어진 경우.
    # 양 끝 RTT가 멀쩡해도 server-event PC 간격이 길면 σ_edge가 폭주.
    # GUI 핑크 갭 표시 기준(expectedGap × 3)과 동일.
    $expectedGapMs = $rttMedian + $IntervalMs
    $serverEventGapMaxMs = $expectedGapMs * 3

    for ($i = 1; $i -lt $ordered.Count; $i++) {
        $prev = $ordered[$i - 1]
        $curr = $ordered[$i]
        if ($null -eq $prev.ServerDateMs -or $null -eq $curr.ServerDateMs) { continue }
        if ([double]$prev.RttMs -gt $rttThreshold -or [double]$curr.RttMs -gt $rttThreshold) { continue }

        $dateStepMs = [double]$curr.ServerDateMs - [double]$prev.ServerDateMs
        if ($dateStepMs -lt 900 -or $dateStepMs -gt 1100) { continue }

        $prevServerEventPcMs = [double]$prev.PcAtT2Ms - ([double]$prev.RttMs / 2)
        $currServerEventPcMs = [double]$curr.PcAtT2Ms - ([double]$curr.RttMs / 2)
        if ($currServerEventPcMs -le $prevServerEventPcMs) { continue }
        if (($currServerEventPcMs - $prevServerEventPcMs) -gt $serverEventGapMaxMs) { continue }

        $edgePcMs = ($prevServerEventPcMs + $currServerEventPcMs) / 2.0
        $edgeOffsetMs = [double]$curr.ServerDateMs - $edgePcMs
        [void]$edges.Add([PSCustomObject]@{
            PrevIdx  = $i - 1
            CurrIdx  = $i
            EdgePcMs = $edgePcMs
            OffsetMs = $edgeOffsetMs
        })
    }

    return $edges
}

function ConvertTo-SampleSummaries {
    param([Parameter(Mandatory)]$Samples)
    return @($Samples | ForEach-Object {
        [PSCustomObject]@{
            pcAtT2Ms     = [double]$_.PcAtT2Ms
            rttMs        = [double]$_.RttMs
            serverDateMs = [double]$_.ServerDateMs
        }
    })
}

function ConvertTo-EdgeSummaries {
    param($Edges)
    return @($Edges | ForEach-Object {
        [PSCustomObject]@{
            prevIdx  = [int]$_.PrevIdx
            currIdx  = [int]$_.CurrIdx
            edgePcMs = [double]$_.EdgePcMs
            offsetMs = [double]$_.OffsetMs
        }
    })
}

function Reduce-Samples {
    param([Parameter(Mandatory)]$Samples)
    # Prefer real Date-header edge detection: when Date jumps N -> N+1, the
    # server second boundary lies between those two server-event estimates.
    $edgeDetails = Get-EdgeDetails -Samples $Samples
    $method = 'edge'
    if ($edgeDetails.Count -eq 0) {
        # Fallback for pathological/cached Date behavior where no transition is
        # visible in the sample window.
        $candidates = Select-QuantizedOffsetCandidates -Samples $Samples
        $method = 'upper-envelope'
    } else {
        $candidates = @($edgeDetails | ForEach-Object { [double]$_.OffsetMs })
    }
    $median = Get-Median -Values $candidates
    $sigma  = Get-StdDev -Values $candidates
    $ci95   = Get-Ci95Ms -Values $candidates
    $rttMedian = Get-Median -Values ($Samples | ForEach-Object { [double]$_.RttMs })

    return [PSCustomObject]@{
        OffsetMs       = $median
        SigmaMs        = $sigma
        Ci95Ms         = $ci95
        RttMedianMs    = $rttMedian
        SampleCount    = $Samples.Count
        AcceptedCount  = $candidates.Count
        Method         = $method
        Samples        = (ConvertTo-SampleSummaries -Samples $Samples)
        Edges          = (ConvertTo-EdgeSummaries -Edges $edgeDetails)
    }
}

function Invoke-MultiSample {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$Count = 50,
        [int]$IntervalMs = 100
    )
    $samples = New-Object System.Collections.ArrayList
    $useNaverClockApi = Test-NaverClockUrl -Url $Url
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $s = if ($useNaverClockApi) { Invoke-NaverTimeProbe } else { Invoke-HeadProbe -Url $Url }
            [void]$samples.Add($s)
        } catch {
            # 개별 실패 허용. 50% 이상 실패 시 상위 함수에서 throw
        }
        if ($i -lt $Count - 1) { Start-Sleep -Milliseconds $IntervalMs }
    }
    if ($samples.Count -lt [int]($Count * 0.5)) {
        throw "Too many failed samples: $($samples.Count)/$Count"
    }
    if ($useNaverClockApi) {
        return Reduce-PreciseSamples -Samples $samples -Method 'naver-time-api'
    }
    return Reduce-Samples -Samples $samples
}

function Invoke-AdaptiveMultiSample {
    # RTT를 먼저 추정한 뒤 약 TargetWindowMs(기본 6000ms) 동안 샘플링되도록
    # Count를 동적으로 정한다. Edge detection은 윈도우 길이(=기대 edge 수)가
    # 결정하고, edge 1개당 표준편차는 (R+I)/sqrt(12)이므로 I는 작을수록 유리.
    # 자세한 근거는 docs/성능분석.md의 "샘플링 파라미터 최적화" 절 참고.
    #
    # 두 가지 적응형 안전장치:
    #   (1) RTT 추정 직후 per-sample timeout을 RTT 기반으로 단축. hang 1회가
    #       측정 윈도우를 통째로 먹는 문제 차단.
    #   (2) 메인 윈도우 종료 시 edge 수가 MinEdgeCount 미만이면 ExtendWindowMs
    #       만큼 추가 샘플링. 통계 신뢰도 확보.
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$IntervalMs = 50,
        [int]$TargetWindowMs = 6000,
        [int]$MinCount = 10,
        [int]$MaxCount = 60,
        [int]$RttProbeCount = 3,
        [int]$MinEdgeCount = 8,
        [int]$ExtendWindowMs = 3000,
        [int]$MaxExtensions = 3,
        [int]$DefaultTimeoutSec = 5
    )
    $samples = New-Object System.Collections.ArrayList
    $useNaverClockApi = Test-NaverClockUrl -Url $Url

    # RTT 추정 단계: timeout 알 수 없으니 기본값 사용
    for ($i = 0; $i -lt $RttProbeCount; $i++) {
        try {
            $s = if ($useNaverClockApi) { Invoke-NaverTimeProbe -TimeoutSec $DefaultTimeoutSec } else { Invoke-HeadProbe -Url $Url -TimeoutSec $DefaultTimeoutSec }
            [void]$samples.Add($s)
        } catch { }
        Start-Sleep -Milliseconds $IntervalMs
    }
    if ($samples.Count -eq 0) {
        throw "All initial RTT probes failed"
    }

    $rtts = $samples | ForEach-Object { [double]$_.RttMs }
    $rttMedian = Get-Median -Values $rtts
    $estimated = [int][Math]::Ceiling($TargetWindowMs / ($rttMedian + $IntervalMs))
    $count = [Math]::Max($MinCount, [Math]::Min($MaxCount, $estimated))

    # 적응형 timeout: max(1초, ceil(5×RTT)). RTT 91ms → 1초. RTT 500ms → 3초. RTT 1000ms+ → 5초.
    # Invoke-WebRequest TimeoutSec는 정수 초만 지원해서 ms 단위로는 못 내려감.
    $adaptiveTimeoutSec = [int][Math]::Max(1, [Math]::Ceiling(5 * $rttMedian / 1000))
    if ($adaptiveTimeoutSec -gt $DefaultTimeoutSec) { $adaptiveTimeoutSec = $DefaultTimeoutSec }

    for ($i = $samples.Count; $i -lt $count; $i++) {
        try {
            $s = if ($useNaverClockApi) { Invoke-NaverTimeProbe -TimeoutSec $adaptiveTimeoutSec } else { Invoke-HeadProbe -Url $Url -TimeoutSec $adaptiveTimeoutSec }
            [void]$samples.Add($s)
        } catch { }
        if ($i -lt $count - 1) { Start-Sleep -Milliseconds $IntervalMs }
    }

    if ($samples.Count -lt [int]($count * 0.5)) {
        throw "Too many failed samples: $($samples.Count)/$count"
    }
    if ($useNaverClockApi) {
        return Reduce-PreciseSamples -Samples $samples -Method 'naver-time-api'
    }

    # Edge가 부족하면 윈도우 연장. 최대 MaxExtensions회 반복.
    # 매 회 ExtendWindowMs만큼 추가 샘플링 후 재집계. AcceptedCount가 MinEdgeCount 도달
    # 또는 method가 edge에서 벗어나면 종료.
    $tentative = Reduce-Samples -Samples $samples
    for ($round = 0; $round -lt $MaxExtensions; $round++) {
        if ($tentative.Method -ne 'edge') { break }
        if ($tentative.AcceptedCount -ge $MinEdgeCount) { break }
        if ($ExtendWindowMs -le 0) { break }

        $extendCount = [int][Math]::Ceiling($ExtendWindowMs / ($rttMedian + $IntervalMs))
        $extendTarget = $samples.Count + $extendCount
        for ($i = $samples.Count; $i -lt $extendTarget; $i++) {
            try {
                $s = Invoke-HeadProbe -Url $Url -TimeoutSec $adaptiveTimeoutSec
                [void]$samples.Add($s)
            } catch { }
            if ($i -lt $extendTarget - 1) { Start-Sleep -Milliseconds $IntervalMs }
        }
        $tentative = Reduce-Samples -Samples $samples
    }
    return $tentative
}
