. "$PSScriptRoot\..\src\anchor.ps1"

Describe 'Anchor module' {
    It 'Initialize-Anchor sets script-scope anchor' {
        Initialize-Anchor
        $script:Anchor.Utc | Should Not BeNullOrEmpty
        $script:Anchor.Sw  | Should Not BeNullOrEmpty
        $script:Anchor.Freq | Should BeGreaterThan 0
    }

    It 'Get-PcUtcNow returns increasing values' {
        Initialize-Anchor
        $a = Get-PcUtcNow
        Start-Sleep -Milliseconds 50
        $b = Get-PcUtcNow
        ($b - $a).TotalMilliseconds | Should BeGreaterThan 30
        ($b - $a).TotalMilliseconds | Should BeLessThan 200
    }

    It 'Get-PcUtcNow tracks elapsed without using DateTime.UtcNow directly' {
        Initialize-Anchor
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $start = Get-PcUtcNow
        Start-Sleep -Milliseconds 100
        $end = Get-PcUtcNow
        $sw.Stop()
        # anchor 기반 진행과 stopwatch 진행이 일치해야
        $anchorElapsed = ($end - $start).TotalMilliseconds
        $swElapsed = $sw.Elapsed.TotalMilliseconds
        [Math]::Abs($anchorElapsed - $swElapsed) | Should BeLessThan 10
    }
}
