# 빠른 측정(Fast Measurement) 기능 설계

작성일: 2026-05-25 / 작성자: Claude (with 사용자)

## 배경 / 목표

현재 측정은 정확도(±10~50ms) 우선이라 초기 측정 최대 20초, F5 재측정 최대 15초가 걸린다.
"20초를 못 기다리는 사용자"를 위해 **정확도를 크게 포기하는 대신 빠른(최대 5초) 측정** 옵션을 추가한다.

- 목표 시간: 메인 윈도우 ~2.5초, 하드캡 **5초**
- 기대 정확도: edge 1~3개 → ±100~300ms, edge 0개(frozen Date) → ±500ms
- 기존 정밀 경로(20s/15s)는 그대로 유지. 빠른 측정은 **별도 1회성 동작**.

## 비목표 (YAGNI)

- 빠른 측정 결과를 백그라운드에서 자동 정밀화하지 않는다(프로그레시브 미채택).
- 빠른/정밀 모드를 고정하는 토글을 두지 않는다. 빠른 측정은 누를 때마다 1회만 동작하고, 이후 F5 재측정은 기존 15초 정밀 경로를 쓴다.
- 빠른 측정 전용 측정 함수를 새로 만들지 않는다(기존 `Invoke-AdaptiveMultiSample` 재사용).

## 1. 측정 알고리즘 (기존 함수 재사용)

`Invoke-AdaptiveMultiSample`은 이미 필요한 파라미터를 모두 받는다. 빠른 측정은 신규 함수 없이 1회 호출:

```powershell
Invoke-AdaptiveMultiSample -Url $measurementUrl -TargetWindowMs 2500 -MinEdgeCount 1 -MaxTotalMs 5000
```

- `MaxTotalMs = 5000`: 하드캡 5초. 기존 `isPastDeadline`(in-flight 요청의 timeout만큼 미리 멈춤) 로직으로 5초 보장.
- `TargetWindowMs = 2500`: 메인 윈도우 ~2.5초 → edge 2~3개 기대.
- `MinEdgeCount = 1`: 연장 루프 사실상 비활성화.
  - `Test-ShouldExtendWindow`는 `Method -like 'edge*'` 이고 `AcceptedCount < MinEdgeCount`일 때만 연장.
  - edge ≥1개면 `AcceptedCount ≥ 1 ≥ MinEdgeCount=1` → 연장 안 함.
  - edge 0개면 `upper-envelope`(edge* 아님) → 연장 안 함.
  - 따라서 5초 안에 단일 윈도우로 종료.
- 결과 method는 기존과 동일하게 산출됨: `edge-intersect`/`edge-intersect-robust`/`upper-envelope`, naver URL이면 `naver-time-api`(precise 경로, 샘플만 적게).

## 2. 수용 정책 (게이트 우회 + 1회성)

빠른 측정은 명시적 동작이므로 재측정 게이트(`Get-RemeasureAttemptDecision`, `MinAcceptedEdges=5`)와
delta 재시도 루프를 **타지 않는다**. 1회 측정 결과를 그대로 채택해 offset을 덮어쓴다.

- LastMeasureAt이 없어도(=첫 측정) 사용 가능.
- 이미 정밀 offset이 있어도 빠른 측정 결과로 덮어쓴다(사용자가 명시적으로 누른 동작).

### 덮어쓰기 전 확인(클라이언트 판단)

"최근/오래됨"은 기존 stale 임계값(**5분**, `Write-StateJson`의 `$ageMin -gt 5 → status='stale'`)을 재사용한다.
신규 상수를 만들지 않는다. 판단은 모두 클라이언트(clock.js)에서:

- **오래됨/없음** (`!state.lastMeasureAt` 또는 `state.status === 'stale'`):
  확인 없이 즉시 `POST /api/measure-fast`.
- **최근** (유효 offset, 5분 이내):
  `confirm("최근 측정값이 있습니다. 빠른 측정(정확도 낮음)으로 덮어쓸까요?")` →
  확인 시에만 POST, 취소 시 중단.

서버는 들어온 요청은 무조건 실행·덮어쓴다(확인 책임은 클라이언트). 이 분리로 서버 로직이 단순해진다.

## 3. 서버 (probe.ps1 / http-server.ps1)

### 상태
- `$state.MeasureMode` 추가: `'normal'`(기본) | `'fast'`. 초기화는 state 정의부에서 `'normal'`.
- `$state.LastMeasureMode` 추가: 마지막으로 완료된 측정 종류(`'normal'`|`'fast'`). UI 라벨용. `/api/state`로 노출.

### 엔드포인트
- `POST /api/measure-fast` → `Start-FastMeasureFromRequest`:
  - `TargetUrl` 없으면 409(측정 대상 없음). (remeasure와 달리 `LastMeasureAt`은 요구하지 않음 → 첫 측정으로도 사용 가능.)
  - 측정 진행 중이면 `{ ok:true, alreadyRunning:true }`.
  - `Resolve-MeasurementTarget`로 measurementUrl 갱신(기존 remeasure와 동일, cache-bust URL 대응).
  - `$state.MeasureMode = 'fast'`, `PendingTargetChange`는 false 유지(타겟 변경 아님), `Status='queued'`, 로그 `ev='fast_measure_requested'`.
  - `Restart-MeasureTimer`.

### Elapsed 핸들러 분기 (probe.ps1)
핸들러 상단(`MeasureInProgress` 가드 직후)에서:
- `MeasureMode -eq 'fast'`이면 **빠른 경로**:
  - `Invoke-AdaptiveMultiSample` 1회(§1 파라미터).
  - 결과를 state에 채택(OffsetMs/RttMedianMs/SigmaMs/Ci95Ms/SampleCount/AcceptedCount/Method/IntersectWidthMs/LastSamples/LastEdges/LastMeasureAt).
  - `LastMeasureMode='fast'`, `LastRemeasureResult='fast'`, `Status='ok'`, `LastError=''`.
  - 로그 `ev='measure'`에 `mode='fast'` 필드 포함.
  - 실패 시 기존 `measure_failed` 경로와 동일하게 처리.
- 아니면 기존 초기/재측정 경로(`LastMeasureMode='normal'`).
- 핸들러 `finally`에서 `MeasureMode='normal'`로 리셋(다음 F5가 정밀 경로 타도록), `MeasureInProgress=false`.

## 4. UI (web/index.html, web/clock.js)

### 버튼
- `measure-actions`에 `⚡ 빠른 측정` 버튼(`id="fast-measure-button"`) 추가. 클릭 → §2 확인 플로우 → `POST /api/measure-fast`.
- 활성/비활성 조건은 재측정 버튼과 유사하되, 첫 측정으로도 쓸 수 있게 `TargetUrl`만 있으면 활성.

### cap 명시 (요구사항)
- `duration-hint`(현재 "초기 측정: 기본 구간 약 6초, 최대 20초")를 세 cap 모두 표기로 변경:
  `측정 최대 20초 · 재측정 최대 15초 · 빠른 측정 최대 5초`

### 상태/라벨
- `activeMeasureLabel()`: 빠른 측정 진행 중이면 `'빠른 측정 중... (최대 5초)'`. 진행 종류 구분 위해 로컬 플래그(`localFastMeasure`) 또는 `state.status`/`MeasureMode` 활용.
- stale 수정: 현재 `'재측정 중... (10초 이내)'` → `'재측정 중... (15초 이내)'`(직전 cap 변경 반영).
- `methodLabel()`: 마지막 측정이 빠른 측정이면(`state.lastMeasureMode === 'fast'`) 접두 `⚡ 빠른 측정 · ` 를 붙이고 "정확도 낮음"을 명시. 예: `⚡ 빠른 측정 · 교집합 (edge 2개 상호 일치, 정확도 낮음)`. 기존 honest-label 정책(✓·"성공" 표현 금지) 유지.

## 5. 테스트

- PowerShell(Pester):
  - 빠른 모드 파라미터(`-TargetWindowMs 2500 -MinEdgeCount 1 -MaxTotalMs 5000`)로 `Invoke-AdaptiveMultiSample` 호출 시 **5초 데드라인 준수**(모킹된 probe로 elapsed ≤ 5초 + reserve) 회귀.
  - edge 1개만 있는 샘플로 `Reduce-Samples`가 throw 없이 결과 반환(빠른 경로가 적은 edge를 수용함을 보장).
  - 기존 39 테스트 그대로 통과.
- JS(`methodLabel` fast 접두, 확인 플로우)는 수동 확인.
- 통합 수동 확인: 실제 사이트에서 빠른 측정 → 5초 내 종료, method/정확도 라벨 표시, 최근 측정 상태에서 confirm 동작.

## 변경 파일 요약

- `src/measurement.ps1`: 변경 없음(기존 함수 재사용). 필요 시 fast 회귀 테스트만.
- `src/probe.ps1`: Elapsed 핸들러 fast 분기 + MeasureMode 리셋, state 필드 추가.
- `src/http-server.ps1`: `/api/measure-fast` 라우트 + `Start-FastMeasureFromRequest`, `/api/state`에 `lastMeasureMode` 노출, state 기본값.
- `src/web/index.html`: 빠른 측정 버튼, duration-hint 3-cap 텍스트.
- `src/web/clock.js`: 버튼 핸들러 + 확인 플로우, `activeMeasureLabel`/`methodLabel` 갱신, 10→15초 수정.
- `tests/Measurement.Tests.ps1`: fast 회귀 2건.
- 배포본 `release/ServerTimeTools/src` 동기화 + zip 재생성(기존 정책).

## 미해결/리스크

- `confirm()`는 브라우저 기본 모달이라 디자인 통제 불가. 요구사항이 "ALERT 하나 띄우고 확인"이라 기본 `confirm()`로 충분하다고 판단. (커스텀 모달은 YAGNI.)
- 빠른 측정이 edge 0개(frozen Date)면 ±500ms이고 정확도 라벨로만 경고됨. 이 경우에도 결과를 채택(사용자가 빠름을 택함).
