# 2026-05-02 Phase Delay Fix

## Background

The app is currently a Windows PowerShell local server + browser GUI, not the older Node/NAS service described later in `CLAUDE.md`.

User report:

- The GUI clock had visible phase delay while showing estimated server time.
- The user explicitly requested no periodic 1-minute remeasurement.
- Remeasurement should happen only when the browser page is refreshed with F5 or re-entered.

## Root Cause

The previous measurement path treated the HTTP `Date` header as a second-granular timestamp and always added `+500ms`:

```powershell
($ServerDateMs + $RttMs / 2 + 500) - $PcAtT2Ms
```

That estimates the middle of the unknown one-second Date bucket. For a clock UI, this can create visible phase delay because the displayed second/progress is effectively centered in the bucket instead of aligned to the second boundary.

The browser also replaced its base clock estimate on every `/api/state` response. Small offset noise could therefore appear as visible phase jumps or phase drift.

## Files Changed

### `src/measurement.ps1`

- `Get-OffsetMs` now defaults to raw Cristian offset with no quantization correction.
- Added optional `QuantizationCorrectionMs` parameter for explicit correction when needed.
- `Invoke-HeadProbe` now returns:
  - `RawOffsetMs`
  - `OffsetMs` for compatibility, currently midpoint style with explicit `+500ms`
  - `ServerDateMs`
  - `PcAtT2Ms`
- Added `Select-EdgeOffsetCandidates`.
- `Reduce-Samples` now prefers true Date-header transition detection.
- It falls back to the upper envelope of raw offsets only if no Date transition is visible.

Current intent:

- HTTP `Date` is usually floored to whole seconds.
- The best phase estimate is from observed transitions where Date jumps `N -> N+1`.
- The server second boundary lies between the previous and current server-event estimates.

### `src/http-server.ps1`

- Page requests to `/` or `/index.html` start the one-shot measurement timer.
- This means F5 refresh triggers a background remeasurement.
- Duplicate measurement is guarded by:

```powershell
$state.Status -ne 'measuring' -and -not $state.MeasureTimer.Enabled
```

### `src/probe.ps1`

- `MeasureTimer` remains one-shot:

```powershell
$measureTimer.Interval = 100
$measureTimer.AutoReset = $false
```

- There is no 1-minute automatic measurement loop.
- NTP remains a display-only diagnostic timer and is not used for server offset correction.

### `src/web/clock.js`

- Added small slew correction for minor base-clock changes.
- If the new base estimate differs by more than `120ms`, the UI snaps to it.
- If the difference is `120ms` or less, the UI applies it gradually through `slewRemainingMs`.

This avoids visible jitter from small measurement noise while still correcting large errors quickly.

### `tests/Measurement.Tests.ps1`

- Updated tests for raw offset default behavior.
- Added explicit quantization correction test.
- Added regression test for upper-envelope second-boundary estimation.

### `tests/Ntp.Tests.ps1`

- Changed `0u` to `[uint32]0` for PowerShell 5.1 compatibility.

### `README.md`

- Updated algorithm wording to:

```text
Cristian + 50샘플 + RTT 필터 + Date 초 경계 상한값 추정
```

- Updated remeasurement policy to:

```text
F5 새로고침 시 백그라운드 재측정으로 오프셋 갱신
```

## Current Remeasurement Policy

Do not add a background 1-minute measurement loop unless the user asks for it again.

Current desired behavior:

1. App starts and performs initial measurement.
2. Browser shows clock using local `performance.now()` interpolation.
3. `/api/state` polling updates UI state and clock base.
4. The first page load after app start does not trigger another measurement.
5. F5 refresh or page re-entry after that triggers one background remeasurement.
6. No automatic 1-minute offset refresh.

Remeasurement sample policy added after the initial phase-delay fix:

- Initial measurement remains `50` samples.
- F5 remeasurement uses `50` samples.
- If the new offset differs from the previous offset by `100ms` or less, accept it.
- If the difference is greater than `100ms`, run one more `50` sample remeasurement.
- If the second attempt is also greater than `100ms`, reject the new value and keep the previous offset.
- Use the original `TargetUrl` for remeasurement. This matters for Naver comparison runs, which must keep using `https://naver.com/`.

## Verification

Run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Script tests\Measurement.Tests.ps1,tests\Anchor.Tests.ps1,tests\Ntp.Tests.ps1"
```

Last known result after this change:

```text
Passed: 13 Failed: 0
```

## Notes For Future Agents

- Be careful with the old design notes in `CLAUDE.md`; many sections describe a future Node/NAS service, not the current PowerShell implementation.
- For the current app, prefer editing the PowerShell and static web files under `src/`.
- The target host is currently hardcoded in `src/probe.ps1`.
- The logs may contain older experimental entries with different sample counts; do not infer current runtime behavior only from old logs.
- HTTP `Date` header precision is limited to seconds, so any millisecond estimate is inferred from sampling behavior.
