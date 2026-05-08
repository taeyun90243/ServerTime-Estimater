# macOS 포팅 설계

작성일: 2026-05-09
대상: 서버시간 측정 서비스의 macOS 버전

## 목표

기존 Windows PowerShell 기반 로컬 GUI 도구(`ServerTimeProbe.exe` + 브라우저 UI)와 동일한 기능을 macOS에서 제공한다. 측정 정확도, 알고리즘, 사용자 경험은 Windows 버전과 동일하게 유지한다.

## 비목표 (Non-goals)

- auto-clicker GUI 포팅 (macOS Accessibility 권한/공증 이슈로 1차 제외)
- Windows 코드 변경 (Windows 빌드는 손대지 않음)
- NAS 배포용 Node.js 장기 설계안 구현 (별도 프로젝트)

## 격리 원칙

`mac/` 폴더 하나로 완전 자립. `mac/`만 따로 떼어 다른 Mac에 복사해도 동작해야 한다. `src/web/`을 공유 참조하지 않고 `mac/web/`으로 **복사**한다.

## 기술 선택

**Python 3** (표준 라이브러리만 사용).

근거:
- bash는 macOS의 `date`가 `%N`(나노초)를 지원하지 않아 ms 측정에 부적합하고, 자체 HTTP 서버 구현도 비현실적.
- Python 3는 macOS Xcode Command Line Tools(`xcode-select --install`) 한 번 설치로 사용 가능. 그 외 별도 의존성 없음.
- 표준 모듈로 충분: `http.client`(keep-alive HEAD probe), `http.server.ThreadingHTTPServer`(로컬 8765 서버), `time.monotonic_ns`(PowerShell `Stopwatch` 대응), `statistics.median`, `threading`, `json`.

## 파일 구조

```
mac/
├── run.command                  # 더블클릭 실행 진입점 (chmod +x)
├── server_time_probe.py         # 메인 진입점 (오케스트레이션 + HTTP 서버)
├── measurement.py               # HEAD probe, RTT 필터, edge detection, 적응형 샘플링
├── state.py                     # 측정 상태/오프셋 캐시 (스레드 안전)
├── web/                         # src/web/ 의 복사본 (index.html, clock.js, clock.css)
│   ├── index.html
│   ├── clock.js
│   └── clock.css
├── tests/
│   ├── test_measurement.py      # reduce/edge/adaptive count 회귀 테스트
│   └── __init__.py
└── README_MAC.md                # 설치/실행/문제해결 안내
```

Windows 측 파일(`src/`, `addons/`, `run.bat`, `tests/*.Tests.ps1` 등)은 변경하지 않는다.

## 구성요소 매핑

| Windows (PowerShell) | macOS (Python) |
|---|---|
| `src/probe.ps1` 오케스트레이션 | `server_time_probe.py` `main()` |
| `src/measurement.ps1` `Invoke-HeadProbe` | `measurement.py` `head_probe()` |
| `src/measurement.ps1` `Invoke-AdaptiveMultiSample` | `measurement.py` `adaptive_multi_sample()` |
| `src/measurement.ps1` `Reduce-Samples` | `measurement.py` `reduce_samples()` |
| `src/http-server.ps1` 8765 서버 | `ThreadingHTTPServer` + 커스텀 `BaseHTTPRequestHandler` |
| `src/web/*` | `mac/web/*` (복사본) |
| `run.bat` / `.exe` | `run.command` |
| `tests/Measurement.Tests.ps1` | `mac/tests/test_measurement.py` |

## 핵심 알고리즘 (Windows와 동일)

- Cristian's algorithm: `offset = (Ts + RTT/2) - t2`
- 적응형 샘플링: `IntervalMs=50` 고정, `Count = ceil(6000/(R_median+50))`을 `[10, 60]`로 클램프. 첫 3샘플로 RTT median 추정 후 잔여 채움.
- Edge detection: Date 헤더 `N초 → N+1초` transition 시각으로 정수 초 경계 매핑. edge가 없을 때만 raw upper-envelope fallback.
- 최종 오프셋: 채택 샘플의 median.
- F5 재측정: 1차 재측정 결과가 기존 offset과 100ms 이내면 채택, 초과 시 한 번 더 재측정, 그래도 100ms 초과면 기존값 유지.
- 첫 페이지 로드는 재측정 트리거에서 제외 (서버 시작 시 1회 측정 후, 이후 `/` 또는 `/index.html` 재요청 시에만 백그라운드 재측정).
- NTP 정보 표시: 1차 포팅에서는 단순화하여 macOS `sntp` 또는 `chronyc` 호출 없이 "표시용 NTP 정보" 항목은 비활성화 또는 "n/a"로 응답. (Windows 동작과 다른 유일한 부분 — README에 명시)

## HTTP 서버 동작

- 0.0.0.0이 아닌 `127.0.0.1:8765`만 바인딩.
- 라우트:
  - `GET /` 또는 `/index.html`: `web/index.html` 반환 + 서버 측에서 백그라운드 재측정 트리거 (단, 이미 measuring 상태가 아닐 때만).
  - `GET /clock.js`, `/clock.css`: 정적 파일.
  - `GET /api/state`: JSON `{status, offsetMs, acceptedCount, rttMedianMs, lastMeasuredAt, target, ntp}`.
  - `GET /api/measure?url=...`: 새 대상 URL로 측정 시작.
- 동시 요청은 `ThreadingHTTPServer`로 처리. 측정 작업은 별도 워커 스레드 1개에서 직렬 실행, `state` 객체는 `threading.Lock`으로 보호.

## UX

1. 사용자가 `mac/` 폴더를 받아 `run.command`를 더블클릭.
2. 터미널이 열리며 `python3 server_time_probe.py` 실행, 8765에서 listen, `open http://127.0.0.1:8765/` 호출.
3. 기본 브라우저에서 시계 페이지가 뜨고 사용자가 측정할 URL을 입력 → 측정 약 6초 후 시계 표시.
4. F5로 재측정.
5. 종료: 터미널 창에서 Ctrl+C 또는 창 닫기.

첫 실행 시 macOS Gatekeeper가 `run.command`를 차단할 수 있다. README에 우클릭 > 열기 1회 허용 절차를 명시한다.

## 테스트

`mac/tests/test_measurement.py` (`unittest`):

- `reduce_samples`: edge가 있는 케이스에서 edge 기반 offset이 선택되는지.
- `reduce_samples`: edge가 없는 케이스에서 upper-envelope fallback이 raw offset median을 반환하는지.
- 적응형 count: RTT median에 따라 `Count`가 `[10, 60]` 안에서 기대대로 산출되는지 (RTT 50/150/300ms 케이스).
- RTT 필터링: 하위 percentile만 채택되는지.

실행:
```
python3 -m unittest discover mac/tests
```

네트워크 통합 테스트는 포함하지 않는다 (외부 의존, 비결정적).

## 보안 / 안전

- 127.0.0.1 only 바인딩 (외부 노출 금지).
- 사용자 입력 URL은 `urllib.parse`로 파싱 후 scheme이 `http`/`https`인 경우만 허용.
- 1차 포팅에서는 SSRF 차단(사설 IP 거부)은 Windows 동작과 동일 수준으로만 (= 명시적 차단 없음, 로컬 도구 전제). 향후 NAS 배포 버전에서 강화.
- 5초 HTTP 타임아웃.

## 위험 / 미해결

- macOS `Date` 헤더 캐싱: CDN 경로에 따라 edge 검출이 Windows와 동일하게 동작하지 않을 수 있음. 동일 알고리즘이므로 Windows에서 보이는 한계가 그대로 보일 것.
- Python 3 미설치 환경: `run.command`가 `python3 --version` 체크 후 미설치 시 `xcode-select --install` 안내 메시지 출력.
- macOS 보안 경고: 미서명 `.command` 첫 실행 차단. README로 우회 안내.

## 산출물 체크리스트

- [ ] `mac/server_time_probe.py`
- [ ] `mac/measurement.py`
- [ ] `mac/state.py`
- [ ] `mac/web/index.html`, `clock.js`, `clock.css` (복사)
- [ ] `mac/run.command` (실행 권한 부여)
- [ ] `mac/tests/test_measurement.py`
- [ ] `mac/README_MAC.md`
- [ ] `mac/tests/test_measurement.py` 통과 확인
