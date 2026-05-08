# 서버시간 측정 CLI 구현 Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 대상 호스트 `den08.inames.kr`의 서버 시각을 ±50ms 정확도로 추정해 네이버 시계 스타일 원형 ms UI로 표시하는 PC 단독 실행 CLI 도구 구현.

**Architecture:** `run.bat` → `probe.ps1`이 (1) Monotonic anchor 설정 (2) 대상 서버 100회 샘플링으로 offset 계산 (3) `127.0.0.1:8765` HttpListener 시작 (4) 기본 브라우저 자동 오픈 (5) 1분 주기 측정 타이머 + 10분 주기 NTP 정보 타이머 운영. 브라우저는 1Hz 폴링 + `performance.now()` 보간으로 60fps 표시.

**Tech Stack:** PowerShell 5.1+, .NET `[System.Net.HttpListener]`, `[System.Net.Sockets.UdpClient]`, `[System.Diagnostics.Stopwatch]`, Pester 3.4+ (단위테스트, Win10/11 기본 탑재), HTML/SVG/Vanilla JS.

**Spec:** `docs/superpowers/specs/2026-05-01-server-time-cli-design.md`

---

## File Structure

```
유사 네이비즘 만들기/
├─ run.bat                              # 진입점 (더블클릭)
├─ src/
│  ├─ probe.ps1                         # 메인 오케스트레이션
│  ├─ anchor.ps1                        # Monotonic 시각 함수 (§4.0)
│  ├─ measurement.ps1                   # HEAD 측정 + 알고리즘 (§4.1~4.5)
│  ├─ ntp.ps1                           # NTP 정보 측정 (§7)
│  ├─ http-server.ps1                   # HttpListener (§3, §5.4)
│  ├─ logger.ps1                        # JSONL 로그 (§8)
│  └─ web/
│     ├─ index.html                     # 시계 페이지
│     ├─ clock.css                      # 스타일
│     └─ clock.js                       # SVG 게이지 + 보간
├─ tests/
│  ├─ Anchor.Tests.ps1
│  ├─ Measurement.Tests.ps1
│  └─ Ntp.Tests.ps1
├─ logs/                                # 런타임 생성 (.gitignore)
└─ docs/superpowers/
   ├─ specs/2026-05-01-server-time-cli-design.md
   └─ plans/2026-05-01-server-time-cli.md           # 이 문서
```

**파일 책임 분리 원칙**:
- `anchor.ps1` — `[DateTime]::UtcNow` 직접 호출은 이 파일 안에서만. 다른 모든 모듈은 `Get-PcUtcNow` 함수만 사용
- `measurement.ps1` — 순수 함수 위주(테스트 용이). HEAD 요청만 외부 의존
- `ntp.ps1` — UDP 송수신 캡슐화. 실패해도 다른 모듈에 영향 없게 try/catch로 봉쇄
- `http-server.ps1` — JSON 직렬화·요청 라우팅
- `probe.ps1` — 위 모듈들 dot-source로 로드 후 오케스트레이션만

---

## Task 0: 프로젝트 기반 + 진입점

**Files:**
- Create: `run.bat`
- Create: `src/probe.ps1`
- Create: `.gitignore`

- [ ] **Step 1: `.gitignore` 작성**

```gitignore
logs/
*.log
.vscode/
.idea/
```

- [ ] **Step 2: `run.bat` 작성**

```bat
@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "src\probe.ps1"
echo.
echo [program ended]
pause
```

- [ ] **Step 3: `src/probe.ps1` 빈 스켈레톤 작성**

```powershell
# probe.ps1 - 서버시간 측정 CLI
$ErrorActionPreference = 'Stop'

# PowerShell 버전 체크
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "이 도구는 PowerShell 5.1 이상이 필요합니다." -ForegroundColor Red
    Write-Host "현재 버전: $($PSVersionTable.PSVersion)"
    exit 1
}

Write-Host "Hello from probe.ps1 (PS $($PSVersionTable.PSVersion))"
```

- [ ] **Step 4: 더블클릭 검증**

Run: 탐색기에서 `run.bat` 더블클릭
Expected: 검정 콘솔에 `Hello from probe.ps1 (PS 5.1.x.x)` + `[program ended]` 표시

- [ ] **Step 5: 커밋**

```bash
git add run.bat src/probe.ps1 .gitignore
git commit -m "task 0: 프로젝트 기반 + 진입점 스켈레톤"
```

---

## Task 1: Monotonic Anchor 모듈

**Files:**
- Create: `src/anchor.ps1`
- Create: `tests/Anchor.Tests.ps1`

- [ ] **Step 1: 실패 테스트 작성 — `tests/Anchor.Tests.ps1`**

```powershell
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
```

- [ ] **Step 2: 테스트 실행 (실패 확인)**

Run: `Invoke-Pester tests/Anchor.Tests.ps1`
Expected: FAIL — `anchor.ps1` 또는 함수 미정의

- [ ] **Step 3: `src/anchor.ps1` 구현**

```powershell
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
```

- [ ] **Step 4: 테스트 실행 (통과 확인)**

Run: `Invoke-Pester tests/Anchor.Tests.ps1`
Expected: PASS (3개 테스트)

- [ ] **Step 5: 수동 점프 테스트 (선택)**

도구 실행 중 시계 변경 시뮬레이션은 단위테스트로 어려움. probe.ps1 통합 후 §12.3 검증으로 확인.

- [ ] **Step 6: 커밋**

```bash
git add src/anchor.ps1 tests/Anchor.Tests.ps1
git commit -m "task 1: monotonic anchor 모듈 + 단위테스트"
```

---

## Task 2-A: 단일 측정 (HEAD 요청 + Date 파싱)

**Files:**
- Create: `src/measurement.ps1`
- Create: `tests/Measurement.Tests.ps1`

- [ ] **Step 1: 순수 함수 테스트 작성**

```powershell
. "$PSScriptRoot\..\src\measurement.ps1"

Describe 'Measurement pure functions' {
    It 'ConvertTo-DateMs parses RFC 1123 Date header' {
        $ms = ConvertTo-DateMs 'Thu, 30 Apr 2026 18:27:26 GMT'
        $expected = [DateTime]::new(2026,4,30,18,27,26,[DateTimeKind]::Utc)
        $actual = [DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc).AddMilliseconds($ms)
        $actual | Should Be $expected
    }

    It 'Get-OffsetMs computes Cristian offset with quantization correction' {
        # Ts = 서버 Date 헤더 ms (정수 초)
        # rttMs = 60
        # pcAtT2 = 임의값
        # 기대값: (Ts + 30 + 500) - pcAtT2
        $tsMs = 1000000000000  # 임의 ms
        $rttMs = 60
        $pcAtT2Ms = 999999999500
        $offset = Get-OffsetMs -ServerDateMs $tsMs -RttMs $rttMs -PcAtT2Ms $pcAtT2Ms
        $expected = ($tsMs + 30 + 500) - $pcAtT2Ms  # 1030
        $offset | Should Be $expected
    }
}
```

- [ ] **Step 2: 테스트 실행 (실패 확인)**

Run: `Invoke-Pester tests/Measurement.Tests.ps1`
Expected: FAIL — 함수 미정의

- [ ] **Step 3: 순수 함수 구현 in `src/measurement.ps1`**

```powershell
# measurement.ps1 - 측정 알고리즘 (§4)
. "$PSScriptRoot\anchor.ps1"

function ConvertTo-DateMs {
    param([Parameter(Mandatory)][string]$DateHeader)
    # RFC 1123: 'Thu, 30 Apr 2026 18:27:26 GMT'
    $dt = [DateTime]::ParseExact(
        $DateHeader,
        'ddd, dd MMM yyyy HH:mm:ss \G\M\T',
        [System.Globalization.CultureInfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::AssumeUniversal -bor `
            [System.Globalization.DateTimeStyles]::AdjustToUniversal
    )
    $epoch = [DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)
    return ($dt - $epoch).TotalMilliseconds
}

function Get-OffsetMs {
    param(
        [Parameter(Mandatory)][double]$ServerDateMs,
        [Parameter(Mandatory)][double]$RttMs,
        [Parameter(Mandatory)][double]$PcAtT2Ms
    )
    # §4.1: serverAtT2 = Ts + RTT/2 + 500ms (양자화 보정)
    # offsetMs = serverAtT2 - pcAtT2
    return ($ServerDateMs + $RttMs / 2 + 500) - $PcAtT2Ms
}
```

- [ ] **Step 4: 테스트 실행 (통과 확인)**

Run: `Invoke-Pester tests/Measurement.Tests.ps1`
Expected: PASS

- [ ] **Step 5: HEAD 요청 함수 추가 (네트워크 의존, 통합테스트로만)**

`src/measurement.ps1`에 추가:

```powershell
function Invoke-HeadProbe {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$TimeoutSec = 5
    )
    $t1 = [System.Diagnostics.Stopwatch]::GetTimestamp()
    try {
        $resp = Invoke-WebRequest `
            -Uri $Url `
            -Method Head `
            -TimeoutSec $TimeoutSec `
            -UseBasicParsing `
            -UserAgent 'ServerTimeProbe/1.0 (personal-use)' `
            -Headers @{ 'Connection' = 'close' }
    } catch {
        throw "HEAD failed: $_"
    }
    $t2 = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $pcAtT2 = Get-PcUtcNow

    $dateHdr = $resp.Headers.Date
    if (-not $dateHdr) { throw 'Date header missing' }

    $rttMs = ($t2 - $t1) / [System.Diagnostics.Stopwatch]::Frequency * 1000
    $serverDateMs = ConvertTo-DateMs $dateHdr
    $epoch = [DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)
    $pcAtT2Ms = ($pcAtT2 - $epoch).TotalMilliseconds
    $offsetMs = Get-OffsetMs -ServerDateMs $serverDateMs -RttMs $rttMs -PcAtT2Ms $pcAtT2Ms

    return [PSCustomObject]@{
        RttMs    = $rttMs
        OffsetMs = $offsetMs
        DateHdr  = $dateHdr
    }
}
```

- [ ] **Step 6: probe.ps1에서 단일 측정 호출 (수동 검증)**

`src/probe.ps1` 갱신:

```powershell
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\anchor.ps1"
. "$PSScriptRoot\measurement.ps1"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "PowerShell 5.1 이상 필요" -ForegroundColor Red; exit 1
}

Initialize-Anchor

$result = Invoke-HeadProbe -Url 'http://den08.inames.kr/'
Write-Host "RTT: $([Math]::Round($result.RttMs,1))ms"
Write-Host "Date 헤더: $($result.DateHdr)"
Write-Host "Offset: $([Math]::Round($result.OffsetMs,1))ms"
$serverNow = (Get-PcUtcNow).AddMilliseconds($result.OffsetMs).ToLocalTime()
Write-Host "추정 서버 시각: $($serverNow.ToString('yyyy-MM-dd HH:mm:ss.fff'))"
```

- [ ] **Step 7: 더블클릭 검증**

Run: `run.bat` 더블클릭
Expected: 추정 서버 시각이 손목시계와 ±2초 일치

- [ ] **Step 8: 커밋**

```bash
git add src/measurement.ps1 src/probe.ps1 tests/Measurement.Tests.ps1
git commit -m "task 2-A: HEAD 단일 측정 + Cristian + 양자화 보정"
```

---

## Task 2-B: 다중 샘플링 + RTT 필터 + 중앙값 + 신뢰구간

**Files:**
- Modify: `src/measurement.ps1`
- Modify: `tests/Measurement.Tests.ps1`
- Modify: `src/probe.ps1`

- [ ] **Step 1: 알고리즘 단위테스트 추가**

`tests/Measurement.Tests.ps1` 끝에 추가:

```powershell
Describe 'Sample reduction algorithm' {
    It 'Get-Median returns middle value for odd count' {
        Get-Median @(1,3,5,7,9) | Should Be 5
    }
    It 'Get-Median averages two middle for even count' {
        Get-Median @(1,2,3,4) | Should Be 2.5
    }
    It 'Select-LowestRtt picks bottom 10 of 100' {
        $samples = 1..100 | ForEach-Object {
            [PSCustomObject]@{ RttMs = $_; OffsetMs = $_ * 10 }
        }
        $top = Select-LowestRtt -Samples $samples -PercentBottom 10
        $top.Count | Should Be 10
        ($top | Measure-Object -Property RttMs -Maximum).Maximum | Should Be 10
    }
    It 'Get-StdDev computes Bessel-corrected stddev' {
        # values 2,4,4,4,5,5,7,9 — known stddev(sample) = 2.138...
        $sd = Get-StdDev @(2,4,4,4,5,5,7,9)
        [Math]::Round($sd,3) | Should Be 2.138
    }
    It 'Reduce-Samples combines filter + median + sigma + ci95' {
        $samples = 1..100 | ForEach-Object {
            [PSCustomObject]@{ RttMs = $_; OffsetMs = 1000 + ($_ % 7) * 3 }
        }
        $r = Reduce-Samples -Samples $samples
        $r.AcceptedCount | Should Be 10
        $r.OffsetMs | Should Not BeNullOrEmpty
        $r.Ci95Ms | Should BeGreaterThan 0
    }
}
```

- [ ] **Step 2: 테스트 실행 (실패 확인)**

Run: `Invoke-Pester tests/Measurement.Tests.ps1`
Expected: FAIL — 새 함수들 미정의

- [ ] **Step 3: `src/measurement.ps1`에 알고리즘 함수 추가**

```powershell
function Get-Median {
    param([Parameter(Mandatory)][double[]]$Values)
    $sorted = $Values | Sort-Object
    $n = $sorted.Count
    if ($n -eq 0) { throw 'Empty array' }
    if ($n % 2 -eq 1) { return [double]$sorted[[int]($n/2)] }
    return ([double]$sorted[$n/2 - 1] + [double]$sorted[$n/2]) / 2.0
}

function Get-StdDev {
    param([Parameter(Mandatory)][double[]]$Values)
    $n = $Values.Count
    if ($n -lt 2) { return 0.0 }
    $mean = ($Values | Measure-Object -Average).Average
    $sumSq = 0.0
    foreach ($v in $Values) { $sumSq += [Math]::Pow($v - $mean, 2) }
    return [Math]::Sqrt($sumSq / ($n - 1))   # Bessel
}

function Select-LowestRtt {
    param(
        [Parameter(Mandatory)]$Samples,
        [int]$PercentBottom = 10
    )
    $count = [Math]::Max(1, [Math]::Floor($Samples.Count * $PercentBottom / 100))
    return $Samples | Sort-Object RttMs | Select-Object -First $count
}

function Reduce-Samples {
    param([Parameter(Mandatory)]$Samples)
    $top = Select-LowestRtt -Samples $Samples -PercentBottom 10
    $offsets = $top | ForEach-Object { [double]$_.OffsetMs }
    $median = Get-Median -Values $offsets
    $sigma  = Get-StdDev -Values $offsets
    $n = $top.Count
    # t분포 df=n-1, 95% 양측. 디자인 doc §4.4에서 n=10 → 2.262
    $tValue = if ($n -eq 10) { 2.262 } elseif ($n -ge 30) { 1.96 } else { 2.262 }
    $ci95 = $tValue * $sigma / [Math]::Sqrt($n)
    $rttMedian = Get-Median -Values ($top | ForEach-Object { [double]$_.RttMs })

    return [PSCustomObject]@{
        OffsetMs       = $median
        SigmaMs        = $sigma
        Ci95Ms         = $ci95
        RttMedianMs    = $rttMedian
        SampleCount    = $Samples.Count
        AcceptedCount  = $n
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `Invoke-Pester tests/Measurement.Tests.ps1`
Expected: PASS (모든 테스트)

- [ ] **Step 5: 100회 샘플링 함수 추가 in `src/measurement.ps1`**

```powershell
function Invoke-MultiSample {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$Count = 100,
        [int]$IntervalMs = 100
    )
    $samples = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Count; $i++) {
        try {
            $s = Invoke-HeadProbe -Url $Url
            [void]$samples.Add($s)
        } catch {
            # 개별 실패 허용. 50% 이상 실패 시 상위 함수에서 throw
        }
        if ($i -lt $Count - 1) { Start-Sleep -Milliseconds $IntervalMs }
    }
    if ($samples.Count -lt [int]($Count * 0.5)) {
        throw "Too many failed samples: $($samples.Count)/$Count"
    }
    return Reduce-Samples -Samples $samples
}
```

- [ ] **Step 6: probe.ps1을 100회 측정으로 변경**

`src/probe.ps1`을 다음으로 교체:

```powershell
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\anchor.ps1"
. "$PSScriptRoot\measurement.ps1"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "PowerShell 5.1 이상 필요" -ForegroundColor Red; exit 1
}

Initialize-Anchor

$url = 'http://den08.inames.kr/'
Write-Host "초기 측정 (100샘플 × 100ms = ~10초)..."
$result = Invoke-MultiSample -Url $url -Count 100 -IntervalMs 100

Write-Host ""
Write-Host "오프셋: $([Math]::Round($result.OffsetMs,1)) ms"
Write-Host "RTT median: $([Math]::Round($result.RttMedianMs,1)) ms"
Write-Host "σ: $([Math]::Round($result.SigmaMs,1)) ms,  95% CI: ±$([Math]::Round($result.Ci95Ms,1)) ms"
Write-Host "채택: $($result.AcceptedCount)/$($result.SampleCount)"

$serverNow = (Get-PcUtcNow).AddMilliseconds($result.OffsetMs).ToLocalTime()
Write-Host ""
Write-Host "추정 서버 시각: $($serverNow.ToString('yyyy-MM-dd HH:mm:ss.fff'))" -ForegroundColor Green
```

- [ ] **Step 7: 더블클릭 검증**

Run: `run.bat`
Expected: ~10초 후 서버 시각 표시. `time.is`와 비교 시 ±50ms 일치.

- [ ] **Step 8: 커밋**

```bash
git add src/measurement.ps1 src/probe.ps1 tests/Measurement.Tests.ps1
git commit -m "task 2-B: 다중 샘플링 + RTT 필터 + 중앙값 + 신뢰구간"
```

---

## Task 3: HTTP 서버 (HttpListener)

**Files:**
- Create: `src/http-server.ps1`
- Modify: `src/probe.ps1`

- [ ] **Step 1: `src/http-server.ps1` 작성**

```powershell
# http-server.ps1 - 127.0.0.1 전용 HttpListener
. "$PSScriptRoot\anchor.ps1"

function New-StateStore {
    return [hashtable]::Synchronized(@{
        Host          = ''
        OffsetMs      = 0.0
        LastMeasureAt = $null
        RttMedianMs   = 0.0
        SigmaMs       = 0.0
        Ci95Ms        = 0.0
        Status        = 'measuring'
        NtpInfo       = $null
    })
}

function Start-LocalHttpServer {
    param(
        [Parameter(Mandatory)]$State,
        [int]$PreferPort = 8765,
        [Parameter(Mandatory)][string]$WebRoot
    )
    # 포트 충돌 시 +1씩 시도 (최대 10)
    $listener = $null
    $port = $PreferPort
    for ($i = 0; $i -lt 10; $i++) {
        try {
            $listener = New-Object System.Net.HttpListener
            $listener.Prefixes.Add("http://127.0.0.1:$port/")
            $listener.Start()
            break
        } catch {
            $listener = $null
            $port++
        }
    }
    if ($null -eq $listener) { throw "Failed to bind any port in $PreferPort..$($PreferPort+9)" }

    Write-Host "HTTP 서버: http://127.0.0.1:$port/" -ForegroundColor Cyan

    return @{
        Listener = $listener
        Port     = $port
        Loop     = {
            param($listener, $state, $webRoot)
            while ($listener.IsListening) {
                try {
                    $ctx = $listener.GetContext()  # 블로킹
                    $req = $ctx.Request
                    $resp = $ctx.Response
                    $resp.Headers.Add('Cache-Control', 'no-store')
                    Handle-Request $req $resp $state $webRoot
                    $resp.Close()
                } catch [System.Net.HttpListenerException] {
                    break  # Stop() 호출 시
                } catch {
                    # 개별 요청 실패 무시
                }
            }
        }
    }
}

function Handle-Request {
    param($req, $resp, $state, $webRoot)
    $path = $req.Url.AbsolutePath
    if ($path -eq '/' -or $path -eq '/index.html') {
        Write-StaticFile $resp (Join-Path $webRoot 'index.html') 'text/html; charset=utf-8'
    } elseif ($path -eq '/clock.css') {
        Write-StaticFile $resp (Join-Path $webRoot 'clock.css') 'text/css; charset=utf-8'
    } elseif ($path -eq '/clock.js') {
        Write-StaticFile $resp (Join-Path $webRoot 'clock.js') 'application/javascript; charset=utf-8'
    } elseif ($path -eq '/api/state') {
        Write-StateJson $resp $state
    } else {
        $resp.StatusCode = 404
        $bytes = [Text.Encoding]::UTF8.GetBytes('Not Found')
        $resp.OutputStream.Write($bytes, 0, $bytes.Length)
    }
}

function Write-StaticFile {
    param($resp, [string]$path, [string]$contentType)
    if (-not (Test-Path $path)) {
        $resp.StatusCode = 404
        return
    }
    $bytes = [IO.File]::ReadAllBytes($path)
    $resp.ContentType = $contentType
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-StateJson {
    param($resp, $state)
    $epoch = [DateTime]::new(1970,1,1,0,0,0,[DateTimeKind]::Utc)
    $pcSendTimeAtMs = ((Get-PcUtcNow) - $epoch).TotalMilliseconds

    $payload = @{
        host           = $state.Host
        offsetMs       = $state.OffsetMs
        lastMeasureAt  = if ($state.LastMeasureAt) { $state.LastMeasureAt.ToString('o') } else { $null }
        rttMedianMs    = $state.RttMedianMs
        sigmaMs        = $state.SigmaMs
        ci95Ms         = $state.Ci95Ms
        status         = $state.Status
        pcSendTimeAtMs = $pcSendTimeAtMs
        ntpInfo        = $state.NtpInfo
    }
    $json = $payload | ConvertTo-Json -Depth 5 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $resp.ContentType = 'application/json; charset=utf-8'
    $resp.ContentLength64 = $bytes.Length
    $resp.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Stop-LocalHttpServer {
    param($listener)
    if ($listener -and $listener.IsListening) {
        try { $listener.Stop() } catch {}
        try { $listener.Close() } catch {}
    }
}
```

- [ ] **Step 2: `src/probe.ps1`에 서버 통합**

```powershell
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\anchor.ps1"
. "$PSScriptRoot\measurement.ps1"
. "$PSScriptRoot\http-server.ps1"

if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Host "PowerShell 5.1 이상 필요" -ForegroundColor Red; exit 1
}

Initialize-Anchor

$url = 'http://den08.inames.kr/'
$webRoot = Join-Path $PSScriptRoot 'web'

# 초기 측정
Write-Host "초기 측정 (100샘플)..."
$state = New-StateStore
$state.Host = ([Uri]$url).Host
try {
    $result = Invoke-MultiSample -Url $url -Count 100 -IntervalMs 100
    $state.OffsetMs      = $result.OffsetMs
    $state.RttMedianMs   = $result.RttMedianMs
    $state.SigmaMs       = $result.SigmaMs
    $state.Ci95Ms        = $result.Ci95Ms
    $state.LastMeasureAt = Get-PcUtcNow
    $state.Status        = 'ok'
    Write-Host "초기 오프셋: $([Math]::Round($result.OffsetMs,1)) ms (±$([Math]::Round($result.Ci95Ms,1)))"
} catch {
    Write-Host "초기 측정 실패: $_" -ForegroundColor Red
    $state.Status = 'failed'
}

# HTTP 서버 시작
$server = Start-LocalHttpServer -State $state -PreferPort 8765 -WebRoot $webRoot

Write-Host ""
Write-Host "Ctrl+C로 종료" -ForegroundColor Yellow

try {
    & $server.Loop $server.Listener $state $webRoot
} finally {
    Stop-LocalHttpServer $server.Listener
    Write-Host "서버 종료됨"
}
```

- [ ] **Step 3: 검증**

Run: `run.bat`
브라우저에서 `http://127.0.0.1:8765/api/state` 접속
Expected: JSON 응답 확인 (offsetMs, status:'ok' 등)

- [ ] **Step 4: 다른 PC/모바일에서 LAN IP 접속 시도 (보안 검증)**

같은 Wi-Fi 다른 기기에서 `http://<PC_IP>:8765/api/state` 접속
Expected: 거부 (`127.0.0.1` 바인드라 외부 접근 불가)

- [ ] **Step 5: 커밋**

```bash
git add src/http-server.ps1 src/probe.ps1
git commit -m "task 3: HttpListener (127.0.0.1 only) + /api/state JSON"
```

---

## Task 4: 정적 UI (텍스트 + 보간)

**Files:**
- Create: `src/web/index.html`
- Create: `src/web/clock.css`
- Create: `src/web/clock.js`

- [ ] **Step 1: `src/web/index.html`**

```html
<!doctype html>
<html lang="ko">
<head>
  <meta charset="utf-8">
  <title>서버 시계</title>
  <link rel="stylesheet" href="/clock.css">
</head>
<body>
  <main class="clock-wrapper">
    <div class="host" id="host">측정 중...</div>
    <div class="time" id="time">--:--:--<span class="ms">.---</span></div>
    <div class="date" id="date">----.--.--.</div>
    <div class="stats" id="stats"></div>
    <div class="ntp" id="ntp"></div>
    <div class="status" id="status"></div>
  </main>
  <script src="/clock.js"></script>
</body>
</html>
```

- [ ] **Step 2: `src/web/clock.css`**

```css
:root {
  --accent: #03C75A;
  --gray:   #999;
  --bg:     #fff;
  --text:   #222;
  --warn:   #d33;
}
body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif; background: var(--bg); color: var(--text); }
.clock-wrapper { width: 360px; margin: 60px auto; text-align: center; }
.host { color: var(--gray); font-size: 14px; margin-bottom: 8px; }
.time { font-size: 56px; font-weight: 600; letter-spacing: -2px; }
.time .ms { color: var(--accent); font-size: 56px; font-weight: 600; }
.date { color: var(--gray); font-size: 14px; margin-top: 4px; }
.stats { color: var(--gray); font-size: 12px; margin-top: 24px; }
.ntp   { color: var(--gray); font-size: 11px; margin-top: 4px; }
.status.warn { color: var(--warn); }
```

- [ ] **Step 3: `src/web/clock.js` (보간만, 게이지는 Task 5)**

```js
(function() {
  let baseServerMs = null;     // 응답 받은 시점의 추정 서버 시각 (ms epoch)
  let basePerfMs = null;       // 같은 시점의 performance.now()
  let state = null;

  async function fetchState() {
    try {
      const t0 = performance.now();
      const res = await fetch('/api/state', { cache: 'no-store' });
      const data = await res.json();
      const t1 = performance.now();
      const lag = (t1 - t0) / 2;   // localhost라 < 1ms

      // pcSendTimeAtMs (서버가 응답 보낸 PC 시각 ms) + offsetMs = 그 시점의 추정 서버 시각
      const serverAtSend = data.pcSendTimeAtMs + data.offsetMs;
      // 클라이언트가 받은 시점은 send + lag 후
      baseServerMs = serverAtSend + lag;
      basePerfMs = t1;
      state = data;
      render();
    } catch (e) {
      console.warn('fetchState failed', e);
    }
  }

  function nowEstimateMs() {
    if (baseServerMs == null) return null;
    return baseServerMs + (performance.now() - basePerfMs);
  }

  const KST_OFFSET_MS = 9 * 60 * 60 * 1000;

  function render() {
    const ms = nowEstimateMs();
    if (ms == null) return;
    const kst = new Date(ms + KST_OFFSET_MS);
    // KST 환산 위해 UTC getter 사용
    const hh = String(kst.getUTCHours()).padStart(2, '0');
    const mm = String(kst.getUTCMinutes()).padStart(2, '0');
    const ss = String(kst.getUTCSeconds()).padStart(2, '0');
    const mss = String(kst.getUTCMilliseconds()).padStart(3, '0');
    const yyyy = kst.getUTCFullYear();
    const mo = kst.getUTCMonth() + 1;
    const d = kst.getUTCDate();
    const dayKr = ['일','월','화','수','목','금','토'][kst.getUTCDay()];

    document.getElementById('time').innerHTML = `${hh}:${mm}:${ss}<span class="ms">.${mss}</span>`;
    document.getElementById('date').textContent = `${yyyy}.${mo}.${d}. ${dayKr}요일`;
    document.getElementById('host').textContent = state.host || '';

    // 통계
    const ago = state.lastMeasureAt
      ? Math.round((Date.now() - new Date(state.lastMeasureAt).getTime()) / 1000)
      : '-';
    document.getElementById('stats').textContent =
      `측정: ${ago}초 전  RTT ${Math.round(state.rttMedianMs)}ms  ±${Math.round(state.ci95Ms)}ms`;

    // NTP 정보 (있으면 표시)
    const ntp = document.getElementById('ntp');
    if (state.ntpInfo) {
      const sign = state.ntpInfo.skewMs >= 0 ? '+' : '';
      ntp.textContent = `참고: PC 시계 ${sign}${Math.round(state.ntpInfo.skewMs)}ms`;
    } else {
      ntp.textContent = '';
    }

    // 상태
    const st = document.getElementById('status');
    st.classList.remove('warn');
    if (state.status === 'failed') {
      st.textContent = '측정 실패 (재시도 1분 후)';
      st.classList.add('warn');
    } else if (state.status === 'stale') {
      st.textContent = '오프셋 오래됨';
      st.classList.add('warn');
    } else if (state.status === 'measuring') {
      st.textContent = '측정 중...';
    } else {
      st.textContent = '';
    }
  }

  function loop() {
    render();
    requestAnimationFrame(loop);
  }

  fetchState();
  setInterval(fetchState, 1000);
  loop();
})();
```

- [ ] **Step 4: 검증**

Run: `run.bat`. 브라우저는 자동 오픈 안 되지만 수동으로 `http://127.0.0.1:8765/`
Expected: 시·분·초·ms가 매끄럽게 흐름. `time.is`와 비교 ±50ms.

- [ ] **Step 5: 커밋**

```bash
git add src/web/
git commit -m "task 4: 정적 UI + performance.now 보간"
```

---

## Task 5: SVG 원형 ms 게이지

**Files:**
- Modify: `src/web/index.html`
- Modify: `src/web/clock.css`
- Modify: `src/web/clock.js`

- [ ] **Step 1: `index.html` SVG 추가**

`<main class="clock-wrapper">` 내부를 다음으로 교체:

```html
<div class="host" id="host">측정 중...</div>
<div class="ring-area">
  <svg class="ring" viewBox="0 0 200 200" width="320" height="320">
    <circle class="track"   cx="100" cy="100" r="92" />
    <circle class="progress" cx="100" cy="100" r="92" id="progress"
            transform="rotate(-90 100 100)" />
    <circle class="marker" id="marker" cx="100" cy="8" r="5" />
  </svg>
  <div class="ring-center">
    <div class="time" id="time">--:--:--<span class="ms">.---</span></div>
    <div class="date" id="date">----.--.--.</div>
  </div>
</div>
<div class="stats" id="stats"></div>
<div class="ntp" id="ntp"></div>
<div class="status" id="status"></div>
```

- [ ] **Step 2: `clock.css` 추가**

```css
.ring-area { position: relative; width: 320px; height: 320px; margin: 16px auto 0; }
.ring { display: block; }
.ring .track    { fill: none; stroke: #f0f0f0; stroke-width: 4; }
.ring .progress { fill: none; stroke: var(--accent); stroke-width: 4;
                  stroke-dasharray: 578.05;  /* 2πr ≈ 2π·92 */
                  stroke-dashoffset: 578.05; stroke-linecap: round; }
.ring .marker   { fill: var(--accent); }
.ring-center {
  position: absolute; top: 0; left: 0; width: 100%; height: 100%;
  display: flex; flex-direction: column; align-items: center; justify-content: center;
}
.ring-center .time { font-size: 44px; }
.ring-center .time .ms { font-size: 44px; }
```

- [ ] **Step 3: `clock.js`의 render 함수에 게이지 갱신 추가**

`render()` 함수 끝에 추가:

```js
    // 외곽 게이지: 1초 = 한 바퀴
    const msInSecond = (kst.getUTCMilliseconds()) / 1000;  // 0~1
    const circumference = 2 * Math.PI * 92;
    const offset = circumference * (1 - msInSecond);
    document.getElementById('progress').setAttribute('stroke-dashoffset', offset);

    // 진행 마커: msInSecond에 따라 원주 위 위치
    const angle = msInSecond * 2 * Math.PI - Math.PI / 2;  // -90°에서 시작
    const cx = 100 + 92 * Math.cos(angle);
    const cy = 100 + 92 * Math.sin(angle);
    const m = document.getElementById('marker');
    m.setAttribute('cx', cx);
    m.setAttribute('cy', cy);
```

- [ ] **Step 4: 검증**

Run: `run.bat` + 브라우저
Expected: 외곽 게이지가 1초마다 한 바퀴 매끄럽게 회전, 마커가 원 따라 움직임

- [ ] **Step 5: 커밋**

```bash
git add src/web/
git commit -m "task 5: SVG 원형 ms 게이지 + 마커"
```

---

## Task 6: 백그라운드 1분 재측정 + 브라우저 자동 오픈

**Files:**
- Modify: `src/probe.ps1`

- [ ] **Step 1: 측정 타이머 콜백 추가**

`src/probe.ps1`에서 HTTP 서버 시작 직전에 다음 추가:

```powershell
# 측정 타이머 (60초 주기)
$measureCallback = {
    param($s)
    $url = $s.Host -replace '^', 'http://'
    if ($s.Status -eq 'measuring') { return }
    $s.Status = 'measuring'
    try {
        $r = Invoke-MultiSample -Url "http://$($s.Host)/" -Count 100 -IntervalMs 100
        $s.OffsetMs      = $r.OffsetMs
        $s.RttMedianMs   = $r.RttMedianMs
        $s.SigmaMs       = $r.SigmaMs
        $s.Ci95Ms        = $r.Ci95Ms
        $s.LastMeasureAt = Get-PcUtcNow
        $s.Status        = 'ok'
    } catch {
        $s.Status = 'failed'
    }
}.GetNewClosure()

# 직접 ScriptBlock을 Timer에 못 넘기므로 Register-ObjectEvent 패턴 사용
# 단순화: 별도 스레드 없이 listener loop 옆에서 stopwatch 기반 polling
$lastMeasure = [System.Diagnostics.Stopwatch]::StartNew()
$measureIntervalSec = 60

# Stale 체크 콜백
$staleCheck = {
    param($s)
    if ($s.LastMeasureAt -and ((Get-PcUtcNow) - $s.LastMeasureAt).TotalMinutes -gt 5) {
        if ($s.Status -ne 'measuring') { $s.Status = 'stale' }
    }
}
```

**더 깔끔한 구현**: `[System.Threading.Timer]` 직접 사용. 콜백을 PowerShell ScriptBlock 대신 `[Action[Object]]` delegate로 변환:

```powershell
# 측정 타이머 등록
$measureAction = {
    param($stateObj)
    $s = $stateObj
    if ($s.Status -eq 'measuring') { return }
    $prevStatus = $s.Status
    $s.Status = 'measuring'
    try {
        $r = Invoke-MultiSample -Url "http://$($s.Host)/" -Count 100 -IntervalMs 100
        $s.OffsetMs      = $r.OffsetMs
        $s.RttMedianMs   = $r.RttMedianMs
        $s.SigmaMs       = $r.SigmaMs
        $s.Ci95Ms        = $r.Ci95Ms
        $s.LastMeasureAt = Get-PcUtcNow
        $s.Status        = 'ok'
    } catch {
        $s.Status = 'failed'
    }
}

$measureTimer = New-Object System.Threading.Timer(
    [System.Threading.TimerCallback]{ param($s) & $measureAction $s },
    $state,
    [TimeSpan]::FromSeconds(60),     # 첫 콜백
    [TimeSpan]::FromSeconds(60)      # 주기
)
```

- [ ] **Step 2: 브라우저 자동 오픈 추가**

서버 시작 직후, listener loop 진입 직전:

```powershell
Start-Process "http://127.0.0.1:$($server.Port)/"
```

- [ ] **Step 3: finally 블록에 타이머 정리**

```powershell
} finally {
    if ($measureTimer) { $measureTimer.Dispose() }
    Stop-LocalHttpServer $server.Listener
    Write-Host "서버 종료됨"
}
```

- [ ] **Step 4: 검증**

Run: `run.bat`
Expected: 자동으로 브라우저 열림. 1분 대기하면 "측정: N초 전" 카운터가 0으로 리셋.

- [ ] **Step 5: 2시간 안정성 검증 (선택)**

도구 켜둔 채 2시간. 종료 시 console에 큰 점프 없는지 확인. JSONL 로그(Task 8 후) 분석.

- [ ] **Step 6: 커밋**

```bash
git add src/probe.ps1
git commit -m "task 6: 1분 주기 백그라운드 재측정 + 브라우저 자동 오픈"
```

---

## Task 7: Stale 상태 처리

**Files:**
- Modify: `src/http-server.ps1` (Write-StateJson 직전에 stale 판정)

- [ ] **Step 1: state JSON 직렬화 직전 stale 판정 추가**

`http-server.ps1`의 `Write-StateJson` 함수 시작에 추가:

```powershell
function Write-StateJson {
    param($resp, $state)
    # Stale 판정 (직렬화 직전)
    if ($state.LastMeasureAt -and $state.Status -ne 'measuring') {
        $ageMin = ((Get-PcUtcNow) - $state.LastMeasureAt).TotalMinutes
        if ($ageMin -gt 5) { $state.Status = 'stale' }
    }
    # 이하 기존 코드 그대로
    ...
}
```

- [ ] **Step 2: 검증**

Run: `run.bat` 후 즉시 인터넷 분리 → 6분 이상 대기 → 브라우저
Expected: UI에 "오프셋 오래됨" 빨강 표시

- [ ] **Step 3: 커밋**

```bash
git add src/http-server.ps1
git commit -m "task 7: stale 상태 자동 판정"
```

---

## Task 8: NTP 정보 측정 (선택 부가)

**Files:**
- Create: `src/ntp.ps1`
- Create: `tests/Ntp.Tests.ps1`
- Modify: `src/probe.ps1`

- [ ] **Step 1: NTP 헬퍼 단위테스트**

`tests/Ntp.Tests.ps1`:

```powershell
. "$PSScriptRoot\..\src\ntp.ps1"

Describe 'NTP byte conversion' {
    It 'ConvertFrom-NtpTimestamp parses big-endian to DateTime' {
        # NTP epoch 1900-01-01부터 secs 정수, frac 정수
        # 2026-01-01 00:00:00 UTC = NTP secs = ?
        $expected = [DateTime]::new(2026,1,1,0,0,0,[DateTimeKind]::Utc)
        $epoch1900 = [DateTime]::new(1900,1,1,0,0,0,[DateTimeKind]::Utc)
        $secs = [uint32]($expected - $epoch1900).TotalSeconds
        $frac = 0u

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
```

- [ ] **Step 2: 테스트 실행 (실패)**

Run: `Invoke-Pester tests/Ntp.Tests.ps1`
Expected: FAIL — 함수 없음

- [ ] **Step 3: `src/ntp.ps1` 작성**

```powershell
# ntp.ps1 - NTP 정보 측정 (§7). 보정엔 사용하지 않고 표시 정보 전용
. "$PSScriptRoot\anchor.ps1"

function ConvertFrom-NtpTimestamp {
    param(
        [Parameter(Mandatory)][byte[]]$ResponseBytes,
        [Parameter(Mandatory)][int]$StartIndex   # 40 = Transmit Timestamp
    )
    # 빅엔디안 4바이트 secs + 4바이트 frac (각각 reverse 후 ToUInt32)
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

        # 검증
        $mode    = $resp[0] -band 0x07
        $stratum = $resp[1]
        if ($mode -ne 4)        { throw 'NTP: not a server response' }
        if ($stratum -eq 0 -or $stratum -ge 16) { throw 'NTP: stratum unsync' }

        $ntpUtc = ConvertFrom-NtpTimestamp -ResponseBytes $resp -StartIndex 40
        $rttMs = ($t2 - $t1) / [System.Diagnostics.Stopwatch]::Frequency * 1000
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
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `Invoke-Pester tests/Ntp.Tests.ps1`
Expected: PASS

- [ ] **Step 5: probe.ps1에 NTP 통합 (시작 시 + 10분 타이머)**

dot-source 추가:
```powershell
. "$PSScriptRoot\ntp.ps1"
```

초기 측정 끝나고 추가:
```powershell
# 초기 NTP 정보 (실패해도 무시)
try {
    $ntp = Get-NtpInfo
    $state.NtpInfo = @{ skewMs = $ntp.SkewMs; rttMs = $ntp.RttMs; at = $ntp.At.ToString('o') }
    Write-Host "NTP skew: $([Math]::Round($ntp.SkewMs,1)) ms (RTT $([Math]::Round($ntp.RttMs,1)) ms)"
} catch {
    Write-Host "NTP 점검 불가 (정보 표시 생략)" -ForegroundColor DarkGray
    $state.NtpInfo = $null
}

# NTP 타이머 (10분)
$ntpAction = {
    param($s)
    try {
        $n = Get-NtpInfo
        $s.NtpInfo = @{ skewMs = $n.SkewMs; rttMs = $n.RttMs; at = $n.At.ToString('o') }
    } catch {
        $s.NtpInfo = $null
    }
}
$ntpTimer = New-Object System.Threading.Timer(
    [System.Threading.TimerCallback]{ param($s) & $ntpAction $s },
    $state,
    [TimeSpan]::FromMinutes(10),
    [TimeSpan]::FromMinutes(10)
)
```

finally 블록에 타이머 dispose 추가:
```powershell
if ($ntpTimer) { $ntpTimer.Dispose() }
```

- [ ] **Step 6: 검증**

Run: `run.bat`
Expected: 콘솔에 NTP skew 출력, 브라우저 UI 하단에 "참고: PC 시계 +Xms"

- [ ] **Step 7: NTP 차단 시뮬레이션 (선택)**

방화벽으로 UDP 123 임시 차단 → 도구 정상 동작, UI에서 NTP 줄 사라짐 확인

- [ ] **Step 8: 커밋**

```bash
git add src/ntp.ps1 src/probe.ps1 tests/Ntp.Tests.ps1
git commit -m "task 8: NTP 정보 측정 (보정 미사용, 차단 시 자동 숨김)"
```

---

## Task 9: JSONL 로그 + 일별 롤링

**Files:**
- Create: `src/logger.ps1`
- Modify: `src/probe.ps1`

- [ ] **Step 1: `src/logger.ps1` 작성**

```powershell
# logger.ps1 - JSONL 일별 롤링 (§8)
. "$PSScriptRoot\anchor.ps1"

$script:LogRoot = $null

function Initialize-Logger {
    param([Parameter(Mandatory)][string]$LogDir)
    if (-not (Test-Path $LogDir)) { [void](New-Item -ItemType Directory -Path $LogDir -Force) }
    $script:LogRoot = $LogDir
    Remove-OldLogs
}

function Get-CurrentLogPath {
    $today = (Get-PcUtcNow).ToString('yyyyMMdd')
    return Join-Path $script:LogRoot "probe-$today.jsonl"
}

function Write-LogEvent {
    param([Parameter(Mandatory)][hashtable]$Event)
    if (-not $script:LogRoot) { return }
    $Event['ts'] = (Get-PcUtcNow).ToString('o')
    $line = ($Event | ConvertTo-Json -Compress -Depth 5)
    Add-Content -Path (Get-CurrentLogPath) -Value $line -Encoding UTF8
}

function Remove-OldLogs {
    if (-not $script:LogRoot) { return }
    $cutoff = (Get-PcUtcNow).AddDays(-25)
    Get-ChildItem -Path $script:LogRoot -Filter 'probe-*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
```

- [ ] **Step 2: probe.ps1에서 측정 결과 로깅**

dot-source 추가, Initialize-Logger 호출:
```powershell
. "$PSScriptRoot\logger.ps1"
Initialize-Logger -LogDir (Join-Path $PSScriptRoot '..\logs')
```

`measureAction` ScriptBlock 안에 catch/try 끝에 로깅 추가:
```powershell
    try {
        $r = Invoke-MultiSample -Url "http://$($s.Host)/" -Count 100 -IntervalMs 100
        ...
        Write-LogEvent @{
            ev = 'measure'; host = $s.Host
            offsetMs = $r.OffsetMs; sigmaMs = $r.SigmaMs
            rttMedianMs = $r.RttMedianMs
            sampleCount = $r.SampleCount; acceptedCount = $r.AcceptedCount
        }
    } catch {
        $s.Status = 'failed'
        Write-LogEvent @{ ev = 'measure_failed'; reason = "$_" }
    }
```

NTP 콜백도 동일 패턴으로 로깅:
```powershell
    try {
        $n = Get-NtpInfo
        $s.NtpInfo = @{ skewMs = $n.SkewMs; rttMs = $n.RttMs; at = $n.At.ToString('o') }
        Write-LogEvent @{ ev = 'ntp'; skewMs = $n.SkewMs; rttMs = $n.RttMs }
    } catch {
        $s.NtpInfo = $null
        Write-LogEvent @{ ev = 'ntp_failed'; reason = "$_" }
    }
```

- [ ] **Step 3: 검증**

Run: `run.bat`. 1분 후 종료.
Expected: `logs/probe-YYYYMMDD.jsonl` 생성, `measure` 라인 존재.

- [ ] **Step 4: 커밋**

```bash
git add src/logger.ps1 src/probe.ps1
git commit -m "task 9: JSONL 일별 롤링 로그"
```

---

## Task 10: Graceful Shutdown

**Files:**
- Modify: `src/probe.ps1`

- [ ] **Step 1: Ctrl+C 핸들러 + 종료 플래그**

`probe.ps1` 상단부:

```powershell
$script:ShouldStop = $false

[Console]::CancelKeyPress += [ConsoleCancelEventHandler]{
    param($sender, $e)
    Write-Host ""
    Write-Host "종료 신호 수신, 정리 중..." -ForegroundColor Yellow
    $e.Cancel = $true              # 즉시 종료 막음
    $script:ShouldStop = $true
}
```

**주의**: PowerShell에서 `[Console]::CancelKeyPress` += 등록은 환경에 따라 동작 차이가 있다. 5.1에서 동작 확인. 안 되면 [Console]::TreatControlCAsInput 토글 + 별도 키 감지 루프로 대체.

대체안 (더 robust):
```powershell
# CancelKeyPress 이벤트는 멀티스레드 환경에서 까다로움
# 대신 listener loop 안에서 ShouldStop 체크 + Stop()으로 깨우기
[Console]::TreatControlCAsInput = $false   # 기본
trap [System.Management.Automation.PipelineStoppedException] {
    $script:ShouldStop = $true
    continue
}
```

- [ ] **Step 2: HttpListener loop을 ShouldStop 체크하도록 수정**

`http-server.ps1`의 Loop ScriptBlock에 인자 추가:

```powershell
Loop = {
    param($listener, $state, $webRoot, $shouldStopRef)
    while ($listener.IsListening -and -not $shouldStopRef.Value) {
        try {
            # 1초 타임아웃 폴링 대신 GetContext는 블로킹이라
            # ShouldStop 시 외부에서 listener.Stop() 호출 → HttpListenerException 발생
            $ctx = $listener.GetContext()
            ...
        } catch [System.Net.HttpListenerException] {
            break
        }
    }
}
```

probe.ps1에서 호출 시 ref 전달, 별도 watchdog 스레드:

```powershell
# 종료 감지 워커
$shouldStopRef = [ref]$false
$watchdog = [System.Threading.Thread]::new([System.Threading.ThreadStart]{
    while (-not $script:ShouldStop) { Start-Sleep -Milliseconds 200 }
    $shouldStopRef.Value = $true
    try { $server.Listener.Stop() } catch {}
})
$watchdog.IsBackground = $true
$watchdog.Start()
```

- [ ] **Step 3: finally 블록에서 진행 중 측정 대기 (max 10s)**

```powershell
} finally {
    Write-Host "타이머 정리..."
    if ($measureTimer) { $measureTimer.Dispose() }
    if ($ntpTimer)     { $ntpTimer.Dispose() }

    Write-Host "진행 중 측정 완료 대기 (max 10s)..."
    $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($state.Status -eq 'measuring' -and $waitSw.Elapsed.TotalSeconds -lt 10) {
        Start-Sleep -Milliseconds 200
    }

    Write-Host "HTTP 서버 정리..."
    Stop-LocalHttpServer $server.Listener

    Write-LogEvent @{ ev = 'shutdown' }
    Write-Host "종료 완료"
}
```

- [ ] **Step 4: 검증**

Run: `run.bat` → 측정 진행 중 Ctrl+C
Expected: "타이머 정리..." → "진행 중 측정 완료 대기..." → "종료 완료" 순으로 출력. 즉시 종료 안 됨.

- [ ] **Step 5: 커밋**

```bash
git add src/probe.ps1 src/http-server.ps1
git commit -m "task 10: graceful shutdown (Ctrl+C 핸들러, 타이머 정리, 측정 대기)"
```

---

## Task 11: 마무리 + README + 안정성 검증

**Files:**
- Create: `README.md`

- [ ] **Step 1: `README.md` 작성**

```markdown
# 서버시간 측정 도구

`http://den08.inames.kr/`의 서버 시각을 ±50ms 정확도로 추정해 네이버 시계 스타일로 표시.

## 실행 방법

1. `run.bat` 더블클릭
2. 검정 콘솔 + 자동으로 브라우저에 시계 페이지 열림
3. 종료: 콘솔에서 Ctrl+C

## 요구사항

- Windows 10 / 11 (PowerShell 5.1 이상 기본 탑재)
- 인터넷 연결
- (선택) UDP 123 허용 — NTP 정보 표시용. 막혀있어도 도구는 정상 동작

## 정확도

- 표시 시각 σ ≈ 21ms (95% CI ±42ms)
- 알고리즘: Cristian + 100샘플 + RTT 하위 10% + 중앙값 + 양자화 보정 +500ms
- PC 시계 절대 오프셋 자동 상쇄 (PC 시계가 부정확해도 표시값 정확)
- PC 시계 점프 방어: monotonic anchor + Stopwatch

## PC방에서 사용

가능. 단:
- PowerShell.exe 실행 가능해야 함 (게임 PC방은 거의 다 됨)
- 폴더째 USB에서 실행 가능
- NTP 차단된 환경에서도 정확도 영향 0 (NTP는 정보 표시 전용)

## 폴더 구조

(생략 — 디자인 doc 참조)

## 로그

`logs/probe-YYYYMMDD.jsonl`. 25일 후 자동 삭제.
```

- [ ] **Step 2: 24시간 안정성 검증**

`run.bat` 켜둔 채 24시간. 다음 확인:
- 콘솔 종료 안 됨
- 메모리 사용 < 100MB (`tasklist /fi "imagename eq powershell.exe"`)
- `logs/probe-*.jsonl`에 1440개 ± 10개 measure 라인
- 자정 넘기면서 새 로그 파일 생성

- [ ] **Step 3: PC 시계 변조 테스트**

도구 실행 중 윈도우 시계 +30초 강제 변경 → 표시값이 점프 없이 매끄럽게 진행 (anchor 효과)
Expected: 표시값에 영향 없음

- [ ] **Step 4: time.is 비교**

브라우저 탭에 우리 도구 + `https://time.is` 동시 표시 → 시각 차이가 100ms 이내인지 육안 확인

- [ ] **Step 5: 커밋**

```bash
git add README.md
git commit -m "task 11: README + 안정성 검증"
```

---

## 종합 체크리스트 (구현 후 self-check)

- [ ] `[DateTime]::UtcNow` 직접 사용한 곳: `anchor.ps1`의 `Initialize-Anchor` 안에서만 (1곳)
- [ ] HttpListener prefix는 `http://127.0.0.1:` (LAN 노출 금지)
- [ ] 호스트는 `den08.inames.kr` 하드코딩 (사용자 입력 X, SSRF 표면 0)
- [ ] NTP 응답 검증 (Stratum, Mode) 포함
- [ ] User-Agent: `ServerTimeProbe/1.0 (personal-use)`
- [ ] 단위테스트: `Invoke-Pester tests/` 모두 PASS
- [ ] 24시간 안정성 검증 통과
- [ ] PC 시계 변조 시 표시값 영향 없음

---

## Self-Review 결과

**1. Spec coverage**: 디자인 doc §3~§14 모두 task에 매핑됨.
- §3 아키텍처 → Task 0, 3
- §4 알고리즘 → Task 1, 2-A, 2-B
- §5 UI → Task 4, 5
- §6 동시성 → Task 6, 8 (타이머)
- §7 NTP → Task 8
- §8 로깅 → Task 9
- §9 상태 → Task 7 (stale)
- §10 보안 → 모든 task에 분산 (체크리스트로 확인)
- §11 단계 순서 → 본 plan task 번호와 일치
- §12 검증 → Task 11
- §13 v2 → 본 plan에서 제외 (의도적)

**2. Placeholder scan**: 검색 결과 "TBD/TODO/fill in" 없음. 모든 step에 코드 또는 명령 명시.

**3. Type consistency**:
- `Get-PcUtcNow`, `Initialize-Anchor` — Task 1 정의 → Task 2~10에서 사용 ✓
- `Reduce-Samples` 반환 객체 필드(`OffsetMs`, `RttMedianMs`, `SigmaMs`, `Ci95Ms`, `SampleCount`, `AcceptedCount`) — Task 2-B 정의 → Task 3, 6, 9에서 사용 ✓
- `State` hashtable 필드(`Host`, `OffsetMs`, `LastMeasureAt`, `RttMedianMs`, `SigmaMs`, `Ci95Ms`, `Status`, `NtpInfo`) — Task 3 정의 → Task 6, 7, 8, 9에서 사용 ✓
- `pcSendTimeAtMs` (서버 응답 필드) → 클라이언트 `clock.js`에서 사용 ✓

**4. 알려진 한계 (의도적)**:
- Task 10 graceful shutdown은 PowerShell의 Ctrl+C 처리 특성상 환경에 따라 동작 차이가 있음. 대체안 명시. 실구현 시 두 방식 모두 시험 후 안정적인 쪽 채택.
- Task 6의 `[System.Threading.Timer]` ScriptBlock 콜백은 PowerShell 5.1에서 약간의 호환성 이슈 가능. 동작 안 되면 `Register-ObjectEvent` + `[System.Timers.Timer]` 패턴으로 대체.
- 24시간 안정성 검증은 실제 시간 소요라 plan 자체엔 코드 없음.

---

## Execution Handoff

Plan 작성 완료. 사용자가 외출 후 돌아오면 다음 두 옵션 중 선택:

1. **Subagent-Driven (recommended)** — task별로 fresh subagent 디스패치, task 사이 review. 빠른 반복.
2. **Inline Execution** — 같은 세션에서 batch 실행. checkpoint마다 review.

어느 쪽으로 갈지는 다음 세션에서 결정.
