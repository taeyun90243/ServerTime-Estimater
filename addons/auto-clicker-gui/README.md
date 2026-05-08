# Server Time Clicker GUI

Python `tkinter` GUI clicker. 기존 서버시간 측정 도구의 `/api/state`를 읽고, 목표 서버시각(KST)에 현재 마우스 위치에서 왼쪽 클릭 1회를 실행한다.

기존 `src` 코드는 수정하지 않는다.

## 실행

1. 프로젝트 루트의 `ServerTimeProbe.exe` 또는 `run.bat`를 먼저 실행한다.
2. 브라우저에서 대상 URL 측정이 완료될 때까지 기다린다.
3. 이 폴더의 `run-gui.bat`를 실행한다.
4. 목표 시간을 입력하고 `Arm`을 누른다.
5. 클릭할 위치에 마우스를 올려 둔다.

목표 시간 형식:

```text
20:00:00.000
20:00:00
2026-05-02 20:00:00.000
2026/05/02 20:00:00.000
```

날짜를 생략하면 오늘 KST로 처리하고, 이미 지난 시간이면 내일로 처리한다.

## 기능

- `Refresh State`: `/api/state` 현재 측정 상태 확인
- `Arm`: 목표 서버시각에 클릭 예약
- `Cancel`: 예약 취소
- `Test Click`: 현재 마우스 위치에서 즉시 왼쪽 클릭 1회
- 클릭 완료 후 다시 목표시간을 바꿔 `Arm` 가능
- `Lead ms`: 목표보다 몇 ms 먼저 클릭 API를 호출할지 보정
- `Resync before ms`: 목표 직전 재동기화 시점
- `Final spin ms`: 마지막 busy-wait 구간

처음에는 아래 기본값 그대로 쓰면 된다.

```text
Lead ms: 0
Resync before ms: 3000
Final spin ms: 25
```

설정 의미:

- `Lead ms`: 목표 서버시각보다 미리 클릭을 호출하는 보정값. 클릭이 항상 늦게 먹히는 환경에서만 `10` 또는 `15`처럼 올려 테스트한다.
- `Resync before ms`: 목표 몇 ms 전에 `/api/state`를 다시 읽어 서버시간 기준을 갱신할지 정한다.
- `Final spin ms`: 마지막 몇 ms 동안 `sleep`을 쓰지 않고 계속 시간을 확인할지 정한다. `sleep`은 늦게 깨어날 수 있어서 마지막 구간만 정밀 대기한다.

## EXE 빌드

PyInstaller가 설치되어 있으면:

```bat
build-exe.bat
```

결과:

```text
dist\ServerTimeClicker.exe
```

PyInstaller가 없다면 설치가 필요하다.

```bat
python -m pip install pyinstaller
```
