# 서버시간 측정 도구

사용자가 입력한 URL의 서버 시각을 ±50ms 정확도로 추정해 네이버 시계 스타일로 표시.

## 실행 방법

1. `ServerTimeProbe.exe` 또는 `run.bat` 더블클릭
2. 검정 콘솔 + 자동으로 브라우저에 시계 페이지 열림
3. 브라우저 상단 입력창에 측정할 URL 입력 후 `측정` 클릭
4. 종료: 콘솔에서 Ctrl+C

## 클릭 도구

서버시간에 맞춰 현재 마우스 위치를 클릭하려면:

```text
addons\auto-clicker-gui\dist\ServerTimeClicker.exe
```

사용 순서:

1. `ServerTimeProbe.exe`를 먼저 실행하고 URL 측정을 완료
2. `ServerTimeClicker.exe` 실행
3. 목표 시각 입력 후 `Arm`
4. 클릭할 위치에 마우스를 올려두기

처음에는 기본값을 그대로 쓰면 된다.

- `Lead ms`: 목표보다 몇 ms 먼저 클릭할지. 처음엔 `0`
- `Resync before ms`: 목표 몇 ms 전에 `/api/state`를 다시 읽을지. 기본 `3000`
- `Final spin ms`: 마지막 몇 ms 동안 Sleep 없이 정밀 대기할지. 기본 `25`

## 배포

Google Drive 등에 올릴 배포본은 아래 압축 파일을 사용한다.

```text
release\ServerTimeTools.zip
```

압축 안에는 `ServerTimeProbe.exe`, `ServerTimeClicker.exe`, `src\`와 사용 안내가 들어 있다.

## EXE 빌드

`run.bat` 대체 실행 파일을 다시 만들려면:

```bat
tools\server-time-probe-exe\build-run-exe.bat
```

결과:

```text
ServerTimeProbe.exe
```

이 EXE는 같은 프로젝트 폴더 안의 `src\probe.ps1`을 실행하는 런처다. 단독 파일만 복사해서는 동작하지 않고, `src` 폴더와 함께 있어야 한다.

빌드 중간 산출물은 `tools\build-artifacts\` 아래에 모은다.

## 요구사항

- Windows 10 / 11 (PowerShell 5.1 이상 기본 탑재)
- 인터넷 연결
- (선택) UDP 123 허용 — NTP 정보 표시용. 막혀있어도 도구는 정상 동작

## 문서

- `docs\README.md`: 문서별 용도와 우선순위
- `docs\프로젝트_전체_설명.md`: 현재 프로젝트 구조와 동작 방식
- `docs\성능분석.md`: 현재 구현 기준 성능 및 오차 분석

## 정확도

- 표시 시각 σ ≈ 21ms (95% CI ±42ms)
- 알고리즘: Cristian + 적응형 샘플링(약 6초) + RTT 필터 + Date 초 경계 검출
- PC 시계 절대 오프셋 자동 상쇄 (PC 시계가 부정확해도 표시값 정확)
- PC 시계 점프 방어: monotonic anchor + Stopwatch
- 첫 페이지 로드 후 F5 새로고침 시 적응형으로 재측정
- 재측정 offset이 기존값과 100ms 이내면 반영, 초과하면 한 번 더 재측정

## PC방에서 사용

가능. 단:
- PowerShell.exe 실행 가능해야 함 (게임 PC방은 거의 다 됨)
- 폴더째 USB에서 실행 가능
- NTP 차단된 환경에서도 정확도 영향 0 (NTP는 정보 표시 전용)

## 폴더 구조

```
.
├── ServerTimeProbe.exe      # run.bat 대체 실행 런처
├── run.bat                  # PowerShell 직접 실행 진입점
├── README.md
├── release/                 # 배포용 폴더/zip
├── addons/
│   └── auto-clicker-gui/    # Python GUI clicker 및 EXE
├── src/
│   ├── probe.ps1            # 메인 스크립트
│   ├── anchor.ps1           # Monotonic 시계 (PC 시계 점프 방어)
│   ├── measurement.ps1      # Cristian + 다중 샘플링 + 중앙값
│   ├── http-server.ps1      # 로컬 HTTP 서버 (127.0.0.1:8765)
│   ├── ntp.ps1              # NTP 정보 측정 (표시 전용)
│   ├── logger.ps1           # JSONL 일별 롤링 로그
│   └── web/                 # 정적 UI (HTML/CSS/JS)
├── tests/                   # Pester 단위 테스트
├── tools/                   # 빌드 도구와 중간 산출물
└── logs/                    # 자동 생성. 25일 후 자동 삭제
```

## 로그

`logs/probe-YYYYMMDD.jsonl`. 25일 후 자동 삭제.

이벤트 종류: `measure`, `measure_failed`, `ntp`, `ntp_failed`, `shutdown`.

## 안정성 검증 권장

- 실행 직후 `logs/probe-*.jsonl`에 초기 `measure` 라인 생성 확인
- F5 새로고침 후 추가 `measure` 라인 생성 확인
- 도구 실행 중 윈도우 시계 +30초 변경 → 표시값에 영향 없음 (anchor 효과)
- `https://time.is`와 동시 표시해 시각 차이 100ms 이내 육안 확인
