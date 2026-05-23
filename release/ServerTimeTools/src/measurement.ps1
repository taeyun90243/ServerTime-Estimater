# measurement.ps1 - 측정 알고리즘 (§4)
. "$PSScriptRoot\anchor.ps1"

$script:ProbeUserAgent = 'ServerTimeProbe/1.0 (personal-use)'

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
    $apiUrl = 'https://ts-proxy.naver.com/dcontent/util/time.naver?passportKey=9964bf6d4645e3a94ca5e72c231b50a3c18fb688&_format=yyyy/MM/dd/HH/mm/ss/SSS&site=naver'

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

    $ordered = @($Samples)
    $edges = New-Object System.Collections.ArrayList
    for ($i = 1; $i -lt $ordered.Count; $i++) {
        $prev = $ordered[$i - 1]
        $curr = $ordered[$i]
        if ($null -eq $prev.ServerDateMs -or $null -eq $curr.ServerDateMs) { continue }

        $dateStepMs = [double]$curr.ServerDateMs - [double]$prev.ServerDateMs
        if ($dateStepMs -lt 900 -or $dateStepMs -gt 1100) { continue }

        $prevServerEventPcMs = [double]$prev.PcAtT2Ms - ([double]$prev.RttMs / 2)
        $currServerEventPcMs = [double]$curr.PcAtT2Ms - ([double]$curr.RttMs / 2)
        if ($currServerEventPcMs -le $prevServerEventPcMs) { continue }

        $edgePcMs = ($prevServerEventPcMs + $currServerEventPcMs) / 2.0
        $edgeOffsetMs = [double]$curr.ServerDateMs - $edgePcMs
        [void]$edges.Add($edgeOffsetMs)
    }

    return $edges
}

function Reduce-Samples {
    param([Parameter(Mandatory)]$Samples)
    # Prefer real Date-header edge detection: when Date jumps N -> N+1, the
    # server second boundary lies between those two server-event estimates.
    $candidates = Select-EdgeOffsetCandidates -Samples $Samples
    $method = 'edge'
    if ($candidates.Count -eq 0) {
        # Fallback for pathological/cached Date behavior where no transition is
        # visible in the sample window.
        $candidates = Select-QuantizedOffsetCandidates -Samples $Samples
        $method = 'upper-envelope'
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
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$IntervalMs = 50,
        [int]$TargetWindowMs = 6000,
        [int]$MinCount = 10,
        [int]$MaxCount = 60,
        [int]$RttProbeCount = 3
    )
    $samples = New-Object System.Collections.ArrayList
    $useNaverClockApi = Test-NaverClockUrl -Url $Url

    for ($i = 0; $i -lt $RttProbeCount; $i++) {
        try {
            $s = if ($useNaverClockApi) { Invoke-NaverTimeProbe } else { Invoke-HeadProbe -Url $Url }
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

    for ($i = $samples.Count; $i -lt $count; $i++) {
        try {
            $s = if ($useNaverClockApi) { Invoke-NaverTimeProbe } else { Invoke-HeadProbe -Url $Url }
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
    return Reduce-Samples -Samples $samples
}
