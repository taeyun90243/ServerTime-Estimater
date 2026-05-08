# 서버시간 측정 서비스 (Server Time Estimator)

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
