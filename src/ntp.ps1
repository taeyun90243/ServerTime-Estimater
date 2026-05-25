# =============================================================================
# ntp.ps1 - NTP(시간 서버) 조회 모듈
# -----------------------------------------------------------------------------
# [역할] 한국표준과학연구원(KRISS) NTP 서버에 물어 "내 PC 시계가 표준시 대비
#        얼마나 어긋났는지"(skew)를 구한다. 이 값은 화면 하단에 참고용으로만
#        보여주고, 실제 서버시각 오프셋 보정에는 쓰지 않는다(§7).
#
# [NTP란] 시간 서버에 UDP 패킷을 보내면 서버가 자기 시각을 담아 돌려주는 프로토콜.
#         시각은 "1900-01-01 기준 초 + 소수부(frac)" 의 빅엔디안 바이트로 온다.
#
#  . "$PSScriptRoot\anchor.ps1" 은 다른 파일을 "불러오기"(dot-sourcing).
#  $PSScriptRoot = 지금 이 .ps1이 있는 폴더 경로. 그래서 같은 폴더의 anchor.ps1을 로드.
#  (anchor.ps1의 Get-PcUtcNow / Get-StopwatchElapsedMs 를 여기서 쓰기 위함)
# =============================================================================
. "$PSScriptRoot\anchor.ps1"

# 서버가 보낸 NTP 타임스탬프(8바이트)를 DateTime으로 변환.
function ConvertFrom-NtpTimestamp {
    param(
        [Parameter(Mandatory)][byte[]]$ResponseBytes,   # 응답 바이트 배열 전체
        [Parameter(Mandatory)][int]$StartIndex          # 타임스탬프가 시작되는 위치
    )
    # 빅엔디안 4바이트 초(secs) + 4바이트 소수부(frac).
    # $a[i..j] 는 배열의 i~j 구간 슬라이스(범위 추출).
    $secsBytes = $ResponseBytes[$StartIndex..($StartIndex + 3)]
    $fracBytes = $ResponseBytes[($StartIndex + 4)..($StartIndex + 7)]
    # 내 PC가 리틀엔디안이면 바이트 순서를 뒤집어야 숫자로 올바로 읽힌다.
    if ([BitConverter]::IsLittleEndian) {
        [Array]::Reverse($secsBytes)
        [Array]::Reverse($fracBytes)
    }
    $secs = [BitConverter]::ToUInt32($secsBytes, 0)   # 1900년 이후 초
    $frac = [BitConverter]::ToUInt32($fracBytes, 0)   # 1초를 2^32로 쪼갠 소수부
    $epoch1900 = [DateTime]::new(1900,1,1,0,0,0,[DateTimeKind]::Utc)
    # frac / 2^32 = 소수 초, × 1000 = 밀리초. (4294967296 = 0x100000000 = 2^32)
    $fracMs = $frac / 4294967296.0 * 1000.0
    return $epoch1900.AddSeconds($secs).AddMilliseconds($fracMs)
}

# NTP 서버에 한 번 물어 skew(PC 시계 오차)와 RTT를 구해 돌려준다.
function Get-NtpInfo {
    param(
        [string]$Server = 'time.kriss.re.kr',   # 기본 시간 서버(KRISS)
        [int]$TimeoutMs = 3000                   # 응답 대기 한도
    )
    # 보낼 48바이트짜리 NTP 요청 패킷을 만든다(전부 0).
    $bytes = New-Object byte[] 48
    # 첫 바이트에 헤더: LI=0, VN=3, Mode=3(client). 0x1B = 2진수 00 011 011.
    $bytes[0] = 0x1B

    $udp = $null
    # try / finally: 중간에 에러가 나도 finally의 정리(소켓 닫기)는 반드시 실행.
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Server, 123)            # NTP 표준 포트 123

        $t1 = [System.Diagnostics.Stopwatch]::GetTimestamp()   # 보내기 직전 시각(틱)
        [void]$udp.Send($bytes, 48)            # [void] = 반환값 버리기(화면 출력 방지)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)         # [ref] = 이 변수를 함수가 채워주도록 참조 전달
        $t2 = [System.Diagnostics.Stopwatch]::GetTimestamp()   # 받은 직후 시각(틱)

        # -band 는 비트 AND 연산. 응답 헤더에서 mode/stratum 검증.
        $mode    = $resp[0] -band 0x07
        $stratum = $resp[1]
        if ($mode -ne 4)        { throw 'NTP: not a server response' }   # -ne = 같지 않다
        if ($stratum -eq 0 -or $stratum -ge 16) { throw 'NTP: stratum unsync' }  # -ge = 이상

        # 응답의 transmit 타임스탬프는 40번째 바이트부터 시작.
        $ntpUtc = ConvertFrom-NtpTimestamp -ResponseBytes $resp -StartIndex 40
        $rttMs = Get-StopwatchElapsedMs -StartTicks $t1 -EndTicks $t2     # 왕복 지연
        # 서버 시각 + RTT/2 = 응답 받은 시점의 서버 시각 추정(Cristian).
        $serverAtT2 = $ntpUtc.AddMilliseconds($rttMs / 2)
        # 그것과 내 PC 시각의 차이 = PC 시계 오차(skew).
        $skewMs = ($serverAtT2 - (Get-PcUtcNow)).TotalMilliseconds

        # [PSCustomObject]@{...} = 이름붙은 필드를 가진 결과 객체를 만들어 반환.
        return [PSCustomObject]@{
            SkewMs = $skewMs
            RttMs  = $rttMs
            At     = Get-PcUtcNow
        }
    } finally {
        if ($udp) { $udp.Close() }    # 소켓 정리(누수 방지)
    }
}
