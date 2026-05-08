# macOS 서버시간 측정기

Windows용 `ServerTimeProbe`의 macOS 포팅판. Python 3 표준 라이브러리만 사용.

## 요구사항

- macOS 12 이상
- Python 3.9 이상 (Xcode Command Line Tools에 포함)

`python3`가 없다면 터미널에서 한 번만:

```
xcode-select --install
```

## 실행

1. 이 폴더(`mac/`) 전체를 다운로드
2. Finder에서 `run.command` 더블클릭
3. (첫 실행) "확인되지 않은 개발자" 경고 → 우클릭 > 열기 > 열기
4. 터미널이 열리며 `http://127.0.0.1:8765/`가 자동으로 브라우저에 뜸
5. 입력창에 측정할 URL을 넣고 약 6초 대기
6. F5 새로고침으로 재측정
7. 종료: 터미널 창에서 Ctrl+C 또는 창 닫기

## 명령행 옵션

```
python3 server_time_probe.py [--target-url URL] [--port 8765] [--no-browser]
```

## Windows 버전과의 차이

- auto-clicker GUI는 미포함 (macOS Accessibility 권한/공증 이슈)
- NTP 표시 정보(`ntpInfo`)는 항상 `null` (1차 포팅에서 단순화)
- 그 외 측정 알고리즘과 UI는 동일

## 테스트

```
python3 -m unittest discover mac/tests
```
