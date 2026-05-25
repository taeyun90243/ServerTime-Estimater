# 빠른 측정(Fast Measurement) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 최대 5초 안에 끝나는 저정확도 "빠른 측정" 1회성 동작을 별도 버튼으로 추가한다.

**Architecture:** 신규 측정 함수 없이 기존 `Invoke-AdaptiveMultiSample`을 빠른 파라미터(window 2.5s, MaxTotalMs 5s, MinEdgeCount 1)로 호출. 측정 타이머 Elapsed 핸들러에 `MeasureMode='fast'` 분기를 추가해 게이트 없이 결과를 채택. 새 엔드포인트 `/api/measure-fast`와 UI 버튼/확인 플로우/cap 명시를 더한다.

**Tech Stack:** Windows PowerShell 5.1, System.Net.HttpListener, 바닐라 JS, Pester.

설계 출처: `docs/superpowers/specs/2026-05-25-fast-measurement-design.md`

---

### Task 1: 빠른 모드 회귀 테스트 (Pester)

**Files:**
- Test: `tests/Measurement.Tests.ps1` (기존 파일에 Describe 블록 추가)

- [ ] **Step 1: 기존 테스트의 Invoke-HeadProbe 모킹 패턴 확인**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Select-String -Path tests\Measurement.Tests.ps1 -Pattern 'Mock|Invoke-AdaptiveMultiSample|Invoke-HeadProbe' | Select-Object -First 20"`
Expected: 기존 모킹/호출 패턴 확인. 패턴이 없으면 Step 3에서 합성 샘플 기반 테스트로 대체.

- [ ] **Step 2: 빠른 모드 데드라인 + 적은 edge 수용 테스트 작성**

`tests/Measurement.Tests.ps1`에 추가. `Invoke-HeadProbe`를 모킹해 ~80ms RTT를 흉내내고 `MaxTotalMs=5000` 데드라인을 검증한다. 모킹이 어려우면(아래 fallback) `Reduce-Samples`가 edge 1개에서 throw 없이 결과를 내는 것만 검증한다.

```powershell
Describe 'Fast measurement path' {
    It 'Invoke-AdaptiveMultiSample honors 5s deadline with fast params' {
        $script:probeCount = 0
        Mock Invoke-HeadProbe {
            $script:probeCount++
            Start-Sleep -Milliseconds 40
            $nowMs = [double](([DateTimeOffset](Get-Date)).ToUnixTimeMilliseconds())
            [PSCustomObject]@{
                RttMs = 80.0; RawServerDateMs = $nowMs; AgeSec = 0
                ServerDateMs = $nowMs; PcAtT2Ms = $nowMs; RawOffsetMs = 0.0; OffsetMs = 0.0
            }
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-AdaptiveMultiSample -Url 'http://example.test/' -TargetWindowMs 2500 -MinEdgeCount 1 -MaxTotalMs 5000
        $sw.Stop()
        # in-flight 1건(timeout reserve)까지 포함 5초 + 여유. 넉넉히 6.5초 상한.
        $sw.Elapsed.TotalMilliseconds | Should -BeLessThan 6500
        $r | Should -Not -BeNullOrEmpty
    }
    It 'Reduce-Samples returns a result with a single edge (no throw)' {
        # 정수 초 경계를 한 번만 넘는 두 샘플 → edge 1개
        $base = 1700000000000.0
        $samples = @(
            [PSCustomObject]@{ RttMs=80; RawServerDateMs=($base+900);  AgeSec=0; ServerDateMs=($base+900);  PcAtT2Ms=($base+900) }
            [PSCustomObject]@{ RttMs=80; RawServerDateMs=($base+1100); AgeSec=0; ServerDateMs=($base+1100); PcAtT2Ms=($base+1100) }
        )
        { Reduce-Samples -Samples $samples } | Should -Not -Throw
        (Reduce-Samples -Samples $samples) | Should -Not -BeNullOrEmpty
    }
}
```

참고: 위 두 번째 테스트의 샘플 필드는 `Invoke-HeadProbe` 반환 형태(`RawServerDateMs/AgeSec/ServerDateMs/PcAtT2Ms`)와 일치시켜야 한다. Step 1에서 실제 필드명을 확인해 맞춘다.

- [ ] **Step 3: 테스트 실패 확인(빨강) 후 필드 보정**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Script tests\Measurement.Tests.ps1 -FullNameFilter '*Fast measurement path*'"`
Expected: 처음엔 필드명/모킹 불일치로 실패할 수 있음. 실제 `Invoke-HeadProbe`/`Reduce-Samples` 시그니처(measurement.ps1)에 맞춰 필드 보정 후 PASS.

- [ ] **Step 4: 전체 테스트 통과 확인**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Script tests\Measurement.Tests.ps1,tests\Anchor.Tests.ps1,tests\Ntp.Tests.ps1"`
Expected: 41 passed (기존 39 + 2), 0 failed.

- [ ] **Step 5: Commit**

```
git add tests/Measurement.Tests.ps1
git commit -m "test: fast measurement deadline and low-edge acceptance"
```

---

### Task 2: 서버 상태 필드 + Elapsed 핸들러 fast 분기 (probe.ps1)

**Files:**
- Modify: `src/probe.ps1` (state 정의부 + Elapsed Action 핸들러)

- [ ] **Step 1: state에 MeasureMode/LastMeasureMode 추가**

state 해시테이블 정의부(`PendingTargetChange = $false` 부근)에 추가:

```powershell
        MeasureMode = 'normal'
        LastMeasureMode = 'normal'
```

- [ ] **Step 2: Elapsed 핸들러에 fast 분기 추가**

핸들러에서 `$s.MeasureInProgress = $true; $s.Status = 'measuring'` 직후, 기존 `$previousOffsetMs`/`$isTargetChange` 계산 앞에 fast 분기를 둔다. fast면 기존 2-attempt 로직 전부를 건너뛴다:

```powershell
        if ($s.MeasureMode -eq 'fast') {
            try {
                try { Write-LogEvent @{ ev = 'measure_started'; mode = 'fast'; host = $s.Host; targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl } } catch {}
                $measurementUrl = if ($s.MeasurementUrl) { $s.MeasurementUrl } else { $s.TargetUrl }
                $r = Invoke-AdaptiveMultiSample -Url $measurementUrl -TargetWindowMs 2500 -MinEdgeCount 1 -MaxTotalMs 5000
                $s.OffsetMs = $r.OffsetMs; $s.RttMedianMs = $r.RttMedianMs; $s.SigmaMs = $r.SigmaMs
                $s.Ci95Ms = $r.Ci95Ms; $s.SampleCount = $r.SampleCount; $s.AcceptedCount = $r.AcceptedCount
                $s.Method = $r.Method; $s.IntersectWidthMs = $r.IntersectWidthMs
                $s.LastSamples = $r.Samples; $s.LastEdges = $r.Edges
                $s.LastMeasureAt = Get-PcUtcNow; $s.LastMeasureMode = 'fast'
                $s.LastRemeasureResult = 'fast'; $s.LastError = ''; $s.Status = 'ok'
                $s.PendingTargetChange = $false
                Write-LogEvent @{ ev = 'measure'; mode = 'fast'; host = $s.Host; targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl; offsetMs = $r.OffsetMs; rttMedianMs = $r.RttMedianMs; sampleCount = $r.SampleCount; acceptedCount = $r.AcceptedCount; method = $r.Method }
            } catch {
                $s.LastError = "$_"; $s.Status = 'error'
                Write-LogEvent @{ ev = 'measure_failed'; mode = 'fast'; targetUrl = $s.TargetUrl; measurementUrl = $s.MeasurementUrl; reason = "$_" }
            } finally {
                $s.MeasureMode = 'normal'
                $s.MeasureInProgress = $false
                $s.LastRemeasureFinishedAt = Get-PcUtcNow
            }
            return
        }
```

참고: 기존 핸들러의 정상 경로 끝에서 `LastMeasureMode = 'normal'`을 설정하도록 한 줄 추가(정상 측정 후 라벨이 fast로 남지 않게). 기존 `accepted` 처리 블록(`$s.Status = 'ok'` 부근)에 `$s.LastMeasureMode = 'normal'` 추가.

- [ ] **Step 3: 구문 점검 (dot-source 로드)**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command ". src\anchor.ps1; . src\measurement.ps1; . src\logger.ps1; Get-Command Invoke-AdaptiveMultiSample | Out-Null; Write-Output 'measurement OK'"`
Expected: `measurement OK` (probe.ps1은 실행형이라 직접 dot-source 대신 구문만 확인: 아래)
Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw src\probe.ps1), [ref]@()); Write-Output 'probe.ps1 parses'"`
Expected: `probe.ps1 parses` (파싱 에러 없음)

- [ ] **Step 4: Commit**

```
git add src/probe.ps1
git commit -m "feat: add fast measurement branch to measure handler"
```

---

### Task 3: /api/measure-fast 엔드포인트 + state 노출 (http-server.ps1)

**Files:**
- Modify: `src/http-server.ps1` (라우팅 + Start-FastMeasureFromRequest + Write-StateJson)

- [ ] **Step 1: 라우트 추가**

`/api/remeasure` 분기 뒤에 추가:

```powershell
    } elseif ($path -eq '/api/measure-fast') {
        if ($req.HttpMethod -ne 'POST') {
            $resp.StatusCode = 405
            Write-JsonResponse $resp @{ ok = $false; error = 'Method Not Allowed' }
            return
        }
        Start-FastMeasureFromRequest $resp $state
```

- [ ] **Step 2: Start-FastMeasureFromRequest 함수 추가**

`Start-RemeasureFromRequest` 함수 뒤에 추가. remeasure와 달리 `LastMeasureAt`을 요구하지 않는다:

```powershell
function Start-FastMeasureFromRequest {
    param($resp, $state)

    if (-not $state.TargetUrl) {
        $resp.StatusCode = 409
        Write-JsonResponse $resp @{ ok = $false; error = '먼저 측정 대상을 입력하세요.' }
        return
    }
    if (-not $state.MeasureTimer) {
        $resp.StatusCode = 500
        Write-JsonResponse $resp @{ ok = $false; error = '측정 타이머가 준비되지 않았습니다.' }
        return
    }
    if ($state.MeasureInProgress -or $state.MeasureTimer.Enabled) {
        Write-JsonResponse $resp @{ ok = $true; alreadyRunning = $true }
        return
    }

    $state.LastMeasureRequestedAt = Get-PcUtcNow
    $state.LastRemeasureFinishedAt = $null
    $state.LastRemeasureResult = ''
    $state.LastRemeasureDeltaMs = $null
    $state.LastRemeasureAttempts = 0
    $previousTargetUrl = $state.TargetUrl
    if (Get-Command Resolve-MeasurementTarget -ErrorAction SilentlyContinue) {
        $measurementTarget = Resolve-MeasurementTarget -Url $state.TargetUrl
        $state.TargetUrl = $measurementTarget.TargetUrl
        $state.Host = ([Uri]$measurementTarget.TargetUrl).Host
        $state.MeasurementUrl = $measurementTarget.MeasurementUrl
        $state.MeasurementNote = $measurementTarget.MeasurementNote
    }
    $state.PendingTargetChange = $false
    $state.MeasureMode = 'fast'
    $state.MeasureInProgress = $false
    $state.Status = 'queued'
    Write-LogEvent @{ ev = 'fast_measure_requested'; source = 'button'; host = $state.Host }
    Restart-MeasureTimer $state.MeasureTimer
    Write-JsonResponse $resp @{ ok = $true }
}
```

- [ ] **Step 3: /api/state에 lastMeasureMode 노출**

`Write-StateJson`의 `$payload` 해시테이블에 추가:

```powershell
        lastMeasureMode = $state.LastMeasureMode
```

- [ ] **Step 4: 구문 점검**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "$null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw src\http-server.ps1), [ref]@()); Write-Output 'http-server.ps1 parses'"`
Expected: `http-server.ps1 parses`

- [ ] **Step 5: Commit**

```
git add src/http-server.ps1
git commit -m "feat: add /api/measure-fast endpoint and expose lastMeasureMode"
```

---

### Task 4: UI — 버튼, 확인 플로우, cap 명시, 라벨 (index.html / clock.js)

**Files:**
- Modify: `src/web/index.html` (버튼 + duration-hint)
- Modify: `src/web/clock.js` (핸들러, activeMeasureLabel, methodLabel, 10→15초)

- [ ] **Step 1: index.html 버튼 + cap 텍스트**

`measure-actions` div를 다음으로 교체:

```html
    <div class="measure-actions">
      <button class="remeasure-button" id="remeasure-button" type="button" disabled>재측정</button>
      <button class="fast-measure-button" id="fast-measure-button" type="button" disabled>⚡ 빠른 측정</button>
      <span class="duration-hint" id="duration-hint">측정 최대 20초 · 재측정 최대 15초 · 빠른 측정 최대 5초</span>
    </div>
```

- [ ] **Step 2: clock.js — 빠른 측정 버튼 핸들러 + 확인 플로우**

remeasure 버튼 핸들러 등록부 근처에 추가(실제 함수명/패턴은 기존 remeasure 핸들러를 그대로 참고해 맞춘다):

```javascript
  const fastBtn = document.getElementById('fast-measure-button');
  if (fastBtn) {
    fastBtn.addEventListener('click', async () => {
      // 최근(5분 이내) 유효 측정이 있으면 덮어쓰기 전에 확인
      const recent = state && state.lastMeasureAt && state.status !== 'stale';
      if (recent && !window.confirm('최근 측정값이 있습니다. 빠른 측정(정확도 낮음)으로 덮어쓸까요?')) {
        return;
      }
      localFastMeasure = true;
      try {
        await fetch('/api/measure-fast', { method: 'POST' });
      } catch (e) { /* 상태 폴링이 결과 반영 */ }
    });
  }
```

`localFastMeasure`는 파일 상단 상태 변수 선언부에 `let localFastMeasure = false;`로 추가. 측정 완료(`state.lastMeasureMode === 'fast'` 반영 또는 status가 ok/stale로 전환) 시 false로 리셋한다(기존 `localReloadRemeasure` 리셋 위치를 참고).

- [ ] **Step 3: clock.js — activeMeasureLabel에 fast 추가 + 10→15초 수정**

`activeMeasureLabel()`을 교체:

```javascript
  function activeMeasureLabel() {
    if (localFastMeasure) return '빠른 측정 중... (최대 5초)';
    return isRemeasureUiActive() ? '재측정 중... (15초 이내)' : '초기 측정 중... (20초 이내)';
  }
```

- [ ] **Step 4: clock.js — methodLabel에 fast 접두 추가**

`methodLabel(method, edgeCount, acceptedCount)` 호출부들이 fast 여부를 전달하도록, 표시 직전에 접두를 붙인다. 가장 간단한 방법: 라벨 산출부에서

```javascript
    let label = methodLabel(state.method, state.edgeCount, acceptedCount);
    if (state.lastMeasureMode === 'fast') {
      label = '⚡ 빠른 측정 · ' + label + ' (정확도 낮음)';
    }
```

`clock.js`의 두 표시 지점(항상 보이는 stats 줄 ~341행, 상세 요약 ~548행) 모두에 동일 처리를 적용. 상세 요약은 `data.lastMeasureMode`(/api/samples에는 없음)가 아니라 `state.lastMeasureMode`를 참조.

- [ ] **Step 5: 빠른 측정 버튼 활성화 조건**

기존 remeasure 버튼 enable/disable 로직 근처에서, fast 버튼은 `state.targetUrl`이 있으면(측정 전이라도) 활성화:

```javascript
    if (fastBtn) fastBtn.disabled = !(state && state.targetUrl) || state.status === 'measuring' || state.status === 'queued';
```

- [ ] **Step 6: 수동 동작 확인**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File run.bat` 또는 `ServerTimeProbe.exe` 실행 후 브라우저에서:
1. URL 입력 → ⚡빠른 측정 클릭 → 5초 내 종료, stats에 `⚡ 빠른 측정 · … (정확도 낮음)` 표시
2. duration-hint에 `측정 최대 20초 · 재측정 최대 15초 · 빠른 측정 최대 5초` 표시
3. 방금 측정 직후(5분 이내) 다시 ⚡빠른 측정 → confirm 대화상자 → 취소 시 미실행, 확인 시 실행
Expected: 위 3가지 정상.

- [ ] **Step 7: Commit**

```
git add src/web/index.html src/web/clock.js
git commit -m "feat: fast measure button, confirm flow, cap hints, accuracy label"
```

---

### Task 5: 배포본 동기화 + 최종 검증

**Files:**
- Modify: `release/ServerTimeTools/src/*` (src 복사), `release/ServerTimeTools.zip` 재생성

- [ ] **Step 1: 전체 테스트 재확인**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Script tests\Measurement.Tests.ps1,tests\Anchor.Tests.ps1,tests\Ntp.Tests.ps1"`
Expected: 41 passed, 0 failed.

- [ ] **Step 2: release/src 동기화**

`src/probe.ps1`, `src/http-server.ps1`, `src/web/index.html`, `src/web/clock.js`를 `release/ServerTimeTools/src/`의 대응 경로로 복사(기존 release에 해당 파일이 있을 때만).

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Compare-Object (Get-Content src\probe.ps1) (Get-Content release\ServerTimeTools\src\probe.ps1) | Measure-Object | Select-Object -ExpandProperty Count"`
Expected: 복사 후 `0` (차이 없음).

- [ ] **Step 3: zip 재생성**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -Path release\ServerTimeTools\* -DestinationPath release\ServerTimeTools.zip -Force"`
Expected: 에러 없음.

- [ ] **Step 4: CLAUDE.md에 변경 절 추가**

빠른 측정 기능 추가 절을 CLAUDE.md 상단에 기록(증상/근거/수정/검증 형식, 기존 절 스타일 따름).

- [ ] **Step 5: Commit**

```
git add release/ CLAUDE.md
git commit -m "chore: sync release bundle and document fast measurement"
```

---

## Self-Review 결과

- **Spec 커버리지:** §1 알고리즘→Task2, §2 게이트 우회/확인→Task2+Task4 Step2, §3 서버→Task2/3, §4 UI/cap/라벨→Task4, §5 테스트→Task1/Task5. 누락 없음.
- **Placeholder:** 모든 코드 스텝에 실제 코드 포함. UI 핸들러는 "기존 패턴 참고" 지시가 있으나 실제 코드 블록 제공(파일별 변수명은 실행 시 기존 코드에 맞춰 확정).
- **타입 일관성:** `MeasureMode`/`LastMeasureMode`(probe state) → `lastMeasureMode`(/api/state JSON, camelCase) → `state.lastMeasureMode`(clock.js). 엔드포인트 `/api/measure-fast` 일관. `localFastMeasure` 플래그 일관.

## 리스크 / 주의

- clock.js의 정확한 상태 변수/리셋 위치는 파일마다 다르므로 Task4에서 기존 `localReloadRemeasure` 패턴을 먼저 읽고 맞춘다.
- Task1의 Pester Mock이 환경에서 안 먹으면(모듈 함수 모킹 제약) 두 번째 테스트(Reduce-Samples edge 1개)만 유지하고 데드라인 테스트는 생략 가능.
