. "$PSScriptRoot\..\src\ntp.ps1"

Describe 'NTP byte conversion' {
    It 'ConvertFrom-NtpTimestamp parses big-endian to DateTime' {
        $expected = [DateTime]::new(2026,1,1,0,0,0,[DateTimeKind]::Utc)
        $epoch1900 = [DateTime]::new(1900,1,1,0,0,0,[DateTimeKind]::Utc)
        $secs = [uint32]($expected - $epoch1900).TotalSeconds
        $frac = [uint32]0

        # 빅엔디안으로 8바이트 구성
        $bytes = New-Object byte[] 48
        $secsBE = [BitConverter]::GetBytes([uint32]$secs)
        if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($secsBE) }
        [Array]::Copy($secsBE, 0, $bytes, 40, 4)
        # frac은 0이라 둠

        $dt = ConvertFrom-NtpTimestamp -ResponseBytes $bytes -StartIndex 40
        $dt | Should Be $expected
    }
}
