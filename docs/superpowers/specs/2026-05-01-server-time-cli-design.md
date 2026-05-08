# 유사 네이비즘 — PC 단독 실행 CLI 설계

작성일: 2026-05-01
대상 호스트: `http://den08.inames.kr/` (확장 가능 구조)
배포 형태: `.bat + .ps1` (PowerShell), 외부 의존성 0
UI: 로컬 HTML + 기본 브라우저 (`http://127.0.0.1:8765`)
정확도 목표: σ ≈ 21ms (95% 신뢰구간 ±42ms)

---

## 1. 개요

대상 서버의 시각을 ms 단위로 추정해 네이버 시계 스타일 원형 UI로 표시한다. 사용자는 티케팅 등 시각이 중요한 작업에 ~2시간 정도 켜두고 사용한다.

전체 흐름:

```
[PowerShell 프로세스]                          [기본 브라우저]
  ├─ HttpListener (127.0.0.1:8765)  ◀────────  GET /
  ├─ 측정 워커 (1분 주기)             ◀────────  GET /api/state (1s 폴링)
  ├─ NTP 점검 워커 (시작 시 + 10분 주기)
  ├─ JSONL 로그 라이터
  └─ 콘솔 로그 (디버그용)

  │  HTTP HEAD (대상 서버)
  ▼
[den08.inames.kr]
```

브라우저는 폴링 1Hz로 서버에서 `{ offsetMs, ntpSkewMs, lastMeasureAt, sigmaMs, status }`만 받고, 화면 갱신은 `performance.now()` 보간으로 60fps.

---

## 2. 요구사항

### 기능
- F1. 시작 시 NTP 점검(`time.kriss.re.kr`) 1회. PC 시계 오차 100ms 초과 시 UI 빨간색 경고.
- F2. 시작 직후 대상 서버 100회 샘플링하여 초기 오프셋 확립.
- F3. 1분마다 백그라운드 재측정. RTT 하위 10% 필터 + 중앙값 + 양자화 보정 +500ms.
- F4. NTP 점검은 10분마다 재실행.
- F5. 브라우저에서 `http://127.0.0.1:8765` 접속 시 원형 ms 시계 표시.
- F6. 측정 실패 시 직전 오프셋 유지하고 UI에 "측정 실패" 표시.
- F7. JSONL 로그 24h 롤링.
- F8. Ctrl+C 또는 브라우저 탭 닫음과 무관하게 PowerShell 콘솔에서 종료.

### 비기능
- N1. 외부 의존성 0 (Windows 기본 환경에서 실행).
- N2. 정확도 σ ≈ 21ms (95% CI ±42ms).
- N3. 대상 서버에 1분당 1회 측정만 (사용자 시작 직후 100회 샘플링은 100ms 간격 = 약 10초간 분산).
- N4. 메모리 점유 < 100MB.

---

## 3. 시스템 아키텍처

### 파일 구성

```
유사 네이비즘 만들기/
├─ run.bat                       # 더블클릭 진입점
├─ src/
│  ├─ probe.ps1                  # 메인 프로세스
│  ├─ measurement.ps1            # 측정 알고리즘 모듈
│  ├─ ntp.ps1                    # NTP 점검 모듈
│  ├─ http-server.ps1            # HttpListener 모듈
│  └─ web/
│     ├─ index.html              # 시계 UI (SVG + JS)
│     ├─ clock.css
│     └─ clock.js
├─ logs/
│  └─ probe-YYYYMMDD.jsonl       # 일별 로그
└─ docs/superpowers/specs/
   └─ 2026-05-01-server-time-cli-design.md  # 이 문서
```

### `run.bat` 동작

```bat
@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "src\probe.ps1"
pause
```

`-ExecutionPolicy Bypass`는 이 호출 한정. 시스템 정책 변경 안 함.

### `probe.ps1` 메인 루프

```
1. PowerShell 버전 확인 (5.1 이상 필수, 미만이면 안내 후 종료)
2. Monotonic anchor 설정 (§4.0)
3. 대상 서버 100회 샘플링 → offsetMs 계산 (§4.3)
4. NTP 1회 점검 (정보 표시용, 실패해도 계속 진행) → ntpInfoMs
5. HttpListener 시작 (127.0.0.1:8765, 점유 중이면 8766...)
6. 기본 브라우저 자동 오픈 (Start-Process "http://127.0.0.1:8765")
7. 타이머 시작:
   - 측정 타이머 (60초)
   - NTP 정보 타이머 (600초, 실패해도 무시)
8. Ctrl+C 핸들러 등록 ([Console]::CancelKeyPress)
9. 메인 스레드: HttpListener.GetContext() 블로킹 루프
10. 종료 시 graceful shutdown:
    - 타이머 Dispose
    - HttpListener Stop + Close
    - 진행 중 측정 완료 대기 (max 10s)
    - 로그 flush
```

PowerShell 5.1은 Windows 10/11 기본 탑재라 별도 설치 불필요. NTP는 정보 표시 전용이라 실패해도 도구 정확도 영향 0 (PC방 등 UDP 123 차단 환경 대비).

---

## 4. 측정 코어 알고리즘

### 4.0 Monotonic Anchor (PC 시계 점프 방어)

**핵심 통찰**: PC 시계의 절대 오프셋은 표시값에 영향을 주지 않는다. 측정 시점에 음수로 박혔다가 표시 시점에 양수로 더해져 자동 상쇄됨. 단, **두 시점 사이에 PC 시계가 점프하면 그 점프량만큼 어긋남**. 윈도우 NTP 동기화, 사용자 수동 시각 변경, 타임존 변경 등이 점프 원인.

대응: 시작 시 anchor 1회 설정, 이후 모든 PC 시각 계산은 monotonic 진행으로:

```
프로그램 시작 시:
  anchor.utc = [DateTime]::UtcNow
  anchor.sw  = [Stopwatch]::GetTimestamp()
  anchor.freq = [Stopwatch]::Frequency

이후 어디서든 "현재 PC 시각" 계산:
  function PcUtcNow():
    elapsedMs = (Stopwatch.GetTimestamp() - anchor.sw) / anchor.freq * 1000
    return anchor.utc.AddMilliseconds(elapsedMs)
```

`[DateTime]::UtcNow`는 측정·표시 어디서도 직접 쓰지 않는다. anchor 설정 시 1회만.

### 4.1 단일 샘플 (HEAD 요청)

```
샘플링 절차:
  t1 = [Stopwatch]::GetTimestamp()              # monotonic
  HEAD http://den08.inames.kr/  with timeout 5s
  t2 = [Stopwatch]::GetTimestamp()
  Ts = ParseDate(response.Headers["Date"])      # 정수 초 UTC

  rttMs      = (t2 - t1) / Stopwatch.Frequency * 1000
  serverAtT2 = Ts + rttMs/2 + 500ms             # 양자화 보정
  pcAtT2     = PcUtcNow_at(t2)                  # §4.0 함수, anchor 기반
  offsetMs   = (serverAtT2 - pcAtT2).TotalMilliseconds
```

PC 시계가 진짜 시각보다 ±X 어긋나 있어도 `pcAtT2`도 ±X만큼 어긋나서 `offsetMs`에 반대로 박힘. 표시 시 `PcUtcNow() + offsetMs`로 합쳐 자동 상쇄. anchor + Stopwatch라 도중 점프와도 무관.

### 4.2 다중 샘플링

- 100회 샘플, 100ms 간격
- 매 요청 새 TCP 핸드셰이크 (대상이 `Connection: close` 강제)
- 샘플별 `(rttMs, offsetMs)` 저장

### 4.3 필터링 + 중앙값

```
sorted = samples sorted by rttMs ascending
top10  = sorted[0..9]                # 하위 10%
result = median(top10.offsetMs)
```

중앙값 채택 이유: outlier에 강건. (성능 예상.md 참조: 균등분포 단독이면 평균이 3배 효율이지만 실 분포엔 RTT 스파이크가 섞여 중앙값이 안전.)

### 4.4 신뢰구간 산출

채택된 10개 샘플의 잔차로 σ 추정:

```
residuals    = top10.offsetMs - median
sigmaSample  = stddev(residuals, Bessel)        # n-1로 나눔
sigmaMedian  ≈ sigmaSample / sqrt(10)           # 단순 근사
ci95         = ±2.262 * sigmaSample / sqrt(10)  # t분포 df=9
```

균등분포·소표본이라 닫힌 형식 점근 공식은 정확하지 않음. t분포(df=9, 95% 양측 = 2.262)로 보수적인 근사 사용. 실측 데이터 누적되면 부트스트랩으로 교체 검토.

UI에 `±42ms` 형태로 표시.

### 4.5 사용자에게 노출되는 시각

```
displayedServerTimeMs(now) = PcUtcNow().ms + offsetMs       # §4.0 anchor 기반
표시 = displayedServerTimeMs(now) → 한국시간(KST)으로 포맷
```

NTP skew는 보정에 쓰지 않는다. PC 시계 절대 오프셋은 자동 상쇄되므로 필요 없음.

브라우저는 `performance.now()` 보간으로 60fps 갱신.

---

## 5. UI 사양 (원형 ms 시계)

### 5.1 시각적 구조 (SVG)

```
       ┌────────────────────────────┐
       │       den08.inames.kr      │   ← 호스트명 (회색 작은 글씨)
       │                            │
       │      ╭──────────────╮      │
       │    ·                 ·     │   ← 외곽: 1초당 한 바퀴 ms 게이지
       │   ·                   ·    │     · = 시간 표식 (5° 간격)
       │  ·    13:28:30.456    ·   │   ← 중앙 시각, "30"과 ms는 강조 색
       │  ·    2026.5.1. 금요일  ·   │   ← 날짜
       │   ·                   ·    │
       │    ·                 ·     │
       │      ╰──────●───────╯      │   ← 진행 마커 (현재 ms 위치)
       │                            │
       │   측정: 5초 전  RTT 65ms    │   ← 작은 통계
       │   ±42ms                     │
       │   참고: PC 시계 +12ms        │   ← NTP 정보 (회색, 부가)
       └────────────────────────────┘
```

### 5.2 외곽 진행 게이지

- 원호: 0° (12시 방향) ~ 360° (다시 12시)
- `progress = (ms_in_second / 1000)` → 매 초 0→1 반복
- SVG `stroke-dasharray` + `stroke-dashoffset`로 구현
- 16ms마다 (`requestAnimationFrame`) 갱신

### 5.3 색상 / 강조 규칙

- 평상시: 시·분은 검정, 초와 ms는 강조 색 (네이버 풍 녹색 — `#03C75A`)
- 측정 실패 (직전 성공 측정 후 5분 경과): 외곽 게이지 회색 + "측정 실패" 배너
- NTP 정보: 회색 작은 글씨로 부가 표시. 차단·실패 시 그 줄 자체를 숨김 (경고 아님). PC 시계가 표시값에 영향 안 주므로 빨간 경고 불필요.

### 5.4 폴링 vs SSE

폴링(1Hz)으로 시작. SSE는 ms 갱신용으로 의미 없음 (브라우저는 보간).

```
GET /api/state →
{
  "host":              "den08.inames.kr",
  "offsetMs":          -847.3,
  "lastMeasureAt":     "2026-05-01T13:28:25.123Z",   # anchor 기반 PcUtcNow
  "rttMedianMs":       65.2,
  "sigmaMs":           21.3,
  "ci95Ms":            41.7,
  "status":            "ok",                          # measuring | ok | failed | stale
  "pcSendTimeAtMs":    1746104910156,                 # PcUtcNow ms (보간 기준점)
  "ntpInfo": {                                         # null이면 NTP 차단/미실시
    "skewMs": 12.4,                                   # PC 시계 - NTP. 정보 표시용, 보정엔 미사용
    "rttMs":  18.5,
    "at":     "2026-05-01T13:20:00.000Z"
  }
}
```

### 5.5 클라이언트 보간

```js
// 응답 받음
const t0_pc = performance.now();
const serverMsAtT0 = pcSendTimeAtMs + offsetMs + (clientReceiveLagEstimate=0);

function nowEstimateMs() {
  return serverMsAtT0 + (performance.now() - t0_pc);
}

// 16ms마다 nowEstimateMs() → HH:MM:SS.mmm 갱신
```

응답 RTT가 ms 보간 정확도에 영향을 주지만 같은 PC 내 localhost라 < 1ms 수준.

---

## 6. 프로세스 / 데이터 흐름

### 6.1 동시성 모델

**채택**: 메인 스레드 + `System.Threading.Timer` 2개. PowerShell 5.1 / 7.x 모두 호환되고 외부 의존성 0.

- 메인 스레드: `HttpListener.GetContext()` 블로킹 루프 (요청 처리)
- 측정 타이머: 60초 주기 → ThreadPool에서 콜백 실행 → 100회 샘플링 → 상태 갱신
- NTP 타이머: 600초 주기 → ThreadPool에서 콜백 → NTP 점검 → 상태 갱신

상태 공유:

```
$script:State = [hashtable]::Synchronized(@{
    OffsetMs       = 0.0
    LastMeasureAt  = $null         # PcUtcNow 기준 (anchor 기반)
    RttMedianMs    = 0.0
    SigmaMs        = 0.0
    Ci95Ms         = 0.0
    Status         = 'measuring'   # measuring | ok | failed | stale
    NtpInfo        = $null         # @{ SkewMs; RttMs; At } 또는 null(미실시·차단)
})

$script:Anchor = @{                # §4.0 monotonic anchor, 시작 시 1회 설정
    Utc  = [DateTime]::UtcNow
    Sw   = [Stopwatch]::GetTimestamp()
    Freq = [Stopwatch]::Frequency
}
```

`[hashtable]::Synchronized()`로 thread-safe 보장. 단일 hashtable이라 단순 lock으로 충분 (ReaderWriterLockSlim 불필요).

기각: `Start-ThreadJob`은 PS 7+ 또는 별도 모듈, `Start-Job`은 별도 프로세스 spawn으로 무거움.

### 6.2 측정 워커 의사코드

타이머 콜백 (60초마다 ThreadPool에서 실행):

```
on tick:
  if (script:State.Status == 'measuring') return  # 이전 측정 진행 중이면 skip
  SetStatus('measuring')
  try:
    samples = []
    for i in 0..99:                       # 시작 시 + 매 1분마다 동일하게 100회
      sample = MeasureOnce(targetUrl, timeout=5s)
      samples.add(sample)
      Sleep 100ms                         # 100회 × 100ms = 10초 분산
    result = ComputeOffset(samples)       # §4.3
    UpdateState(result, status='ok')
    LogJsonl(result)
  catch:
    SetStatus('failed')
    LogError()
  finally:
    if (LastMeasureAt + 5min < now) SetStatus('stale')
```

대상 서버 부담: 1분 중 10초 동안 100요청 = 평균 1.67 req/s. 사용자 세션이 ~2시간이면 총 ~12,000 요청. 일반 웹사이트 트래픽에 비하면 무시할 수준.

### 6.3 NTP 정보 워커 (정보 표시 전용)

```
on tick:                                        # 시작 시 1회 + 600초 주기
  try:
    ntpResp = QueryNtp('time.kriss.re.kr', timeout=3s)
    skewMs  = (ntpResp.ServerTime - PcUtcNow()).TotalMilliseconds
    State.NtpInfo = @{ SkewMs=skewMs; RttMs=ntpResp.RttMs; At=PcUtcNow() }
    LogJsonl(ev='ntp', skew=skewMs)
  catch:
    State.NtpInfo = $null                       # UI에서 자동 숨김
    LogJsonl(ev='ntp_failed', reason=...)       # 1회만 (스팸 방지)
```

표시 정보 전용. 차단·실패해도 측정 워커·표시값에 영향 0. UDP 123 막힌 PC방에서도 도구는 정상 동작. NTP는 `[System.Net.Sockets.UdpClient]`로 48바이트 패킷 직접 송수신 (§7).

---

## 7. NTP 정보 측정 (구체)

**역할**: PC 시계가 표준시 대비 얼마나 어긋나 있는지 사용자에게 보여주는 부가 정보. 측정값 보정엔 쓰지 않음 (§4 자동 상쇄). 차단·실패 시 도구 정상 동작.

### 패킷 구조 (RFC 5905)

NTP v3 클라이언트 요청:
- 첫 바이트(LI/VN/Mode): `0x1B` (LI=0, VN=3, Mode=3 client)
- 나머지 47바이트: 0
- 응답에서 사용:
  - 바이트 0의 Stratum 비트 → 16이면 Unsync, 결과 무시
  - 바이트 0의 Mode → 4(Server)가 아니면 무시
  - 바이트 40~47: Transmit Timestamp (초 32비트 + 분수 32비트, **빅엔디안**)

### 의사코드 (구현 시 검증·예외처리 보강)

```powershell
$bytes = New-Object byte[] 48
$bytes[0] = 0x1B
$udp = New-Object Net.Sockets.UdpClient
$udp.Client.ReceiveTimeout = 3000
$udp.Connect('time.kriss.re.kr', 123)
$t1 = [Stopwatch]::GetTimestamp()
$udp.Send($bytes, 48) | Out-Null
$ep   = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0)
$resp = $udp.Receive([ref]$ep)
$t2 = [Stopwatch]::GetTimestamp()

# 응답 검증
$mode    = $resp[0] -band 0x07
$stratum = $resp[1]
if ($mode -ne 4)        { throw 'NTP: not a server response' }
if ($stratum -eq 0 -or $stratum -ge 16) { throw 'NTP: stratum unsync/invalid' }

# 바이트 40~47: Transmit Timestamp (빅엔디안)
# PowerShell의 `[BitConverter]`는 리틀엔디안이라 인덱스를 역순([43..40])으로 슬라이스해 변환
$secs = [BitConverter]::ToUInt32($resp[43..40], 0)
$frac = [BitConverter]::ToUInt32($resp[47..44], 0)
$ntpUtc = (Get-Date '1900-01-01Z').AddSeconds($secs).AddMilliseconds($frac/0x100000000 * 1000)

$rttMs      = ($t2 - $t1) / [Stopwatch]::Frequency * 1000
$serverAtT2 = $ntpUtc.AddMilliseconds($rttMs / 2)
$skewMs     = ($serverAtT2 - (PcUtcNow)).TotalMilliseconds   # anchor 기반 함수, §4.0
```

PowerShell의 음수 범위 슬라이스 `$arr[N..M]` (N>M)는 역순 추출이 정상 동작 — 빅엔디안 → 리틀엔디안 뒤집기 트릭으로 사용.

---

## 8. 로깅 (JSONL 24h)

```
logs/probe-2026-05-01.jsonl
{"ts":"2026-05-01T04:28:25.456Z","ev":"measure","host":"den08.inames.kr","offsetMs":-847.3,"sigmaMs":21.3,"rttMedianMs":65.2,"sampleCount":100,"acceptedCount":10}
{"ts":"2026-05-01T04:38:25.789Z","ev":"ntp","skewMs":12.4,"rttMs":18.5}
{"ts":"2026-05-01T04:39:25.000Z","ev":"measure_failed","reason":"timeout"}
```

자정 지나면 새 파일 생성. 25일 이전 파일 자동 삭제(시작 시 1회 정리).

---

## 9. 에러 / 상태 처리

| 상태 | 트리거 | UI 표시 |
|---|---|---|
| `measuring` | 시작 직후 ~10초간 (100회 샘플링 진행) | 외곽 게이지 회색, "측정 중..." |
| `ok` | 정상 측정 후 | 평상시 |
| `failed` | 측정 실패 1회 | 외곽 게이지 회색, "측정 실패 (재시도 1분 후)" |
| `stale` | 마지막 성공 측정 5분 초과 | 외곽 빨강, "오프셋 오래됨" |

NTP 정보는 별도 영역(부가 표시)이라 status에 안 들어감. NTP 차단·실패 시 그 줄만 숨김.

`failed` 상태에서도 직전 오프셋으로 표시 계속 (사용자가 갑자기 시계 멈추면 더 혼란).

---

## 10. 보안

PC 단독 실행이라 표면이 작지만 짚어야 할 것:

- **HttpListener는 `127.0.0.1:8765`에만 바인드.** `+:8765` 또는 `*:8765`로 열면 LAN 노출. 명시적으로 `http://127.0.0.1:8765/` URL prefix 사용.
- **포트 충돌**: 8765 점유 중이면 8766, 8767... 순차 시도. 결정한 포트는 콘솔 + 브라우저 자동 오픈에 반영.
- **호스트는 코드에 하드코딩**. 사용자 입력 없으니 SSRF 표면 0. 향후 다중 호스트 추가 시에는 화이트리스트 방식.
- **NTP 응답 검증**: Stratum 16(Unsync)이면 결과 무시. Mode 4(Server) 아니면 무시. 잘못된 서버에서 위조된 시각 받지 않도록.
- **로그에 IP/개인정보 없음**. 그래도 logs/는 `.gitignore`에 추가.
- **User-Agent 명시**: `ServerTimeProbe/1.0 (personal-use)` — 차단 회피 + 매너.
- **방화벽**: HttpListener가 처음 실행될 때 Windows Defender 방화벽이 묻지 않도록 `127.0.0.1` 바인드는 통상 프롬프트 안 뜸. 만약 뜨면 "사적 네트워크" 거부 안내.

---

## 11. 단계별 구현 순서

CLAUDE.md의 단계별 가이드를 PC 버전으로 재구성.

| 단계 | 산출물 | 검증 |
|---|---|---|
| **0. 기반** | `run.bat`, `probe.ps1` 빈 스켈레톤, PS 버전 체크 | 더블클릭 → "Hello" 출력 |
| **1. Anchor + 단일 측정** | §4.0 anchor 함수, HEAD 1회 → Date 파싱 → 콘솔 | 손목시계와 ±2초 일치, PC 시계 변경해도 anchor 영향 없음 |
| **2. 다중 샘플링** | 100회 + 필터 + 중앙값 + 양자화 보정 + 신뢰구간 | `time.is`와 ±50ms 일치 |
| **3. HTTP 서버** | `127.0.0.1:8765/api/state` JSON 응답 (NtpInfo=null) | 브라우저 직접 접속 시 JSON 표시 |
| **4. 정적 UI (수치만)** | HTML 1Hz 폴링 → 텍스트로 시각 표시 + performance.now 보간 | 시각이 매끄럽게 흐름 |
| **5. SVG 원형 시계** | `clock.js`의 ms 게이지, requestAnimationFrame | 60fps 매끄러운 회전 |
| **6. 백그라운드 재측정** | 1분 타이머, 상태 갱신 | 2시간 켜두고 드리프트 없는지 |
| **7. 에러/상태 표시** | `failed`, `stale` 분기 | 인터넷 끊고 5분 → "오프셋 오래됨" |
| **8. NTP 정보 (선택 부가)** | `ntp.ps1`, 시작 + 10분 주기, 실패 시 NtpInfo=null | UI에 "PC 시계 +Xms" 표시. UDP 막은 환경에서 도구 정상 동작 |
| **9. JSONL 로그 + 롤링** | logs/ 일별 파일, 25일 후 정리 | 자정 넘기면 새 파일 |
| **10. Graceful shutdown** | Ctrl+C 핸들러, 타이머 Dispose, HttpListener 정리, 진행 중 측정 대기 | Ctrl+C → 즉시 종료 안 되고 정리 후 종료 |
| **11. 마무리** | README, 브라우저 자동 오픈, 24h 안정성 검증 | 더블클릭 → 브라우저까지 한 번에 |

각 단계 끝나고 동작 확인 후 다음으로. 한 번에 다 짜지 말 것 (CLAUDE.md 지침).

---

## 12. 검증 방법

1. **time.is**: 브라우저 두 탭에 우리 시계 + time.is 띄워놓고 육안 비교. ±50ms 안이면 합격.
2. **NTP 정보 sanity**: `w32tm /stripchart /computer:time.kriss.re.kr /samples:5`의 skew와 우리 도구 `ntpInfo.skewMs`가 ±10ms 일치해야 (NTP 측정 자체 정확도 확인용. 이 값은 표시값에 영향 안 줌).
3. **PC 시계 변조 테스트**: 도구 실행 중 윈도우 시계를 +30초 강제 변경 → 표시값이 그대로 유지돼야 (anchor + Stopwatch 효과 검증).
4. **장기 안정성**: 2시간 켜두고 1분마다 재측정한 offsetMs의 변동 표준편차가 < 30ms.
5. **JSONL 로그 분석**: `acceptedCount==10`, `sigmaMs < 30` 일관 유지.

---

## 13. 미해결 / v2

- **에지 검출 (CLAUDE.md §3)**: Date 헤더가 `:00` → `:01`로 바뀌는 순간 포착해 ms 정밀도 오프셋 추출. 현재는 양자화 보정으로 평균만 맞추는 단계. 추후 `sigmaMs`를 추가로 줄이려면 도입.
- **다중 호스트 동시 표시**: 현재 단일 호스트 하드코딩. v2에서 `config.json`으로 분리 + 탭 UI.
- **알림**: 특정 시각 도달 시 시스템 알림(`[System.Windows.Forms.NotifyIcon]`). 티케팅 카운트다운 용도. v2 후보.
- **윈도우 자동 시작**: 부팅 시 자동 실행은 사용자가 원하면 작업 스케줄러로 별도 등록 (이 도구가 등록하지 않음 — 권한 문제 회피).

---

## 14. 의사결정 요약

| 결정 | 채택 | 폐기 |
|---|---|---|
| 배포 형태 | `.bat + .ps1` | NAS Docker, .exe pkg, Go |
| UI | 로컬 HTML + 브라우저 | WPF, WinForms, 터미널 ASCII |
| 캐시 | 메모리(스크립트 변수) | SQLite, Redis |
| 로그 | JSONL 일별 롤링 | SQLite |
| 시계 기준 | Monotonic anchor + Stopwatch | `[DateTime]::UtcNow` 직접 사용 (PC 시계 점프 취약) |
| NTP | 정보 표시 전용 (보정 미사용), 시작 + 10분 주기, 실패 시 숨김 | NTP skew로 표시값 보정 (자동 상쇄로 불필요), NTP 차단 시 빨간 경고 |
| 호스트 | 하드코딩 | 사용자 입력 (SSRF 표면 회피) |
| HTTP 클라이언트 | `Invoke-WebRequest -Method Head` | undici (Node 의존) |
| HTTP 서버 | `[System.Net.HttpListener]` 127.0.0.1 | Express, Fastify |

---

이 doc 기준으로 다음 단계: self-review → 사용자 검토 → `superpowers:writing-plans`로 구현 plan 작성 → 코드.
