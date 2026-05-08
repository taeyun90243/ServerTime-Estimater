# ntp.ps1 - NTP 정보 측정 (§7). 보정엔 사용하지 않고 표시 정보 전용
. "$PSScriptRoot\anchor.ps1"

function ConvertFrom-NtpTimestamp {
    param(
        [Parameter(Mandatory)][byte[]]$ResponseBytes,
        [Parameter(Mandatory)][int]$StartIndex
    )
    # 빅엔디안 4바이트 secs + 4바이트 frac
    $secsBytes = $ResponseBytes[$StartIndex..($StartIndex + 3)]
    $fracBytes = $ResponseBytes[($StartIndex + 4)..($StartIndex + 7)]
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($secsBytes)
        [Array]::Reverse($fracBytes)
    }
    $secs = [BitConverter]::ToUInt32($secsBytes, 0)
    $frac = [BitConverter]::ToUInt32($fracBytes, 0)
    $epoch1900 = [DateTime]::new(1900,1,1,0,0,0,[DateTimeKind]::Utc)
    $fracMs = $frac / 4294967296.0 * 1000.0   # 0x100000000
    return $epoch1900.AddSeconds($secs).AddMilliseconds($fracMs)
}

function Get-NtpInfo {
    param(
        [string]$Server = 'time.kriss.re.kr',
        [int]$TimeoutMs = 3000
    )
    $bytes = New-Object byte[] 48
    $bytes[0] = 0x1B   # LI=0, VN=3, Mode=3 (client)

    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Server, 123)

        $t1 = [System.Diagnostics.Stopwatch]::GetTimestamp()
        [void]$udp.Send($bytes, 48)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        $t2 = [System.Diagnostics.Stopwatch]::GetTimestamp()

        $mode    = $resp[0] -band 0x07
        $stratum = $resp[1]
        if ($mode -ne 4)        { throw 'NTP: not a server response' }
        if ($stratum -eq 0 -or $stratum -ge 16) { throw 'NTP: stratum unsync' }

        $ntpUtc = ConvertFrom-NtpTimestamp -ResponseBytes $resp -StartIndex 40
        $rttMs = Get-StopwatchElapsedMs -StartTicks $t1 -EndTicks $t2
        $serverAtT2 = $ntpUtc.AddMilliseconds($rttMs / 2)
        $skewMs = ($serverAtT2 - (Get-PcUtcNow)).TotalMilliseconds

        return [PSCustomObject]@{
            SkewMs = $skewMs
            RttMs  = $rttMs
            At     = Get-PcUtcNow
        }
    } finally {
        if ($udp) { $udp.Close() }
    }
}
