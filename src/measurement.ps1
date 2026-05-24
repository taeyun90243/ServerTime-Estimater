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

function Get-EffectiveServerDateMs {
    # Date + Age 산술 헬퍼. **주의**: 이 결합은 raw Date가 'frozen'(정지)일 때만 옳다.
    # frozen Date 캐시(예: CloudFront)는 Date를 적재 시각에 고정하고 경과를 Age(초,
    # RFC 9111)로 노출하므로 Date+Age = 현재 시각. 그러나 Date가 라이브(매초 증가)인데
    # Age도 0이 아니면 Date+Age는 정수 초만큼 미래로 과보정된다. 따라서 호출은
    # Set-AgeCorrectedServerDates의 frozen 판정 뒤에만 해야 한다. (이 함수 자체는
    # 무조건 더하기만 하므로 단독 사용 금지.)
    param(
        [Parameter(Mandatory)][string]$DateHeader,
        [string]$AgeHeader
    )
    $dateMs = ConvertTo-DateMs $DateHeader
    $ageSec = 0
    if ($AgeHeader -and ($AgeHeader -match '^\s*(\d+)\s*$')) { $ageSec = [int]$Matches[1] }
    return $dateMs + ($ageSec * 1000)
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

function Resolve-MeasurementTarget {
    param([Parameter(Mandatory)][string]$Url)

    $uri = [Uri]$Url
    $targetHost = $uri.Host.ToLowerInvariant()
    if ($targetHost -in @('ticket.interpark.com', 'tickets.interpark.com', 'nol.interpark.com')) {
        $cacheBust = [Guid]::NewGuid().ToString('N').Substring(0, 10)
        $canonicalUrl = 'https://nol.interpark.com/ticket'
        return [PSCustomObject]@{
            TargetUrl       = $canonicalUrl
            MeasurementUrl  = "${canonicalUrl}?t=$cacheBust"
            MeasurementNote = 'interpark-final-ticket-page'
        }
    }

    return [PSCustomObject]@{
        TargetUrl       = $Url
        MeasurementUrl  = $Url
        MeasurementNote = ''
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
                Age  = $response.Headers['Age']
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

    # Age 헤더는 따로 들고만 간다. 기본 ServerDateMs는 raw Date(안전).
    # Age 보정은 윈도우 전체를 보고 'Date가 정지(frozen)'로 판정될 때만
    # Reduce-Samples(=Set-AgeCorrectedServerDates)에서 적용한다. 라이브 Date에
    # Age를 더하면 정수 초만큼 미래로 과보정되기 때문(ticket.interpark.com 회귀).
    $ageHdr = $resp.Headers.Age
    if ($ageHdr -is [array]) { $ageHdr = $ageHdr[0] }
    $ageSec = 0
    if ($ageHdr -and ($ageHdr -match '^\s*(\d+)\s*$')) { $ageSec = [int]$Matches[1] }

    $rttMs = Get-StopwatchElapsedMs -StartTicks $t1 -EndTicks $t2
    $rawServerDateMs = ConvertTo-DateMs $dateHdr
    $serverDateMs = $rawServerDateMs
    $pcAtT2Ms = ConvertTo-UnixMs -Utc $pcAtT2
    $rawOffsetMs = Get-OffsetMs -ServerDateMs $serverDateMs -RttMs $rttMs -PcAtT2Ms $pcAtT2Ms

    return [PSCustomObject]@{
        RttMs            = $rttMs
        RawOffsetMs      = $rawOffsetMs
        OffsetMs         = $rawOffsetMs
        ServerDateMs     = $serverDateMs
        RawServerDateMs  = $rawServerDateMs
        AgeSec           = $ageSec
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
    # [int]($n/2)는 [int]1.5 -> 2 (은행가 반올림)라 홀수 n에서 가운데를 빗나간다.
    # floor로 정확히 가운데 인덱스를 구한다.
    $mid = [int][Math]::Floor($n / 2)
    if ($n % 2 -eq 1) { return [double]$sorted[$mid] }
    return ([double]$sorted[$mid - 1] + [double]$sorted[$mid]) / 2.0
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

function Get-RttThreshold {
    # RTT 필터 임계값. 이보다 큰 RTT 샘플/edge는 σ 폭주로 채택 제외.
    param([Parameter(Mandatory)][double]$RttMedianMs)
    return $RttMedianMs * 1.5 + 2
}

function Test-ShouldExtendWindow {
    # 윈도우 연장 여부: edge 계열(edge-intersect/-robust/-median)이고 edge가 부족할 때만.
    # upper-envelope(edge 미검출)는 더 샘플링해도 Date 전환이 안 보일 수 있어 연장 안 함.
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][int]$AcceptedCount,
        [Parameter(Mandatory)][int]$MinEdgeCount
    )
    return ($Method -like 'edge*') -and ($AcceptedCount -lt $MinEdgeCount)
}

function Get-RemeasureAttemptDecision {
    # 재측정 1회 결과 판정.
    #   - 타겟 변경(=새 URL의 첫 측정): edge 적어도 'accept'
    #   - 진짜 재측정: edge < MinAcceptedEdges면 'fail-insufficient' (적은 edge로 갱신 안 함)
    #   - edge 충분 + |delta| <= KeepExistingThresholdMs: 'keep-existing' (기존값 유지)
    #   - edge 충분 + |delta| <= DeltaThresholdMs: 'accept'
    #   - edge 충분 + |delta| 초과: 'delta-exceeded' (호출부가 재시도/거부 처리)
    param(
        [Parameter(Mandatory)][bool]$IsTargetChange,
        [Parameter(Mandatory)][int]$AcceptedCount,
        [Parameter(Mandatory)][double]$DeltaMs,
        [int]$MinAcceptedEdges = 5,
        [double]$KeepExistingThresholdMs = 30,
        [double]$DeltaThresholdMs = 100
    )
    if ($IsTargetChange) { return 'accept' }
    if ($AcceptedCount -lt $MinAcceptedEdges) { return 'fail-insufficient' }
    if ($DeltaMs -le $KeepExistingThresholdMs) { return 'keep-existing' }
    if ($DeltaMs -le $DeltaThresholdMs) { return 'accept' }
    return 'delta-exceeded'
}

function Select-LowJitterSamples {
    param(
        [Parameter(Mandatory)]$Samples,
        [int]$MinCount = 3
    )
    $rtts = $Samples | ForEach-Object { [double]$_.RttMs }
    $rttMedian = Get-Median -Values $rtts
    $lowJitter = $Samples | Where-Object { [double]$_.RttMs -le (Get-RttThreshold -RttMedianMs $rttMedian) }
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

function Get-EdgeDetails {
    # GUI 시각화용. 각 edge가 어떤 샘플 쌍 사이에서 검출됐는지 인덱스까지 반환.
    param(
        [Parameter(Mandatory)]$Samples,
        [int]$IntervalMs = 50
    )

    $ordered = @($Samples)
    $edges = New-Object System.Collections.ArrayList

    # RTT 필터: 양 끝 샘플 중 한쪽이라도 임계값을 넘으면 해당 edge offset의 σ가
    # 폭주하므로 채택 안 함. Select-LowJitterSamples와 동일 기준(Get-RttThreshold).
    $rtts = $ordered | ForEach-Object { [double]$_.RttMs }
    if ($rtts.Count -eq 0) { return $edges }
    $rttMedian = Get-Median -Values $rtts
    $rttThreshold = Get-RttThreshold -RttMedianMs $rttMedian

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
        # 1초 격자 제약을 위한 θ 구간: θ ∈ (S - R, S - L).
        # L = prev 서버이벤트 PC시각(작음), R = curr(큼) → Lower = S - R, Upper = S - L.
        # OffsetMs(중점) = (Lower + Upper)/2 로 방법1 추정과 일치.
        [void]$edges.Add([PSCustomObject]@{
            PrevIdx  = $i - 1
            CurrIdx  = $i
            EdgePcMs = $edgePcMs
            OffsetMs = $edgeOffsetMs
            LowerMs  = [double]$curr.ServerDateMs - $currServerEventPcMs
            UpperMs  = [double]$curr.ServerDateMs - $prevServerEventPcMs
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
            lowerMs  = [double]$_.LowerMs
            upperMs  = [double]$_.UpperMs
        }
    })
}

function Get-HybridOffsetEstimate {
    # 각 edge는 θ ∈ [LowerMs, UpperMs] 라는 제약. θ는 측정 내내 상수이므로
    # 모든 구간을 동시에 만족해야 함 = 교집합. 균등노이즈 가정에서 교집합
    # 중점이 MLE이고, edge 수 n에 대해 오차가 1/√n(중앙값)이 아니라 1/n로 줄어든다.
    #
    # 하이브리드(robustness):
    #   - 전체 교집합이 비지 않음 → 'edge-intersect' (모든 edge 일치)
    #   - 일부 outlier만 빼면 일치(최대 겹침 ≥ 2) → 'edge-intersect-robust'
    #   - 어떤 두 edge도 안 겹침(최대 겹침 = 1) → 'edge-median' (중점들의 median 폴백)
    param([Parameter(Mandatory)]$Edges)

    $arr = @($Edges)
    $n = $arr.Count
    if ($n -eq 0) { throw 'No edges' }

    $midpoints = @($arr | ForEach-Object { [double]$_.OffsetMs })
    if ($n -eq 1) {
        return [PSCustomObject]@{
            OffsetMs  = $midpoints[0]
            Method    = 'edge-intersect'
            UsedCount = 1
            WidthMs   = [double]$arr[0].UpperMs - [double]$arr[0].LowerMs
        }
    }

    # 최대 겹침 영역(interval stabbing). n이 작아(≤수십) O(n^2) 스윕으로 충분.
    # 동률이면 중점이 전체 중점 median에 가장 가까운 영역을 택해 robust하게.
    $medianMid = Get-Median -Values $midpoints
    $points = @()
    foreach ($e in $arr) { $points += [double]$e.LowerMs; $points += [double]$e.UpperMs }
    $points = @($points | Sort-Object -Unique)

    $bestCount = 0
    $bestLo = $null
    $bestHi = $null
    $bestDist = [double]::MaxValue
    for ($j = 0; $j -lt $points.Count - 1; $j++) {
        $mid = ($points[$j] + $points[$j + 1]) / 2.0
        $containing = @($arr | Where-Object {
            [double]$_.LowerMs -le $mid -and $mid -le [double]$_.UpperMs
        })
        $c = $containing.Count
        if ($c -eq 0) { continue }
        $candLo = ($containing | ForEach-Object { [double]$_.LowerMs } | Measure-Object -Maximum).Maximum
        $candHi = ($containing | ForEach-Object { [double]$_.UpperMs } | Measure-Object -Minimum).Minimum
        $candDist = [Math]::Abs((($candLo + $candHi) / 2.0) - $medianMid)
        if ($c -gt $bestCount -or ($c -eq $bestCount -and $candDist -lt $bestDist)) {
            $bestCount = $c
            $bestLo = $candLo
            $bestHi = $candHi
            $bestDist = $candDist
        }
    }

    if ($bestCount -le 1) {
        # 어떤 두 edge도 겹치지 않음 → 합의 불가. 중점들의 median으로 폴백.
        return [PSCustomObject]@{
            OffsetMs  = (Get-Median -Values $midpoints)
            Method    = 'edge-median'
            UsedCount = $n
            WidthMs   = 0.0
        }
    }

    $method = if ($bestCount -eq $n) { 'edge-intersect' } else { 'edge-intersect-robust' }
    return [PSCustomObject]@{
        OffsetMs  = ($bestLo + $bestHi) / 2.0
        Method    = $method
        UsedCount = $bestCount
        WidthMs   = $bestHi - $bestLo
    }
}

function Set-AgeCorrectedServerDates {
    # Age 보정을 '언제' 적용할지 윈도우 전체를 보고 결정한다.
    #
    #   - raw Date가 윈도우 내내 사실상 정지(span <= FrozenSpanMs)인데 Age>0가 있으면
    #     → CDN frozen-Date 캐시(예: CloudFront nol.interpark.com). Date는 멈췄고 Age가
    #       경과를 메우므로 ServerDateMs = Date + Age*1000 로 복구한다. (AgeCorrected=$true)
    #   - 그 외(= raw Date가 매초 살아 움직임) → raw Date가 이미 정답. Age가 0이 아니어도
    #     절대 더하지 않는다. 라이브 Date에 Age를 더하면 정수 초만큼 미래로 과보정되어
    #     "edge는 다 맞는데 N초 빠른" 위험한 표시가 된다(ticket.interpark.com 회귀).
    #
    # RawServerDateMs/AgeSec가 없는 샘플(네이버 경로·구형 단위테스트)은 건드리지 않는다.
    # 각 샘플의 ServerDateMs/OffsetMs/RawOffsetMs를 raw에서 다시 계산하므로 idempotent.
    param(
        [Parameter(Mandatory)]$Samples,
        [double]$FrozenSpanMs = 2000
    )
    $withRaw = @($Samples | Where-Object { $null -ne $_.RawServerDateMs })
    if ($withRaw.Count -eq 0) { return $false }

    $raws = @($withRaw | ForEach-Object { [double]$_.RawServerDateMs })
    $span = ($raws | Measure-Object -Maximum).Maximum - ($raws | Measure-Object -Minimum).Minimum
    $anyAge = @($withRaw | Where-Object { [int]$_.AgeSec -gt 0 }).Count -gt 0
    $frozen = ($span -le $FrozenSpanMs) -and $anyAge

    foreach ($s in $withRaw) {
        $eff = if ($frozen) { [double]$s.RawServerDateMs + ([int]$s.AgeSec) * 1000 } else { [double]$s.RawServerDateMs }
        $s.ServerDateMs = $eff
        $newOffset = Get-OffsetMs -ServerDateMs $eff -RttMs ([double]$s.RttMs) -PcAtT2Ms ([double]$s.PcAtT2Ms)
        $s.OffsetMs = $newOffset
        $s.RawOffsetMs = $newOffset
    }
    return $frozen
}

function Reduce-Samples {
    param([Parameter(Mandatory)]$Samples)
    # Age 보정 여부를 먼저 결정(frozen Date 캐시일 때만 Date+Age). 라이브 Date면 raw 유지.
    $ageCorrected = Set-AgeCorrectedServerDates -Samples $Samples

    # Prefer real Date-header edge detection: when Date jumps N -> N+1, the
    # server second boundary lies between those two server-event estimates.
    $edgeDetails = Get-EdgeDetails -Samples $Samples
    $rttMedian = Get-Median -Values ($Samples | ForEach-Object { [double]$_.RttMs })

    if ($edgeDetails.Count -eq 0) {
        # Fallback for pathological/cached Date behavior where no transition is
        # visible in the sample window.
        $candidates = Select-QuantizedOffsetCandidates -Samples $Samples
        return [PSCustomObject]@{
            OffsetMs       = (Get-Median -Values $candidates)
            SigmaMs        = (Get-StdDev -Values $candidates)
            Ci95Ms         = (Get-Ci95Ms -Values $candidates)
            RttMedianMs    = $rttMedian
            SampleCount    = $Samples.Count
            AcceptedCount  = $candidates.Count
            Method         = 'upper-envelope'
            AgeCorrected   = $ageCorrected
            Samples        = (ConvertTo-SampleSummaries -Samples $Samples)
            Edges          = @()
        }
    }

    # 1초 격자 제약을 활용한 교집합 추정(+모순 시 median 폴백).
    $hybrid = Get-HybridOffsetEstimate -Edges $edgeDetails
    $midpoints = @($edgeDetails | ForEach-Object { [double]$_.OffsetMs })
    $sigma = Get-StdDev -Values $midpoints
    # 교집합 계열은 feasible 영역의 반폭이 θ의 hard bound. median 폴백은 통계적 CI.
    $ci95 = if ($hybrid.Method -eq 'edge-median') {
        Get-Ci95Ms -Values $midpoints
    } else {
        $hybrid.WidthMs / 2.0
    }

    return [PSCustomObject]@{
        OffsetMs       = $hybrid.OffsetMs
        SigmaMs        = $sigma
        Ci95Ms         = $ci95
        RttMedianMs    = $rttMedian
        SampleCount    = $Samples.Count
        AcceptedCount  = $hybrid.UsedCount
        Method         = $hybrid.Method
        IntersectWidthMs = $hybrid.WidthMs
        AgeCorrected   = $ageCorrected
        Samples        = (ConvertTo-SampleSummaries -Samples $Samples)
        Edges          = (ConvertTo-EdgeSummaries -Edges $edgeDetails)
    }
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
    #
    # MaxTotalMs > 0이면 전체 측정의 하드 데드라인. 데드라인 직전(현재 timeout만큼
    # 여유를 두고)부터 새 요청을 시작하지 않아 in-flight 1건까지 포함해 MaxTotalMs를
    # 넘지 않는다. 재측정 하드캡에서 사용. 0이면 무제한(첫 측정·타겟 변경).
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
        [int]$DefaultTimeoutSec = 5,
        [int]$MaxTotalMs = 0
    )
    $samples = New-Object System.Collections.ArrayList
    $useNaverClockApi = Test-NaverClockUrl -Url $Url
    $deadlineSw = [System.Diagnostics.Stopwatch]::StartNew()
    # 데드라인 초과 여부. ReserveMs는 곧 시작할 요청의 최대 비용(=timeout)으로,
    # 그만큼 일찍 멈춰 in-flight 요청까지 포함해 MaxTotalMs를 넘지 않게 한다.
    $isPastDeadline = {
        param([double]$ReserveMs)
        return ($MaxTotalMs -gt 0) -and (($deadlineSw.Elapsed.TotalMilliseconds + $ReserveMs) -ge $MaxTotalMs)
    }

    # RTT 추정 단계: timeout 알 수 없으니 기본값 사용
    for ($i = 0; $i -lt $RttProbeCount; $i++) {
        if (& $isPastDeadline ($DefaultTimeoutSec * 1000)) { break }
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
        if (& $isPastDeadline ($adaptiveTimeoutSec * 1000)) { break }
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
        # edge 계열이고 edge가 부족할 때만 연장(Test-ShouldExtendWindow).
        if (-not (Test-ShouldExtendWindow -Method $tentative.Method -AcceptedCount $tentative.AcceptedCount -MinEdgeCount $MinEdgeCount)) { break }
        if ($ExtendWindowMs -le 0) { break }
        if (& $isPastDeadline ($adaptiveTimeoutSec * 1000)) { break }

        $extendCount = [int][Math]::Ceiling($ExtendWindowMs / ($rttMedian + $IntervalMs))
        $extendTarget = $samples.Count + $extendCount
        for ($i = $samples.Count; $i -lt $extendTarget; $i++) {
            if (& $isPastDeadline ($adaptiveTimeoutSec * 1000)) { break }
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
