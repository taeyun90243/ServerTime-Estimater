. "$PSScriptRoot\..\src\http-server.ps1"
. "$PSScriptRoot\..\src\measurement.ps1"

Describe 'HTTP server URL helpers' {
    It 'Normalize-TargetUrl adds https scheme when omitted' {
        Normalize-TargetUrl 'example.com/path' | Should Be 'https://example.com/path'
    }

    It 'Normalize-TargetUrl rejects unsupported schemes' {
        try {
            Normalize-TargetUrl 'ftp://example.com/'
            $threw = $false
        } catch {
            $threw = $true
        }
        $threw | Should Be $true
    }
}

Describe 'HTTP server target state' {
    BeforeEach {
        Initialize-Anchor
    }

    It 'keeps previous measurement when the same measured URL is requested again' {
        $state = New-StateStore
        $measuredAt = [DateTime]::new(2026,5,2,8,0,0,[DateTimeKind]::Utc)
        $state.TargetUrl = 'https://example.com/'
        $state.Host = 'example.com'
        $state.LastMeasureAt = $measuredAt
        $state.OffsetMs = 123.4
        $state.RttMedianMs = 12.3
        $state.SigmaMs = 4.5
        $state.Ci95Ms = 6.7

        Set-TargetState -State $state -Url 'https://example.com/'

        $state.PendingTargetChange | Should Be $false
        $state.LastMeasureAt | Should Be $measuredAt
        $state.RttMedianMs | Should Be 12.3
        $state.Status | Should Be 'queued'
    }

    It 'clears previous measurement when explicit initial measure is requested for same URL' {
        $state = New-StateStore
        $state.TargetUrl = 'https://example.com/'
        $state.Host = 'example.com'
        $state.LastMeasureAt = [DateTime]::new(2026,5,2,8,0,0,[DateTimeKind]::Utc)
        $state.RttMedianMs = 12.3
        $state.SigmaMs = 4.5
        $state.Ci95Ms = 6.7

        Set-TargetState -State $state -Url 'https://example.com/' -ForceInitialMeasure $true

        $state.PendingTargetChange | Should Be $true
        $state.LastMeasureAt | Should Be $null
        $state.RttMedianMs | Should Be 0.0
        $state.Status | Should Be 'queued'
    }

    It 'clears previous measurement when the URL changes' {
        $state = New-StateStore
        $state.TargetUrl = 'https://example.com/'
        $state.LastMeasureAt = [DateTime]::new(2026,5,2,8,0,0,[DateTimeKind]::Utc)
        $state.RttMedianMs = 12.3
        $state.SigmaMs = 4.5
        $state.Ci95Ms = 6.7

        Set-TargetState -State $state -Url 'https://www.naver.com/'

        $state.PendingTargetChange | Should Be $true
        $state.LastMeasureAt | Should Be $null
        $state.RttMedianMs | Should Be 0.0
        $state.Host | Should Be 'www.naver.com'
        $state.Status | Should Be 'queued'
    }

    It 'keeps same-target remeasure on the delta-guard path' {
        $state = New-StateStore
        $state.TargetUrl = 'https://example.com/'
        $state.Host = 'example.com'
        $state.LastMeasureAt = [DateTime]::new(2026,5,2,8,0,0,[DateTimeKind]::Utc)
        $state.MeasureTimer = New-Object Timers.Timer
        $stream = New-Object IO.MemoryStream
        $resp = [PSCustomObject]@{
            StatusCode = 200
            ContentType = ''
            ContentLength64 = 0
            OutputStream = $stream
        }

        Start-RemeasureFromRequest -resp $resp -state $state

        $state.PendingTargetChange | Should Be $false
        $state.LastMeasureAt | Should Not Be $null
        $state.Status | Should Be 'queued'
    }

    It 'treats Interpark cache-busted remeasure as the same target' {
        $state = New-StateStore
        $state.TargetUrl = 'https://nol.interpark.com/ticket'
        $state.MeasurementUrl = 'https://nol.interpark.com/ticket?t=old'
        $state.Host = 'nol.interpark.com'
        $state.LastMeasureAt = [DateTime]::new(2026,5,2,8,0,0,[DateTimeKind]::Utc)
        $state.MeasureTimer = New-Object Timers.Timer
        $stream = New-Object IO.MemoryStream
        $resp = [PSCustomObject]@{
            StatusCode = 200
            ContentType = ''
            ContentLength64 = 0
            OutputStream = $stream
        }

        Start-RemeasureFromRequest -resp $resp -state $state

        $state.PendingTargetChange | Should Be $false
        $state.TargetUrl | Should Be 'https://nol.interpark.com/ticket'
        $state.MeasurementUrl | Should Match '^https://nol\.interpark\.com/ticket\?t='
        $state.MeasurementUrl | Should Not Be 'https://nol.interpark.com/ticket?t=old'
    }
}
