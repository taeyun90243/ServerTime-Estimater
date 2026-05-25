. "$PSScriptRoot\..\src\measurement.ps1"

function Format-RfcDate {
    # unix-ms -> RFC 1123 Date 헤더 문자열 (테스트용)
    param([Parameter(Mandatory)][double]$UnixMs)
    return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$UnixMs).UtcDateTime.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
}

Describe 'Measurement pure functions' {
    It 'ConvertTo-DateMs parses RFC 1123 Date header' {
        $ms = ConvertTo-DateMs 'Thu, 30 Apr 2026 18:27:26 GMT'
        $expected = [DateTime]::new(2026,4,30,18,27,26,[DateTimeKind]::Utc)
        $actual = [DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc).AddMilliseconds($ms)
        $actual | Should Be $expected
    }

    It 'Get-OffsetMs computes Cristian raw offset' {
        $tsMs = 1000000000000
        $rttMs = 60
        $pcAtT2Ms = 999999999500
        $offset = Get-OffsetMs -ServerDateMs $tsMs -RttMs $rttMs -PcAtT2Ms $pcAtT2Ms
        $expected = ($tsMs + 30) - $pcAtT2Ms
        $offset | Should Be $expected
    }

    It 'Get-EffectiveServerDateMs returns Date unchanged when no Age header' {
        $expected = ConvertTo-DateMs 'Sun, 24 May 2026 08:44:13 GMT'
        Get-EffectiveServerDateMs -DateHeader 'Sun, 24 May 2026 08:44:13 GMT' | Should Be $expected
    }

    It 'Get-EffectiveServerDateMs adds Age seconds to a cache-frozen Date (CloudFront)' {
        # Date frozen at :13, Age=7 -> real server second is :20
        $base = ConvertTo-DateMs 'Sun, 24 May 2026 08:44:13 GMT'
        Get-EffectiveServerDateMs -DateHeader 'Sun, 24 May 2026 08:44:13 GMT' -AgeHeader '7' | Should Be ($base + 7000)
    }

    It 'Get-EffectiveServerDateMs treats blank/zero Age as no offset' {
        $base = ConvertTo-DateMs 'Sun, 24 May 2026 08:44:13 GMT'
        Get-EffectiveServerDateMs -DateHeader 'Sun, 24 May 2026 08:44:13 GMT' -AgeHeader '' | Should Be $base
        Get-EffectiveServerDateMs -DateHeader 'Sun, 24 May 2026 08:44:13 GMT' -AgeHeader '0' | Should Be $base
    }

    It 'Resolve-MeasurementTarget routes Interpark ticket hosts to the final ticket page' {
        $r = Resolve-MeasurementTarget -Url 'https://ticket.interpark.com/'
        $r.TargetUrl | Should Be 'https://nol.interpark.com/ticket'
        $r.MeasurementUrl | Should Match '^https://nol\.interpark\.com/ticket\?t=[0-9a-f]{10}$'
        $r.MeasurementNote | Should Be 'interpark-final-ticket-page'
    }

    It 'Resolve-MeasurementTarget canonicalizes nol.interpark.com root to the ticket page' {
        $r = Resolve-MeasurementTarget -Url 'https://nol.interpark.com/'
        $r.TargetUrl | Should Be 'https://nol.interpark.com/ticket'
        $r.MeasurementUrl | Should Match '^https://nol\.interpark\.com/ticket\?t=[0-9a-f]{10}$'
        $r.MeasurementNote | Should Be 'interpark-final-ticket-page'
    }

    It 'Resolve-MeasurementTarget keeps non-Interpark URLs unchanged' {
        $r = Resolve-MeasurementTarget -Url 'https://example.com/path'
        $r.TargetUrl | Should Be 'https://example.com/path'
        $r.MeasurementUrl | Should Be 'https://example.com/path'
        $r.MeasurementNote | Should Be ''
    }
}

Describe 'Sample reduction algorithm' {
    It 'Get-Median returns middle value for odd count' {
        Get-Median @(1,3,5,7,9) | Should Be 5
    }
    It 'Get-Median returns true middle for n=3 (banker rounding regression)' {
        Get-Median @(125,325,525) | Should Be 325
    }
    It 'Get-Median returns true middle for n=7' {
        Get-Median @(10,20,30,40,50,60,70) | Should Be 40
    }
    It 'Get-Median averages two middle for even count' {
        Get-Median @(1,2,3,4) | Should Be 2.5
    }
    It 'Get-StdDev computes Bessel-corrected stddev' {
        # values 2,4,4,4,5,5,7,9 — known stddev(sample) = 2.138...
        $sd = Get-StdDev @(2,4,4,4,5,5,7,9)
        [Math]::Round($sd,3) | Should Be 2.138
    }
    It 'Reduce-Samples combines filter + median + sigma + ci95' {
        $samples = 1..100 | ForEach-Object {
            [PSCustomObject]@{ RttMs = $_; RawOffsetMs = 1000 + ($_ % 7) * 3; OffsetMs = 1500 + ($_ % 7) * 3 }
        }
        $r = Reduce-Samples -Samples $samples
        $r.AcceptedCount | Should Be 6
        $r.Method | Should Be 'upper-envelope'
        $r.OffsetMs | Should Not BeNullOrEmpty
        $r.Ci95Ms | Should BeGreaterThan -1
    }

    It 'Reduce-Samples falls back to raw offset upper envelope without edge fields' {
        $samples = 0..49 | ForEach-Object {
            $phaseMs = ($_ * 100) % 1000
            [PSCustomObject]@{
                RttMs = 20
                RawOffsetMs = 1000 - $phaseMs
                OffsetMs = 1500 - $phaseMs
            }
        }
        $r = Reduce-Samples -Samples $samples
        $r.Method | Should Be 'upper-envelope'
        [Math]::Abs($r.OffsetMs - 1000) | Should BeLessThan 80
    }

    It 'Reduce-Samples estimates offset from Date header edges when transitions are visible' {
        $pcBaseMs = 2000000.0
        $trueOffsetMs = 350.0
        $samples = 0..49 | ForEach-Object {
            $pcEventMs = $pcBaseMs + ($_ * 100.0)
            $serverEventMs = $pcEventMs + $trueOffsetMs
            $serverDateMs = [Math]::Floor($serverEventMs / 1000.0) * 1000.0
            $rttMs = 20.0
            $pcAtT2Ms = $pcEventMs + ($rttMs / 2.0)
            [PSCustomObject]@{
                RttMs = $rttMs
                ServerDateMs = $serverDateMs
                PcAtT2Ms = $pcAtT2Ms
                RawOffsetMs = ($serverDateMs + $rttMs / 2.0) - $pcAtT2Ms
                OffsetMs = ($serverDateMs + $rttMs / 2.0 + 500.0) - $pcAtT2Ms
            }
        }
        $r = Reduce-Samples -Samples $samples
        $r.Method | Should Be 'edge-intersect'
        [Math]::Abs($r.OffsetMs - $trueOffsetMs) | Should BeLessThan 30
    }

    It 'applies Age only when raw Date is FROZEN across the window (CloudFront cache)' {
        # frozen Date 캐시: raw Date는 한 초에 고정, Age가 매초 증가.
        # Reduce-Samples가 frozen으로 판정 → ServerDateMs = Date+Age → edge 복구.
        $pcBaseMs = 2000000.0
        $trueOffsetMs = 350.0
        $frozenDateSecMs = [Math]::Floor(($pcBaseMs + $trueOffsetMs) / 1000.0) * 1000.0
        $samples = 0..49 | ForEach-Object {
            $pcEventMs = $pcBaseMs + ($_ * 100.0)
            $serverEventMs = $pcEventMs + $trueOffsetMs
            $realServerSecMs = [Math]::Floor($serverEventMs / 1000.0) * 1000.0
            $ageSec = [int](($realServerSecMs - $frozenDateSecMs) / 1000.0)
            $rttMs = 20.0
            $pcAtT2Ms = $pcEventMs + ($rttMs / 2.0)
            [PSCustomObject]@{
                RttMs = $rttMs
                RawServerDateMs = $frozenDateSecMs   # 고정
                AgeSec = $ageSec                     # 매초 증가
                ServerDateMs = $frozenDateSecMs      # 기본값(raw); resolver가 덮어씀
                PcAtT2Ms = $pcAtT2Ms
                RawOffsetMs = ($frozenDateSecMs + $rttMs / 2.0) - $pcAtT2Ms
                OffsetMs = ($frozenDateSecMs + $rttMs / 2.0) - $pcAtT2Ms
            }
        }
        $r = Reduce-Samples -Samples $samples
        $r.AgeCorrected | Should Be $true
        $r.Method | Should Be 'edge-intersect'
        [Math]::Abs($r.OffsetMs - $trueOffsetMs) | Should BeLessThan 30
    }

    It 'does NOT add Age when raw Date is LIVE even if Age is nonzero (no whole-second overshoot)' {
        # ticket.interpark.com 회귀: raw Date가 매초 살아 움직이는데 Age=6이 붙는 경우.
        # Age를 더하면 +6000ms 미래로 과보정 → 반드시 raw Date를 써야 함.
        $pcBaseMs = 2000000.0
        $trueOffsetMs = 350.0
        $spuriousAge = 6
        $samples = 0..119 | ForEach-Object {
            $pcEventMs = $pcBaseMs + ($_ * 100.0)
            $serverEventMs = $pcEventMs + $trueOffsetMs
            $liveDateMs = [Math]::Floor($serverEventMs / 1000.0) * 1000.0   # 매초 증가(live)
            $rttMs = 20.0
            $pcAtT2Ms = $pcEventMs + ($rttMs / 2.0)
            [PSCustomObject]@{
                RttMs = $rttMs
                RawServerDateMs = $liveDateMs
                AgeSec = $spuriousAge
                ServerDateMs = $liveDateMs
                PcAtT2Ms = $pcAtT2Ms
                RawOffsetMs = ($liveDateMs + $rttMs / 2.0) - $pcAtT2Ms
                OffsetMs = ($liveDateMs + $rttMs / 2.0) - $pcAtT2Ms
            }
        }
        $r = Reduce-Samples -Samples $samples
        $r.AgeCorrected | Should Be $false
        $r.Method | Should Be 'edge-intersect'
        # +6000ms 과보정이 없어야 한다: 진짜 오프셋 근처여야 함.
        [Math]::Abs($r.OffsetMs - $trueOffsetMs) | Should BeLessThan 30
    }
}

Describe 'Get-EdgeDetails per-edge offset bounds' {
    It 'returns LowerMs = S - R, UpperMs = S - L, OffsetMs = midpoint' {
        # prev: serverEvent PC = 4600 - 45 = 4555, Date 4000
        # curr: serverEvent PC = 4740 - 45 = 4695, Date 5000
        $samples = @(
            [PSCustomObject]@{ RttMs = 90; ServerDateMs = 4000; PcAtT2Ms = 4600 },
            [PSCustomObject]@{ RttMs = 90; ServerDateMs = 5000; PcAtT2Ms = 4740 }
        )
        $edges = Get-EdgeDetails -Samples $samples
        @($edges).Count | Should Be 1
        $e = @($edges)[0]
        $e.LowerMs  | Should Be 305   # 5000 - 4695
        $e.UpperMs  | Should Be 445   # 5000 - 4555
        $e.OffsetMs | Should Be 375   # 5000 - 4625
    }
}

Describe 'Get-HybridOffsetEstimate' {
    # 교집합 = 균등노이즈 MLE. 1초 격자 제약을 써서 1/n로 수렴.
    It 'intersects all consistent edges and returns midpoint of the feasible region' {
        $edges = @(
            [PSCustomObject]@{ LowerMs = 305; UpperMs = 445; OffsetMs = 375 },
            [PSCustomObject]@{ LowerMs = 185; UpperMs = 325; OffsetMs = 255 },
            [PSCustomObject]@{ LowerMs = 205; UpperMs = 345; OffsetMs = 275 }
        )
        $r = Get-HybridOffsetEstimate -Edges $edges
        $r.Method    | Should Be 'edge-intersect'
        $r.UsedCount | Should Be 3
        $r.OffsetMs  | Should Be 315   # ([305..325] 교집합 중점)
        $r.WidthMs   | Should Be 20
    }

    It 'drops an inconsistent outlier edge and flags robust intersection' {
        $edges = @(
            [PSCustomObject]@{ LowerMs = 305; UpperMs = 445; OffsetMs = 375 },
            [PSCustomObject]@{ LowerMs = 185; UpperMs = 325; OffsetMs = 255 },
            [PSCustomObject]@{ LowerMs = 205; UpperMs = 345; OffsetMs = 275 },
            [PSCustomObject]@{ LowerMs = 600; UpperMs = 740; OffsetMs = 670 }  # outlier
        )
        $r = Get-HybridOffsetEstimate -Edges $edges
        $r.Method    | Should Be 'edge-intersect-robust'
        $r.UsedCount | Should Be 3
        $r.OffsetMs  | Should Be 315
    }

    It 'falls back to median of midpoints when no two edges overlap' {
        $edges = @(
            [PSCustomObject]@{ LowerMs = 100; UpperMs = 150; OffsetMs = 125 },
            [PSCustomObject]@{ LowerMs = 300; UpperMs = 350; OffsetMs = 325 },
            [PSCustomObject]@{ LowerMs = 500; UpperMs = 550; OffsetMs = 525 }
        )
        $r = Get-HybridOffsetEstimate -Edges $edges
        $r.Method   | Should Be 'edge-median'
        $r.OffsetMs | Should Be 325   # median(125,325,525)
    }

    It 'handles a single edge as its midpoint' {
        $edges = @(
            [PSCustomObject]@{ LowerMs = 200; UpperMs = 340; OffsetMs = 270 }
        )
        $r = Get-HybridOffsetEstimate -Edges $edges
        $r.Method    | Should Be 'edge-intersect'
        $r.UsedCount | Should Be 1
        $r.OffsetMs  | Should Be 270
    }
}

Describe 'Get-RttThreshold' {
    It 'computes rttMedian * 1.5 + 2' {
        Get-RttThreshold -RttMedianMs 100 | Should Be 152
    }
    It 'handles zero median' {
        Get-RttThreshold -RttMedianMs 0 | Should Be 2
    }
}

Describe 'Test-ShouldExtendWindow' {
    It 'extends when edge-based and below MinEdgeCount' {
        Test-ShouldExtendWindow -Method 'edge-intersect' -AcceptedCount 3 -MinEdgeCount 8 | Should Be $true
    }
    It 'stops when edge count reached' {
        Test-ShouldExtendWindow -Method 'edge-intersect' -AcceptedCount 8 -MinEdgeCount 8 | Should Be $false
    }
    It 'does not extend for non-edge method (upper-envelope)' {
        Test-ShouldExtendWindow -Method 'upper-envelope' -AcceptedCount 1 -MinEdgeCount 8 | Should Be $false
    }
    It 'extends for edge-median when below count' {
        Test-ShouldExtendWindow -Method 'edge-median' -AcceptedCount 2 -MinEdgeCount 8 | Should Be $true
    }
}

Describe 'Get-RemeasureAttemptDecision' {
    # 재측정 수용 판정. 첫 측정/타겟변경은 edge 적어도 수용, 진짜 재측정만 edge>=5 요구.
    It 'accepts target change regardless of edge count' {
        Get-RemeasureAttemptDecision -IsTargetChange $true -AcceptedCount 1 -DeltaMs 9999 | Should Be 'accept'
    }
    It 'keeps existing genuine remeasure with enough edges and very small delta' {
        Get-RemeasureAttemptDecision -IsTargetChange $false -AcceptedCount 6 -DeltaMs 30 | Should Be 'keep-existing'
    }
    It 'accepts genuine remeasure with enough edges and moderate delta' {
        Get-RemeasureAttemptDecision -IsTargetChange $false -AcceptedCount 6 -DeltaMs 50 | Should Be 'accept'
    }
    It 'fails genuine remeasure with too few edges even if delta small' {
        Get-RemeasureAttemptDecision -IsTargetChange $false -AcceptedCount 4 -DeltaMs 10 | Should Be 'fail-insufficient'
    }
    It 'flags delta-exceeded with enough edges but large delta' {
        Get-RemeasureAttemptDecision -IsTargetChange $false -AcceptedCount 6 -DeltaMs 500 | Should Be 'delta-exceeded'
    }
    It 'accepts at exact boundary (5 edges, 100ms delta)' {
        Get-RemeasureAttemptDecision -IsTargetChange $false -AcceptedCount 5 -DeltaMs 100 | Should Be 'accept'
    }
}

Describe 'Fast measurement path' {
    # 빠른 측정(MinEdgeCount=1)은 edge가 1~2개여도 결과를 채택한다.
    # 적은 edge에서 Reduce-Samples가 throw 없이 edge 계열 결과를 내는지 회귀.
    It 'Reduce-Samples returns an edge result with a single edge (no throw)' {
        # ServerDateMs가 ~1000ms 점프(초 경계 전환)하지만 PC시각은 ~100ms만 진행 → edge 1개.
        $base = 1700000000000.0
        $samples = @(
            [PSCustomObject]@{ RttMs=80.0; RawServerDateMs=$base;          AgeSec=0; ServerDateMs=$base;          PcAtT2Ms=($base+50);  RawOffsetMs=0.0; OffsetMs=0.0 }
            [PSCustomObject]@{ RttMs=80.0; RawServerDateMs=($base+1000.0); AgeSec=0; ServerDateMs=($base+1000.0); PcAtT2Ms=($base+150); RawOffsetMs=0.0; OffsetMs=0.0 }
        )
        { Reduce-Samples -Samples $samples } | Should Not Throw
        $r = Reduce-Samples -Samples $samples
        $r | Should Not BeNullOrEmpty
        $r.Method | Should Match '^edge'
    }
}
