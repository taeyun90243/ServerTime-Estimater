# =============================================================================
# anchor.ps1 - "흔들리지 않는 시계"(Monotonic 시각) 모듈
# -----------------------------------------------------------------------------
# [왜 필요한가]
#   보통 현재 시각은 [DateTime]::UtcNow 로 읽는다. 그런데 이 값은 Windows가
#   NTP 동기화 등으로 시스템 시계를 갑자기 앞/뒤로 점프시키면 같이 튄다.
#   측정 도중 시계가 뒤로 점프하면 "경과 시간"이 음수가 되는 등 계산이 깨진다.
#
#   그래서 이 프로젝트는 "기준 시각 한 번"만 [DateTime]::UtcNow 로 잡아두고(=Anchor),
#   그 이후의 경과 시간은 절대 거꾸로 안 가는 Stopwatch(고해상도 타이머)로 잰다.
#   현재 시각 = 기준 시각 + Stopwatch로 잰 경과시간. 이러면 중간에 시스템 시계가
#   점프해도 우리 시계는 매끄럽게 흐른다.
#
# [규칙] [DateTime]::UtcNow 직접 호출은 이 파일에서만 한다. 다른 모듈은 항상
#        Get-PcUtcNow 를 쓴다.
# =============================================================================

# $script: 는 "이 파일(스크립트) 안에서만 공유되는 변수"라는 뜻의 스코프 표시.
# 함수 밖에서 함수들이 같이 쓰는 저장소로 둔다. 처음엔 비어 있음($null).
$script:Anchor = $null

# 기준점을 한 번 잡는 함수. 앱 시작 시 probe.ps1에서 1회 호출한다.
function Initialize-Anchor {
    # @{ ... } 는 해시테이블(파이썬 dict 같은 key=value 묶음) 리터럴.
    $script:Anchor = @{
        Utc  = [DateTime]::UtcNow                                  # 기준이 되는 절대 시각(딱 한 번 읽음)
        Sw   = [System.Diagnostics.Stopwatch]::GetTimestamp()      # 그 순간의 Stopwatch 눈금(틱)
        Freq = [System.Diagnostics.Stopwatch]::Frequency           # 1초당 틱 수(틱→초 환산용)
    }
}

# 현재 PC 기준 UTC 시각을 돌려준다. 다른 모듈은 전부 이걸 쓴다.
function Get-PcUtcNow {
    # -eq 는 "같다" 비교 연산자(== 아님). 아직 기준점을 안 잡았으면 에러.
    if ($null -eq $script:Anchor) {
        throw 'Anchor not initialized. Call Initialize-Anchor first.'
    }
    # 지금 틱 - 기준 틱 = 기준 이후 흐른 틱 수.
    $elapsedTicks = [System.Diagnostics.Stopwatch]::GetTimestamp() - $script:Anchor.Sw
    # 틱 ÷ (1초당 틱) × 1000 = 경과한 밀리초.
    $elapsedMs = $elapsedTicks / $script:Anchor.Freq * 1000
    # 기준 시각에 경과 밀리초를 더한 값이 "지금". return 으로 호출자에게 반환.
    return $script:Anchor.Utc.AddMilliseconds($elapsedMs)
}

# 유닉스 epoch(1970-01-01 00:00:00 UTC) 시각을 만들어 돌려준다. ms 변환의 기준점.
function Get-UnixEpoch {
    return [DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)
}

# DateTime → 유닉스 epoch 이후 밀리초(숫자)로 변환.
function ConvertTo-UnixMs {
    # param(...) 은 이 함수가 받는 입력값 선언.
    # [Parameter(Mandatory)] = 반드시 넣어야 함, [DateTime] = 타입 강제.
    param([Parameter(Mandatory)][DateTime]$Utc)
    # (시각 - epoch) 는 TimeSpan(기간) 객체. 그 .TotalMilliseconds 가 총 밀리초.
    return ($Utc - (Get-UnixEpoch)).TotalMilliseconds
}

# 두 Stopwatch 틱 사이의 경과 시간을 밀리초로 환산. RTT 측정 등에 사용.
function Get-StopwatchElapsedMs {
    param(
        [Parameter(Mandatory)][long]$StartTicks,   # 시작 틱
        [Parameter(Mandatory)][long]$EndTicks      # 끝 틱
    )
    return ($EndTicks - $StartTicks) / [System.Diagnostics.Stopwatch]::Frequency * 1000
}
