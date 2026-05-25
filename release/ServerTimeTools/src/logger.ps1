# =============================================================================
# logger.ps1 - 측정 이벤트 로그 기록 모듈
# -----------------------------------------------------------------------------
# [역할] 측정/재측정/실패 같은 사건을 한 줄에 하나씩 JSON으로 적는다(JSONL 형식).
#        파일명은 날짜별: logs/probe-YYYYMMDD.jsonl. 25일보다 오래된 로그는 자동 삭제.
#        이 로그가 있어서 "왜 빠른 측정이 실패했나" 같은 원인 분석이 가능하다.
# =============================================================================
. "$PSScriptRoot\anchor.ps1"   # Get-PcUtcNow 사용을 위해 anchor 모듈 로드

# 로그 폴더 경로 저장소(파일 전역). 처음엔 비어 있고 Initialize-Logger가 채운다.
$script:LogRoot = $null

# 로그 폴더를 정하고 준비한다. 앱 시작 시 1회 호출.
function Initialize-Logger {
    param([Parameter(Mandatory)][string]$LogDir)
    # 폴더가 없으면 새로 만든다. Test-Path = 존재 여부 검사(True/False).
    # [void](...) = New-Item이 만든 객체 출력을 버린다.
    if (-not (Test-Path $LogDir)) { [void](New-Item -ItemType Directory -Path $LogDir -Force) }
    $script:LogRoot = $LogDir
    Remove-OldLogs   # 오래된 로그 청소
}

# 오늘 날짜에 해당하는 로그 파일의 전체 경로를 만들어 돌려준다.
function Get-CurrentLogPath {
    # ToString('yyyyMMdd') = 20260525 같은 날짜 문자열.
    $today = (Get-PcUtcNow).ToString('yyyyMMdd')
    # Join-Path = 폴더와 파일명을 OS에 맞게 안전히 합친다.
    return Join-Path $script:LogRoot "probe-$today.jsonl"
}

# 사건 하나를 로그 파일에 한 줄(JSON)로 덧붙인다.
function Write-LogEvent {
    # [hashtable]$Event = key=value 묶음으로 사건 내용을 받는다. 예: @{ ev='measure'; offsetMs=12 }
    param([Parameter(Mandatory)][hashtable]$Event)
    # 아직 로거 준비 전이면 조용히 무시(return = 함수 종료).
    if (-not $script:LogRoot) { return }
    # 모든 이벤트에 타임스탬프(ts)를 자동으로 끼워 넣는다. 'o' = ISO 8601 형식.
    $Event['ts'] = (Get-PcUtcNow).ToString('o')
    # 해시테이블을 한 줄 JSON 문자열로 변환. -Compress=공백 없이, -Depth 5=중첩 5단계까지.
    $line = ($Event | ConvertTo-Json -Compress -Depth 5)
    # 파일 끝에 한 줄 추가(append). 한글 깨짐 방지로 UTF8.
    Add-Content -Path (Get-CurrentLogPath) -Value $line -Encoding UTF8
}

# 보존 기간(25일)이 지난 옛 로그 파일을 지운다.
function Remove-OldLogs {
    if (-not $script:LogRoot) { return }
    # AddDays(-25) = 지금으로부터 25일 전 시각(기준선).
    $cutoff = (Get-PcUtcNow).AddDays(-25)
    # 로그 폴더에서 probe-*.jsonl 파일들을 찾아,
    Get-ChildItem -Path $script:LogRoot -Filter 'probe-*.jsonl' -ErrorAction SilentlyContinue |
        # 마지막 수정 시각이 기준선보다 오래된 것만 골라(-lt = 미만),
        Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
        # 삭제한다. ($_ = 파이프라인으로 넘어온 현재 파일)
        Remove-Item -Force -ErrorAction SilentlyContinue
}
