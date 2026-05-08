# anchor.ps1 - Monotonic 시각 함수 (§4.0)
# [DateTime]::UtcNow 직접 호출은 이 파일에서만. 다른 모듈은 Get-PcUtcNow 사용

$script:Anchor = $null

function Initialize-Anchor {
    $script:Anchor = @{
        Utc  = [DateTime]::UtcNow
        Sw   = [System.Diagnostics.Stopwatch]::GetTimestamp()
        Freq = [System.Diagnostics.Stopwatch]::Frequency
    }
}

function Get-PcUtcNow {
    if ($null -eq $script:Anchor) {
        throw 'Anchor not initialized. Call Initialize-Anchor first.'
    }
    $elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $script:Anchor.Sw
    $elapsedMs = $elapsedTicks / $script:Anchor.Freq * 1000
    return $script:Anchor.Utc.AddMilliseconds($elapsedMs)
}

function Get-UnixEpoch {
    return [DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)
}

function ConvertTo-UnixMs {
    param([Parameter(Mandatory)][DateTime]$Utc)
    return ($Utc - (Get-UnixEpoch)).TotalMilliseconds
}

function Get-StopwatchElapsedMs {
    param(
        [Parameter(Mandatory)][long]$StartTicks,
        [Parameter(Mandatory)][long]$EndTicks
    )
    return ($EndTicks - $StartTicks) / [System.Diagnostics.Stopwatch]::Frequency * 1000
}
