. "$PSScriptRoot\..\src\measurement.ps1"

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
}

Describe 'Sample reduction algorithm' {
    It 'Get-Median returns middle value for odd count' {
        Get-Median @(1,3,5,7,9) | Should Be 5
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
        $r.Method | Should Be 'edge'
        [Math]::Abs($r.OffsetMs - $trueOffsetMs) | Should BeLessThan 60
    }
}
