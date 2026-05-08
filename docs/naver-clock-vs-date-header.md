# 네이버 시계 API와 naver.com Date 헤더의 차이

## 문제

네이버 시계, 네이비즘, 우리 프로젝트가 모두 "네이버 서버시간"처럼 보이지만 실제 기준은 서로 다르다.

- 네이버 시계: 네이버 검색 위젯의 전용 시간 API
- 네이비즘: 자체 서버가 계산한 기준값을 HTML에 박아 넣고 브라우저에서 표시
- 우리 프로젝트: 대상 URL의 HTTP `Date` 헤더를 여러 번 측정해서 초 경계를 추정

그래서 `naver.com`을 대상으로 재도 네이버 시계와 거의 1초 가까이 다르게 보일 수 있다. 이것은 단순 버그라기보다 "무엇을 서버시간이라고 부를 것인가"의 기준 차이다.

## 관찰한 근거

### 네이버 시계

`docs/references/네이버 서버시간.txt` 안의 네이버 검색 시계 위젯은 다음 모듈을 로드한다.

```js
Domestic: "https://ssl.pstatic.net/sstatic/fe/sfe/clock/Domestic_230810"
```

설정에는 전용 시간 API가 들어 있다.

```js
sApiNowTime: "https://ts-proxy.naver.com/dcontent/util/time.naver"
passportKey: "9964bf6d4645e3a94ca5e72c231b50a3c18fb688"
format: "yyyy/MM/dd/HH/mm/ss/SSS"
site: "naver"
```

직접 호출하면 밀리초 포함 시간이 내려온다.

```js
nhntime("2026/05/02/19/30/20/791");
```

네이버 JS의 보정 방식은 다음 구조다.

```text
요청 직전 Date.now() 저장
밀리초 포함 서버시각 수신
응답 도착 Date.now() 저장
서버시각 += RTT / 2
deviceGap = 보정된 서버시각 - 클라이언트 현재시각
이후 Date.now() + deviceGap 으로 표시
```

즉 네이버 시계는 HTTP `Date` 헤더를 추정하지 않는다. 시계 표시용 API에서 밀리초 단위 시간을 직접 받는다.

### 네이비즘

`docs/references/네이비즘 소스.txt`에는 페이지 생성 시점의 값이 박혀 있다.

```js
var mgap = 528;
var thisTime2 = 1777715528;
var mgval = new Date().getTime() - (thisTime2 * 1000 + mgap);
...
mgval = mgval + 900;
```

`time.js`의 시간 계산은 다음 형태다.

```js
function time() {
  return Math.floor((new Date().getTime() - mgval - 0) / 1000);
}
```

마지막 `mgval += 900`은 표시 시간을 약 900ms 늦추는 효과가 있다. 네이비즘은 정확한 밀리초 표시보다 안정적인 초 표시와 실사용 안전성을 우선한 흔적이 있다.

### 우리 프로젝트

우리 프로젝트는 `src/measurement.ps1`에서 대상 URL에 `HEAD` 요청을 보내고 `Date` 헤더를 읽는다.

```text
Date: Sat, 02 May 2026 10:13:24 GMT
```

HTTP `Date` 헤더는 초 단위다. 밀리초가 없다. 그래서 여러 샘플을 모아 `Date`가 `N초 -> N+1초`로 바뀌는 순간을 추정한다.

이 방식은 일반 사이트에는 현실적인 최선이다. 하지만 네이버 시계 API처럼 밀리초를 직접 주는 공식 API와 비교하면 불리하다.

## 왜 차이가 나는가

`naver.com`의 HTTP `Date` 헤더는 "네이버 공식 시계"가 아니다.

`https://naver.com/` 요청은 다음 중 어느 계층에서 응답이 만들어질 수 있다.

```text
내 PC
-> ISP / DNS
-> CDN edge 또는 프록시
-> 로드밸런서
-> 네이버 프론트 서버
-> 캐시 / 리다이렉트 / 보안 장비
```

HTTP `Date` 헤더는 애플리케이션 서버가 붙일 수도 있고, CDN/프록시 계층이 붙일 수도 있다. 외부에서는 정확히 어느 계층의 시각인지 알 수 없다.

반면 네이버 시계 API는 시계 위젯이 쓰라고 만든 별도 서비스다. 밀리초를 포함하고, JS가 RTT/2 보정까지 한다.

따라서 두 값은 모두 "네이버에서 나온 시간"일 수 있지만 같은 의미의 시간이 아니다.

## 티케팅 관점의 모순

티케팅에서 중요한 것은 표준시 자체가 아니라 "요청을 받은 서버가 오픈 여부를 판정하는 시각"이다.

따라서 다음 질문이 핵심이다.

```text
내가 클릭해서 보내는 요청은 어느 서버/도메인/엔드포인트에서 오픈 판정을 받는가?
```

### 네이버 시계 API가 더 적절한 경우

- 목표가 "네이버 검색 시계와 같은 시간"을 보는 것일 때
- 이벤트가 네이버의 공식 시계 기준으로 안내될 때
- 단순 표준시/참고시가 필요할 때

이 경우 `ts-proxy.naver.com/dcontent/util/time.naver?site=naver`가 가장 직접적인 기준이다.

### naver.com Date 헤더가 더 적절할 수 있는 경우

- 실제 티케팅 요청이 `naver.com` 도메인 또는 그와 같은 HTTP 경로에서 판정될 때
- 네이버 시계 API가 아니라 실제 서비스 프론트 계층의 시간을 보고 싶을 때

이 경우 네이버 시계 API보다 `naver.com` 또는 실제 예매 URL의 `Date` 헤더가 판정 계층에 더 가까울 수 있다. 다만 초 단위라 밀리초 정확도는 낮다.

### 둘 다 부적절한 경우

실제 오픈 판정이 다른 API 도메인에서 일어난다면 둘 다 부적절하다.

예:

```text
화면: naver.com
실제 예매 요청: ticket-api.example.naver.com/open
```

이 경우 봐야 할 것은 `naver.com`도 네이버 시계 API도 아니라 실제 예매 API 도메인이다.

## 현재 판단

네이버 시계와 맞추는 목적이라면 네이버 시계 API를 써야 한다.

```text
정답 기준: ts-proxy.naver.com/dcontent/util/time.naver?site=naver
```

하지만 `naver.com`에서 실제 티케팅을 한다는 가정이면 더 비판적으로 봐야 한다.

- 네이버 시계 API는 정밀하지만 티케팅 판정 서버와 같다는 보장이 없다.
- `naver.com` Date 헤더는 부정확하지만 실제 요청 경로에 더 가까울 수 있다.
- 가장 좋은 기준은 실제 예매 요청이 들어가는 URL의 시간이다.

## 구현 방향 제안

일반 모드:

```text
대상 URL의 HTTP Date 헤더 측정
```

네이버 시계 비교 모드:

```text
네이버 시계 API 사용
```

실전 티케팅 모드:

```text
사용자가 실제 예매 페이지 또는 실제 API URL을 넣는다.
가능하면 그 URL의 Date 헤더를 측정한다.
네이버 시계는 참고값으로만 표시한다.
```

## Claude에게 물어볼 질문

1. `naver.com`에서 실제 티케팅이 열린다고 가정할 때, 네이버 시계 API와 `naver.com` Date 헤더 중 무엇이 더 좋은 기준인가?
2. HTTP `Date` 헤더가 CDN/프록시 계층에서 생성될 수 있다는 점을 감안하면, 실제 판정 서버에 가까운 시간을 어떻게 추정해야 하는가?
3. 사용자가 실제 예매 API URL을 모르는 경우, 어떤 휴리스틱으로 가장 의미 있는 측정 URL을 선택할 수 있는가?
4. 네이버 시계 API 같은 공식 ms API가 존재하는 사이트에서는 Date 헤더 측정보다 API를 우선해야 하는가, 아니면 실전 판정 서버 기준과 분리해서 표시해야 하는가?
