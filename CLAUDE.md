# 서버시간 측정 서비스 (Server Time Estimator)

## 빠른 측정 기능 + 재측정 cap 10→15초 (2026-05-25, Claude)

### 재측정 cap 상향 (10→15초)

로그 분석: `remeasure_failed_insufficient` 10건 중 9건이 `edge-intersect`(전부 상호 일치)인데 edge가 4개로 딱 1개 부족. 같은 호스트(`den08.inames.kr`)가 **초기측정(20초 예산)에선 edge 9개, 재측정(10초)에선 4개** → 순수 예산 부족(데이터는 clean). 버려진 4-edge 값들도 기존 offset과 8~24ms 이내 일치.

→ `probe.ps1` `$RemeasureBudgetMs` **10000→15000**. cap은 *상한*이라 빠른 호스트(이미 6초에 edge 8~10개)는 일찍 accept하고 빠져나가므로 비용 0. 느린 호스트만 5개 도달할 시간을 더 받음. edge 게이트(`MinAcceptedEdges=5`)는 정확도/안전 보장이라 그대로 유지. (release 사본은 이미 15000이었음 → src가 뒤처졌던 것.)

### 빠른 측정(Fast Measurement)

"20초를 못 기다리는 사용자"용 저정확도 1회성 측정. 설계/계획: `docs/superpowers/specs/2026-05-25-fast-measurement-design.md`, `docs/superpowers/plans/2026-05-25-fast-measurement.md`.

- **알고리즘(신규 함수 0개)**: 기존 `Invoke-AdaptiveMultiSample`을 `-TargetWindowMs 2500 -MinEdgeCount 1 -MaxTotalMs 5000`으로 1회 호출. `MinEdgeCount=1`이라 연장 루프 비활성화(5초 내 종료). edge 1~3개 → ±100~300ms, 0개(frozen) → ±500ms.
- **게이트 우회**: 재측정 게이트/delta 재시도 안 탐. 1회 결과를 그대로 채택·덮어쓰기(명시적 동작). 첫 측정으로도 사용 가능(LastMeasureAt 불필요).
- **서버**: state에 `MeasureMode`('normal'|'fast')/`LastMeasureMode` 추가. Elapsed 핸들러 상단에 fast 분기(채택 후 `MeasureMode='normal'` 리셋). 신규 `POST /api/measure-fast`(`Start-FastMeasureFromRequest`). `/api/state`에 `lastMeasureMode` 노출.
- **UI**: `⚡ 빠른 측정` 버튼. 클릭 시 **최근(5분 이내, 기존 stale 임계값 재사용) 유효 측정이 있으면 `confirm()`로 덮어쓰기 확인**, 오래됨/없음이면 바로 실행. `duration-hint`를 `측정 최대 20초 · 재측정 최대 15초 · 빠른 측정 최대 5초`로 cap 3개 명시(요구사항). 결과 라벨에 `⚡ 빠른 측정 · … (정확도 낮음)` 접두. stale했던 `재측정 중... (10초)` → `(15초)` 수정.
- **테스트**: edge 1개에서 `Reduce-Samples`가 throw 없이 edge 결과 반환 회귀 추가. **40 passed**. (데드라인 Mock 테스트는 Pester v3가 dot-source 함수 Mock을 못 잡아 생략.)
- 배포본 `release/ServerTimeTools/src` 동기화 + zip 재생성.

### 주의

- 빠른 측정은 정밀 offset이 있어도 덮어쓴다(저정확도). 안전장치는 confirm + "정확도 낮음" 라벨뿐. F5 재측정은 `LastMeasureMode`가 다시 normal이 되어 기존 15초 정밀 경로를 탄다.

## Age 보정 조건부화 (ticket.interpark.com +N초 과보정 회귀 수정) (2026-05-24, Claude)

바로 아래 절(무조건 `Date+Age`)의 **회귀**를 잡은 후속 수정.

### 증상

사용자가 `ticket.interpark.com`을 측정하니 네이비즘보다 **6~8초 빠르게** 표시됨. edge가 8/8 전부 일치(±8ms)인데도 초 단위로 어긋남. 사용자 지적: "edge가 맞아도 차이 난다 = ms가 아닌 초 단위 = 다른 걸 보고 있다."

### 근본 원인

`Age`는 **정수 초**다. 무조건 `Date+Age`를 더하면, `Date`가 이미 라이브(매초 증가)인데 응답에 일정한 `Age=k`가 붙는 경우(CDN 재검증/edge별 캐시 상태) **모든 샘플이 +k초 평행이동** → edge끼리는 완벽히 일치(깔끔한 `edge-intersect`)하면서 표시가 k초 미래로 감. 티켓팅에서 가장 위험한 "빠른 표시". 실측: 같은 PC에서 `ticket.interpark.com`은 Age=0(120/120) 라이브였으나, 측정 순간의 edge 상태에 따라 v1이 +6초 과보정.

핵심: **라이브 `Date`면 raw `Date`가 이미 정답이라 `Age`가 불필요**. `Age`는 `Date`가 정지(frozen)일 때만 의미.

### 수정 (`measurement.ps1`)

- `Invoke-HeadProbe`: `Date+Age`를 미리 합치지 않고 `RawServerDateMs`/`AgeSec`를 따로 반환. 기본 `ServerDateMs`=raw(안전).
- `Set-AgeCorrectedServerDates` 신설: 윈도우 전체에서 raw `Date` span ≤ 2000ms **그리고** `Age>0` 존재일 때만 frozen으로 보고 `ServerDateMs=Date+Age*1000` 적용. 그 외엔 raw 유지. 결과에 `AgeCorrected` bool. `Reduce-Samples` 첫 줄에서 호출.
- `Get-EffectiveServerDateMs`는 산술 헬퍼로 강등(주석에 "frozen 판정 뒤에만 호출" 명시).
- 테스트: frozen→`AgeCorrected=true`, **live+Age=6→`AgeCorrected=false` 무과보정** 회귀 추가. 36 passed.

### 검증

같은 PC 실측: `ticket.interpark.com`→`AgeCorrected=false`, 표시−진짜UTC ≈ −0.3s(과보정 사라짐). `nol.interpark.com/ticket`→`AgeCorrected=true`, ≈ +0.4s(여전히 복구). 둘 다 sub-second.

### 주의 (아래 절 정정)

아래 "CDN Age 헤더 보정" 절의 "범용적으로 안전" 결론은 **부분적으로 틀렸다**. 일반 origin(Age 없음)·완전 frozen 캐시는 맞지만, **라이브 Date + 0 아닌 Age** 케이스에서 과보정했다. 이번 조건부화로 교정. (네이비즘 비교: nol에선 이 도구가 정확, ticket에선 v1이 틀리고 네이비즘이 옳았음 → 조건부 규칙이 양쪽 모두 정확.)

## CDN Age 헤더 보정 (CloudFront frozen-Date 대응) (2026-05-24, Claude)

사용자 보고: `https://nol.interpark.com/ticket`에서 upper-envelope 폴백이 뜨고, HEAD를 몇 초간 반복해도 같은 시각만 반환됨.

### 근본 원인

`nol.interpark.com`은 CloudFront 엣지 캐시 뒤에 있다. 캐시 응답은 `Date`를 **적재 시각에 고정**하고(예: `:13`에 고정), 경과 시간은 `Age` 헤더(초, RFC 9111)로 노출한다. 기존 코드는 `Date`만 읽고 `N→N+1` 전환만 edge로 검출하므로:
- `Date`가 안 움직임 → edge 0개 → `upper-envelope` 폴백.
- 폴백 offset이 고정된 `:13` 기준이라 표시 시각이 정지·드리프트.

실측: raw Date 초 = `13`(고정), `Date+Age` 초 = `13,14,15,16,17,18,19,20`(정수 초 경계에서 깔끔히 증가).

### 수정

- `measurement.ps1` `Get-EffectiveServerDateMs` 신설: 실효 서버시각 = `Date + Age*1000`. Age는 정수 초 경계에서 증가하므로 결합값은 1초 해상도 라이브 클럭 → 기존 edge-intersect 파이프라인이 그대로 동작(ms 정밀 유지). Age 없으면 0 → Date 원본(일반 origin 무영향).
- `Invoke-HeadProbe`/`Invoke-RangeGetDateProbe`: `Age` 헤더 읽어 `serverDateMs`에 반영.
- 테스트 4건 추가(`Get-EffectiveServerDateMs` 3 + frozen-Date+Age edge 통합 1). `Format-RfcDate` 테스트 헬퍼 추가.

### 검증

```
Invoke-Pester tests\Measurement.Tests.ps1,tests\Anchor.Tests.ps1,tests\Ntp.Tests.ps1  → Passed: 35 Failed: 0
```

실사이트(nol.interpark.com): `upper-envelope` → `edge-intersect`, edge 9개, 교집합 폭 ~19ms, RTT median 17ms.

### 범용성 검증

7개 사이트 조사: google/github/cloudflare/interpark.com/ticket.interpark.com/melon티켓 = live Date+Age없음(→ +0 무변화), nol.interpark.com = frozen Date+Age(→ 복구). "live Date + Age 동시" 케이스는 없었고 RFC 비준수. 그런 변종도 Age 매초 증가 시 결합값 2초/초 → edge 필터(900~1100ms)에 걸려 자동 폴백.

### 네이비즘 ~10초 차이 진단 (사용자 보고)

`nol.interpark.com`에서 네이비즘 대비 ~10초 차이. google live Date(독립 기준)와 동시 비교: `Date+Age`=진짜 UTC ±0.5초, 전체 파이프라인 표시값 ±0.06초. frozen Date와 실제 차이(=Age값, ≈10초)가 곧 격차. **네이비즘이 Age 보정 없이 캐시 Date를 읽어 ~10초 뒤처진 것이고, 이 도구가 정확.** (사용자 실행 환경: ServerTimeProbe.exe는 옆 src를 실행하므로 release/src 동기화 필수.)

### 주의

- Age는 정수 초라 결합값은 초 해상도(일반 Date와 동일). sub-second는 edge intersection이 핀하므로 정밀도 손실 없음.
- 라이브 `Date`를 주면서 동시에 `Age`도 보내는 비정상 프록시에선 과보정 가능하나, RFC상 캐시는 origin의 Date를 보존하므로 정상 동작.
- 배포본 `release/ServerTimeTools/src/measurement.ps1` 동기화 + zip 재생성 완료.

## 재측정 정책·안전마진·교집합 audit·문서 통합 (2026-05-24, Claude)

교집합 전환(아래 절)에 이어 같은 날 추가 작업.

### 재측정 정책 (F1/F2)

- `Get-RemeasureAttemptDecision` 신설(`measurement.ps1`): 타겟 변경/첫 측정은 edge 적어도 수용, 진짜 재측정은 `acceptedCount < 5`면 `fail-insufficient`(적은 edge로 갱신 안 함, 기존 offset 유지).
- `probe.ps1` 재측정 액션: 위 판정 + 15초 하드캡(2회 시도 공유 예산). 실패 시 `LastRemeasureResult='failed-insufficient-edges'`. 타겟 변경은 무제한.
- `Invoke-AdaptiveMultiSample -MaxTotalMs`: Stopwatch 데드라인. 곧 시작할 요청의 timeout만큼 여유를 두고 새 요청 중단 → in-flight 포함 캡 보장. 0=무제한. `Test-ShouldExtendWindow`로 연장 조건 순수함수화(method가 `edge*`이고 edge<MinEdgeCount).
- `clock.js`: `failed-insufficient-edges` 상태 메시지 추가.

### 적응형 안전마진

- `clock.js`: 고정 30ms → `max(30, rttMedianMs*0.3)`. RTT 비대칭(업로드 정체)이 표시를 빠르게 미는 위험이 RTT에 비례하므로 마진도 비례. stats 줄에 실제 마진 표시.

### 교집합 과신 audit (사용자 의문 "계속 성공으로 뜬다")

- 몬테카를로 800회: 대칭 조건 coverage 100% 정상. 그러나 RTT 비대칭 +40/+80ms에서도 `edge-intersect`가 100% 뜨면서 진짜 θ가 보고 ± 밖에 98~99% → 교집합은 공통 편향을 못 잡는다(상호 일치 ≠ 정확).
- 대응(코드 버그 아님, 정직성): `methodLabel`에서 ✓/"전부 일치" 제거 → "상호 일치(정확도 보장 아님)". stats의 ±를 교집합 계열은 "일치폭 ±N(비대칭 미반영)"으로 표기.

### 정리(죽은 코드)

- `Select-EdgeOffsetCandidates`, `Invoke-MultiSample` 제거(미사용). RTT 임계값을 `Get-RttThreshold`로 통일.

### 문서 통합 (docs 3개로)

- `docs/superpowers/`(초기 Node/CLI 설계·계획 아카이브), 루트 `bash.exe.stackdump` 삭제.
- `프로젝트_전체_설명.md` + `성능분석.md` + `naver-clock-vs-date-header.md` + `2026-05-02-phase-delay-fix.md` → **`docs/프로젝트_기술문서.md`** 로 통합(stale 내용 교정). 따라서 2026-05-08 절의 "phase-delay-fix.md는 유지" 지시는 무효 — 내용은 기술문서 §10 변경이력에 흡수됨.
- `방법비교_*.html` → `알고리즘_설명.html`의 13~14장으로 흡수. `docs/README.md`는 3-문서 인덱스로 갱신.
- 배포본 `release/ServerTimeTools/`의 `src` 동기화 + zip 재생성(새 알고리즘 반영).

## Edge 오프셋: 중앙값 → 1초 격자 교집합(하이브리드) 전환 (2026-05-24, Claude)

기존 edge 추정은 각 edge의 중점 offset들을 **독립 측정**으로 보고 median을 냈다(`method='edge'`). 이를 **1초 격자 제약을 활용한 교집합 추정**으로 바꿨다.

### 결정 근거

오프셋 θ는 측정 윈도우 내내 상수이고, 서버 초 경계는 PC 시간축에서 정확히 1000ms 간격이다. 각 edge는 인접 두 서버이벤트 PC시각 `L, R` 사이에 경계가 있다는 정보 → `θ ∈ (S−R, S−L)` 라는 **구간 제약**을 준다. θ는 하나이므로 모든 구간을 동시에 만족 = **교집합**.

균등노이즈 가정에서 교집합 중점이 MLE이고, edge 수 n에 대해 오차가 중앙값의 `1/√n`이 아니라 **`1/n`** 로 줄어든다(독일 탱크 문제). 워크드 예제: 동일 데이터에서 median 오차 45ms → 교집합 5ms.

### 하이브리드 (robustness)

교집합은 outlier 1개에 취약(공집합화)하므로 최대겹침(interval stabbing)으로 합의 부분집합을 찾는다:

- 전체 일치 → `edge-intersect`
- 일부 outlier 제외 후 일치(최대겹침 ≥ 2) → `edge-intersect-robust`
- 어떤 두 edge도 안 겹침(최대겹침 = 1) → `edge-median` (중점 median 폴백)
- edge 0개 → 기존 `upper-envelope` 폴백 유지

### 수정 내역

- `src/measurement.ps1`
  - `Get-EdgeDetails`: 각 edge에 `LowerMs = S−R`, `UpperMs = S−L` 추가(`OffsetMs`=중점=`(Lower+Upper)/2`).
  - `Get-HybridOffsetEstimate` 신설: O(n²) 스윕으로 최대겹침 영역 교집합, 동률은 전체 중점 median에 가까운 영역 선택. 반환 `OffsetMs/Method/UsedCount/WidthMs`.
  - `Reduce-Samples`: edge가 있으면 하이브리드 사용. `Ci95Ms`는 교집합 계열이면 `WidthMs/2`(hard bound), `edge-median`이면 기존 통계적 CI. `IntersectWidthMs` 필드 추가.
  - **버그픽스**: `Get-Median`이 `[int]($n/2)`의 은행가 반올림(`[int]1.5=2`)으로 홀수 n(3,7,11…)에서 가운데를 빗나갔다. `[Math]::Floor`로 교정. (기존 테스트가 n=5,9만 써서 안 드러났음.)
- `src/probe.ps1`, `src/http-server.ps1`: `IntersectWidthMs` state 전파, `/api/state`에 `edgeCount`·`intersectWidthMs`, `/api/samples`에 `intersectWidthMs` 노출. edge 요약에 `lowerMs/upperMs` 추가.
- `src/web/clock.js`: `methodLabel()` 추가. 항상 보이는 stats 줄과 측정 상세 요약에 사용된 방법을 한국어로 명시(예: `교집합 ✓ (edge 5개 전부 일치)`, `교집합 (이상치 1개 제외, edge 5/6개)`). 상세에 교집합 폭 표시.
- `tests/Measurement.Tests.ps1`: `Get-HybridOffsetEstimate` 4케이스, `Get-EdgeDetails` 경계, `Get-Median` n=3/n=7 회귀 추가. 기존 edge 테스트는 `edge-intersect`/오차<30ms로 갱신.

### 검증

```
Invoke-Pester -Script tests\Measurement.Tests.ps1,tests\Anchor.Tests.ps1,tests\Ntp.Tests.ps1
Passed: 19 Failed: 0
```

통합 확인(RTT 90ms, 5 edge): `edge-intersect`, 오차 10ms, 교집합 폭 20ms(±10ms).

### 주의

- 교집합 폭/2를 ±값으로 보고하므로 RTT 비대칭 같은 **계통오차는 잡지 못한다**(이건 median 방식도 동일). 폭은 통계적 산포가 아니라 feasible 영역의 hard bound다.
- `naver-time-api` 경로는 ms 정밀이라 edge 비대상 → `Reduce-PreciseSamples` 그대로(교집합 미적용, `IntersectWidthMs` 없음).

## 적응형 샘플링 전환 (2026-05-08, Codex)

`Count=50, IntervalMs=100` 고정 → **`IntervalMs=50` 고정 + `Count` 적응형(약 6초 윈도우)** 으로 변경.

### 결정 근거

샘플 1회 비용 ≈ `R+I`, 총 시간 `T = N(R+I)`, 윈도우 안 기대 edge 수 `E ≈ T/1000`.

Edge offset의 정밀도: edge는 인접 두 샘플 사이 PC 시간 간격이 `R+I`인 구간에서 균등분포라 가정 → `σ_edge ≈ (R+I)/√12`. median(E)의 표준오차:

```
σ_final ≈ 0.362 × √(1000(R+I)/N)
```

이 식에서 두 가지 결론:

1. `I`는 작을수록 시간·정밀도 양쪽 이득. 서버 매너상 하한 50ms 채택.
2. 시간은 RTT가 아니라 "필요한 edge 수"가 결정. 안정 median 위해 E≥5~6 → 윈도우 ≈ 6초가 시간 하한.

따라서 `IntervalMs=50` 고정, `Count = ceil(6000/(R+50))`을 [10, 60]로 클램프하면 사이트 무관 약 6초 측정 + 일관된 정확도가 나옴.

이론치 σ_final: RTT 50ms→±15ms, 150ms→±25ms, 300ms→±37ms. 실측은 1.5배(±20~55ms)로 본다. CLAUDE.md 목표 ±50ms를 RTT 200ms 이하에서 충족.

### 수정 내역

- `src/measurement.ps1`: `Invoke-AdaptiveMultiSample` 신설. 첫 3샘플로 RTT median 추정 → `Count` 결정 → 잔여 샘플 채움. `Invoke-MultiSample`은 호환용으로 남김.
- `src/probe.ps1`: 초기 측정과 F5 재측정 모두 `Invoke-AdaptiveMultiSample`로 교체.
- `src/web/clock.js`: 상태 메시지 `(50샘플)` → `(약 6초)`.
- `docs/성능 예상.md` 삭제 (성능분석.md와 중복 stub).
- `docs/성능분석.md`: 적응형 절차와 파라미터 최적화 절 추가, "50회/50샘플" 표현 일괄 갱신.
- `docs/프로젝트_전체_설명.md`, `README.md`: 50샘플 표현 일괄 갱신.
- `docs/2026-05-02-phase-delay-fix.md`는 과거 변경 기록이므로 유지.

### 주의

- 매우 큰 RTT(>500ms)에서는 `MinCount=10` 때문에 6초보다 길어질 수 있음. 의도된 동작.
- 네이버 API 경로는 ms 정밀이라 edge detection 비대상이지만, 같은 적응형 로직을 통일 적용.
- 동작 검증은 측정 후 `/api/state`의 `acceptedCount`(=edge 수)가 5 이상인지 확인하면 됨.

## 현재 구현 메모 (2026-05-03, Codex)

이 저장소의 현재 실행 코드는 아래 장기 설계안(Node.js/NAS 서비스)이 아니라 **Windows PowerShell 로컬 GUI 도구**다.

- 진입점: `ServerTimeProbe.exe` 또는 `run.bat` -> `src/probe.ps1`
- 로컬 서버: `src/http-server.ps1`, `http://127.0.0.1:8765/`
- 웹 UI: `src/web/index.html`, `src/web/clock.js`, `src/web/clock.css`
- clicker GUI: `addons/auto-clicker-gui/dist/ServerTimeClicker.exe`
- 배포 압축: `release/ServerTimeTools.zip`
- 측정 대상 기본값: 없음. 브라우저 입력창에서 URL을 입력한다.
- `src/probe.ps1`는 `-TargetUrl` 파라미터를 받을 수 있다. `https://naver.com/`을 입력하면 네이버 시계 API 경로를 사용한다.
- 테스트: `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Script tests\Measurement.Tests.ps1,tests\Anchor.Tests.ps1,tests\Ntp.Tests.ps1"`

### 2026-05-02 위상지연 수정 내역

사용자가 "서버 시간을 정확히 측정해서 GUI로 보여주는데 위상지연이 생긴다"고 보고했고, 이어서 "1분 주기 재측정하지 말고 F5 새로고침할 때만 재측정"을 요구했다.

수정 요약:

- `src/measurement.ps1`
  - 기존 `Get-OffsetMs`는 HTTP `Date` 헤더의 초 단위 양자화를 평균 보정한다는 이유로 항상 `+500ms`를 더했다.
  - 이 방식은 실제 화면에서 초 위상이 평균적으로 밀리는 원인이 될 수 있어, 기본 offset은 raw Cristian offset으로 바꿨다.
  - `QuantizationCorrectionMs` 선택 인자를 추가해 명시적으로만 `+500ms`를 적용할 수 있게 했다.
  - `Invoke-HeadProbe`는 `RawOffsetMs`, 기존 호환용 `OffsetMs`, `ServerDateMs`, `PcAtT2Ms`를 함께 반환한다.
  - `Reduce-Samples`는 이제 Date 헤더가 `N초 -> N+1초`로 증가하는 transition을 시간순으로 찾아 edge offset을 먼저 계산한다.
  - edge가 하나도 보이지 않는 비정상/캐시 Date 상황에서만 raw offset upper-envelope 방식으로 fallback한다.

- `src/http-server.ps1`
  - `/` 또는 `/index.html` 요청 때만 `MeasureTimer.Start()`를 호출한다.
  - 첫 페이지 로드는 제외하고, 이후 브라우저 F5 새로고침 또는 페이지 재진입 때만 재측정한다.
  - `state.Status -ne 'measuring'`와 `-not $state.MeasureTimer.Enabled` 조건으로 중복 측정을 막는다.

- `src/probe.ps1`
  - `MeasureTimer.Interval = 100`, `AutoReset = $false`인 one-shot 타이머를 유지한다.
  - 1분 자동 재측정은 없다.
  - 초기 측정은 50샘플이다.
  - F5 재측정도 50샘플을 사용한다.
  - 재측정 offset이 기존 offset과 100ms 이내면 새 값을 반영한다.
  - 100ms를 초과하면 50샘플 재측정을 한 번 더 수행한다.
  - 2회차도 100ms를 초과하면 새 값은 버리고 기존 offset을 유지한다.
  - 재측정은 `TargetUrl` 원본을 사용한다. 네이버 측정도 `https://naver.com/` 그대로 재측정해야 하므로 host만 조합해 `http://host/`로 만들면 안 된다.
  - NTP 타이머는 기존처럼 10분 주기 표시 정보용이며 offset 보정에는 쓰지 않는다.

- `src/web/clock.js`
  - `/api/state` 응답마다 기준 시각을 즉시 점프시키던 동작을 완화했다.
  - 새 기준과 현재 표시 추정값 차이가 120ms 초과면 즉시 동기화한다.
  - 120ms 이하면 `slewRemainingMs`로 누적한 뒤 렌더 루프에서 천천히 반영한다.
  - 목적은 측정값의 작은 흔들림이 초침/프로그레스의 위상 점프로 보이지 않게 하는 것이다.
  - F5 재측정 UI는 `재측정 중... (50샘플)`, rejected 시 `재측정 편차 Nms 초과: 기존값 유지`를 보여준다.

- `tests/Measurement.Tests.ps1`
  - raw offset 기본 동작, 명시적 양자화 보정, upper-envelope 방식 회귀 테스트를 추가/수정했다.

- `tests/Ntp.Tests.ps1`
  - PowerShell 5.1 호환을 위해 `0u` 리터럴을 `[uint32]0`으로 바꿨다.

- `README.md`
  - 알고리즘 설명을 `Cristian + 50샘플 + RTT 필터 + Date 초 경계 상한값 추정`으로 맞췄다.
  - 재측정 정책을 `F5 새로고침 시 백그라운드 재측정`으로 맞췄다.

검증 결과:

```
Invoke-Pester -Script tests\Measurement.Tests.ps1,tests\Anchor.Tests.ps1,tests\Ntp.Tests.ps1
Passed: 13 Failed: 0
```

주의:

- `README.md`의 장시간 안정성 검증 항목 중 과거의 "1분마다 자동 측정" 전제와 충돌하는 내용이 있으면 F5 수동 재측정 정책을 우선한다.
- HTTP `Date` 헤더는 초 단위라 밀리초 정밀도는 직접 제공되지 않는다. 현재 구현은 초 경계 근처 샘플을 통계적으로 고르는 방식이다.
- 실제 정확도는 대상 서버가 `Date` 헤더를 언제 갱신하는지, CDN/프록시가 개입하는지, RTT 비대칭이 얼마나 큰지에 좌우된다.

## 프로젝트 목표

특정 웹사이트(예: `ticket.interpark.com`)의 서버 시각을 가능한 한 정확하게 추정하여 사용자에게 실시간으로 보여주는 웹 서비스를 만든다. 네이비즘(time.navyism.com)과 동일한 컨셉이지만, **정확도를 더 끌어올리는 것**을 핵심 목표로 한다.

목표 정확도: **±50ms 이내** (네이비즘은 추정 ±100~500ms 수준).

## 운영 환경

- **호스팅**: Synology NAS (DS218+), DSM 7.x
- **NAS 시계**: NTP로 `time.kriss.re.kr`와 동기화 완료. 이 NAS의 시계를 기준점(reference)으로 신뢰한다.
- **접근**: NAS는 가정용 인터넷에 연결되어 있고, DDNS 또는 포트포워딩으로 외부 접근 가능하다고 가정.

## 핵심 원리 (반드시 이대로 구현할 것)

대상 서버의 시각을 알아내는 방법은 HTTP 응답의 `Date` 헤더를 읽는 것이다. 이 헤더는 RFC 9110에 정의되어 있고, 거의 모든 HTTP 서버가 응답에 포함시킨다.

문제는 두 가지:
1. `Date` 헤더는 **초 단위 해상도**다. 밀리초는 직접 못 읽는다.
2. 네트워크 RTT(왕복 지연) 때문에 받은 Date는 이미 과거 시각이다.

이 두 문제를 아래 기법들로 해결한다.

## 정확도 향상 기법 (모두 구현 필수)

### 1. RTT 기반 오프셋 보정 (Cristian's Algorithm)

요청 보낸 시각 `t1`, 응답 받은 시각 `t2`, 응답의 Date 헤더 값 `Ts`라 할 때:

```
실제 서버 시각(응답 시점) ≈ Ts + RTT/2
오프셋 = (Ts + RTT/2) - NAS의 t2 시각
```

이 오프셋을 NAS 현재 시각에 더하면 대상 서버의 현재 추정 시각이 된다.

### 2. 다중 샘플링 + RTT 필터링

- 한 번 측정으로 끝내지 않고, **50~100회 샘플링**한다.
- 샘플 간 간격은 50~100ms (대상 서버에 부담 주지 않는 선).
- RTT가 짧을수록 비대칭 가능성이 작고 정확하다. **RTT 하위 10~20% 샘플만 채택**한다.
- 채택한 샘플들의 오프셋 **중앙값(median)**을 최종 오프셋으로 쓴다. 평균은 outlier에 약하므로 쓰지 않는다.

### 3. Edge Detection으로 ms 정밀도 추출 (선택 구현, MVP 후 추가)

`Date` 헤더가 `07:28:00`에서 `07:28:01`로 바뀌는 **순간**을 짧은 간격(20~50ms) 폴링으로 포착하면, 그 순간이 대상 서버의 정수 초 경계다. 이 경계 시각을 NAS 시계에 매핑하면 ms 정밀도 오프셋을 얻을 수 있다.

MVP에는 빼고, v2 기능으로 분리.

### 4. 클럭 드리프트 대응

오프셋은 한 번 측정하고 끝이 아니다. NAS 시계와 대상 서버 시계의 흐름 속도가 미세하게 달라서 시간이 갈수록 어긋난다. **30초~1분마다 백그라운드에서 재측정**하여 오프셋을 갱신한다.

### 5. Monotonic Clock 사용

RTT 측정과 ms 보간에는 **`process.hrtime.bigint()` 또는 `performance.now()`**(Node.js 16+)를 쓴다. `Date.now()`는 NTP가 시계를 점프시키면 음수 RTT가 나올 수 있어 부적합.

### 6. HEAD 요청 우선

본문 안 받으면 RTT 작아지고 일관성 좋아진다. 대상 서버가 HEAD를 거부하면(405) GET으로 폴백하되 `Range: bytes=0-0`로 1바이트만 받기.

### 7. Keep-Alive 연결 재사용

샘플링할 때마다 TCP 핸드셰이크하면 RTT가 들쭉날쭉해진다. HTTP keep-alive로 같은 연결 재사용. Node.js에서는 `http.Agent({ keepAlive: true })` 사용.

## 아키텍처

```
[사용자 브라우저]
      │ HTTPS
      ▼
[NAS의 Node.js 서버]
   ├─ /api/measure?host=...  : 오프셋 측정 (캐시됨)
   ├─ /api/time?host=...     : 현재 추정 시각 반환 (밀리초)
   └─ /                      : 정적 프론트엔드
      │
      │ HTTP HEAD/GET (서버 ↔ 서버, CORS 무관)
      ▼
[대상 서버 (예: ticket.interpark.com)]
```

### 클라이언트(브라우저) 동작

- 페이지 로드 시 한 번 `/api/time`에 요청해서 `(서버추정시각, 클라이언트의 performance.now() 시점)` 쌍을 받음
- 그 후로는 클라이언트의 `performance.now()` 증가분만큼 더해서 매 16ms마다(60fps) 화면 갱신
- **클라이언트는 NAS에 매초 폴링하지 않는다**. 30초~1분마다만 재동기화.

### 서버 동작

- 처음 들어온 호스트는 측정 후 결과를 메모리 캐시
- 캐시된 호스트는 백그라운드 워커가 1분마다 재측정해서 오프셋 갱신
- 같은 호스트에 동시 요청 와도 측정은 한 번만(in-flight 요청 dedup)

## 기술 스택

- **백엔드**: Node.js 20+ / TypeScript / Fastify (또는 Express, 가벼운 쪽)
- **HTTP 클라이언트**: `undici` (Node.js 내장 fetch보다 keep-alive 제어 깔끔)
- **프론트엔드**: 단일 HTML 파일 + 바닐라 JS. React 등 프레임워크 불필요
- **캐시**: 메모리(Map). Redis 등 외부 의존성 추가하지 말 것
- **로깅**: `pino` (구조화 로그)
- **배포**: Docker 컨테이너로 패키징해서 DSM의 Container Manager에서 실행

## 코드 품질 기준

- TypeScript strict 모드
- 모든 외부 입력(`host` 파라미터)은 검증: 도메인 형식 검사, 사설 IP 차단(SSRF 방지), 프로토콜은 https/http만
- 에러는 적절한 HTTP 상태 코드로(400/502/504 등). 사용자에게 스택트레이스 노출 금지
- 테스트는 Vitest. 핵심 알고리즘(중앙값 계산, 오프셋 계산, RTT 필터링)은 단위 테스트 필수

## 보안 / 운영 주의사항

- **SSRF 방지**: 사용자가 `localhost`, `127.0.0.1`, `192.168.x.x`, `10.x.x.x`, `169.254.x.x` 같은 내부 주소를 host로 넣으면 거부. NAS 내부망이 노출될 수 있음.
- **레이트 리밋**: 같은 클라이언트 IP가 초당 10회 이상 측정 요청 못 하게 제한
- **대상 서버 보호**: 한 호스트에 대해 측정은 1분에 1번만. 외부 사이트에 트래픽 쏟아붓지 않기
- **타임아웃**: HTTP 요청 5초 타임아웃. 안 그러면 측정 워커가 멈출 수 있음

## 하지 말아야 할 것 (Anti-patterns)

- ❌ 클라이언트 브라우저에서 직접 대상 서버에 fetch 보내기 (CORS로 막힘)
- ❌ `Date.now()`로 RTT 측정 (NTP 점프에 취약)
- ❌ 평균 오프셋 사용 (outlier에 약함, 중앙값 쓸 것)
- ❌ 한 번만 측정하고 끝내기 (드리프트 누적)
- ❌ 매 화면 갱신마다 서버 호출 (대상 서버에 부담 + 느림)
- ❌ 사용자 입력 host를 검증 없이 fetch (SSRF 위험)
- ❌ React/Next.js 같은 무거운 프레임워크 (이 프로젝트엔 과함)

## 측정 결과 검증 방법

구현 후 다음으로 검증:
1. `time.navyism.com`을 host로 측정 → 네이비즘이 자기 서버 시각 보여주니 비교 가능
2. `time.is`와 시각 비교 (browser dev console에서 둘 다 띄워놓고 육안 확인)
3. NAS에서 `chronyc tracking`으로 NAS 자체 오차 확인 후, 그걸 감안하고 비교

## 단계별 구현 순서 (이대로 진행할 것)

1. **MVP**: HEAD 요청 1회 → Date 헤더 파싱 → 화면에 표시. 정확도 무시
2. **다중 샘플링 + 중앙값**: 100회 샘플, RTT 필터, 중앙값 오프셋 계산
3. **백그라운드 재측정 + 캐시**: 1분마다 자동 갱신
4. **클라이언트 보간**: performance.now()로 ms 단위 매끄럽게 표시
5. **에지 검출(v2)**: ms 정밀도 오프셋
6. **다중 호스트 동시 표시 + UI 개선**

각 단계 끝날 때마다 동작 확인하고 다음으로 넘어갈 것. 한 번에 다 짜려고 하지 말 것.

## 참고 자료

- RFC 9110 (HTTP Semantics) - Date 헤더 정의
- Cristian's Algorithm - 클럭 동기화 알고리즘
- NTP 문서 - 다중 샘플 + RTT 필터링 기법의 원조
- 네이비즘 (https://time.navyism.com) - 비교 대상 서비스
