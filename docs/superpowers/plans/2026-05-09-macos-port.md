# macOS Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Windows PowerShell server-time probe (`src/probe.ps1` + `src/web/`) to a self-contained macOS Python 3 implementation under `mac/`, preserving the Windows algorithm exactly while leaving the Windows tree untouched.

**Architecture:** A single Python 3 process exposes `http://127.0.0.1:8765/` via `ThreadingHTTPServer`. A worker thread runs adaptive multi-sampling (`IntervalMs=50`, `Count=ceil(6000/(R+50))` clamped `[10,60]`), Cristian offset, edge detection, and F5 re-measurement (100 ms acceptance threshold) — mirroring the Windows behavior. Static web assets live in `mac/web/` (a copy of `src/web/`).

**Tech Stack:** Python 3 stdlib only (`http.server`, `http.client`, `urllib.parse`, `time.monotonic_ns`, `statistics`, `threading`, `email.utils`, `unittest`).

---

## File Structure

```
mac/
├── run.command              # double-click launcher (chmod +x)
├── server_time_probe.py     # main entry: parse args, init, start server, run worker
├── measurement.py           # probe + reduce (Cristian, adaptive, edge detection)
├── state.py                 # thread-safe state store
├── server.py                # ThreadingHTTPServer + request handler
├── web/
│   ├── index.html           # copied from src/web/index.html
│   ├── clock.js             # copied from src/web/clock.js
│   └── clock.css            # copied from src/web/clock.css
├── tests/
│   ├── __init__.py
│   └── test_measurement.py
└── README_MAC.md
```

Windows files (`src/`, `addons/`, `run.bat`, `tests/*.Tests.ps1`, `ServerTimeProbe.exe`) are not modified.

---

## Task 1: Scaffold mac/ directory + copy web assets

**Files:**
- Create: `mac/web/index.html`, `mac/web/clock.js`, `mac/web/clock.css` (copies of `src/web/*`)
- Create: `mac/__init__-placeholder` (empty marker, deleted later — only used to make `git add` see the dir)

- [ ] **Step 1: Create directory and copy web assets**

```bash
mkdir -p mac/web mac/tests
cp src/web/index.html mac/web/index.html
cp src/web/clock.js mac/web/clock.js
cp src/web/clock.css mac/web/clock.css
```

- [ ] **Step 2: Verify file count and sizes match**

```bash
ls -la mac/web/
diff src/web/index.html mac/web/index.html
diff src/web/clock.js mac/web/clock.js
diff src/web/clock.css mac/web/clock.css
```

Expected: `diff` produces no output for any file.

- [ ] **Step 3: Commit**

```bash
git add mac/web/
git commit -m "feat(mac): scaffold mac/ and copy web assets from src/web/"
```

---

## Task 2: measurement.py — basic probe + offset (Cristian)

**Files:**
- Create: `mac/measurement.py`
- Test: `mac/tests/test_measurement.py`

- [ ] **Step 1: Write the failing test for `cristian_offset_ms`**

Create `mac/tests/__init__.py` (empty), then create `mac/tests/test_measurement.py`:

```python
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from measurement import cristian_offset_ms


class CristianOffsetTest(unittest.TestCase):
    def test_basic_formula(self):
        # offset = (Ts + RTT/2) - t2_pc
        self.assertAlmostEqual(
            cristian_offset_ms(server_date_ms=1_000_000, rtt_ms=100, pc_at_t2_ms=999_950),
            100.0,
            places=6,
        )

    def test_negative_offset_when_pc_ahead(self):
        self.assertAlmostEqual(
            cristian_offset_ms(server_date_ms=1_000_000, rtt_ms=50, pc_at_t2_ms=1_000_100),
            -75.0,
            places=6,
        )


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

```bash
python3 -m unittest mac.tests.test_measurement -v
```

Expected: FAIL with `ModuleNotFoundError: No module named 'measurement'`.

- [ ] **Step 3: Create minimal `mac/measurement.py`**

```python
"""Server-time probe and reduction (port of src/measurement.ps1).

All public functions return primitives or simple namedtuple-style dicts.
Algorithm parity with the PowerShell implementation is required; do not
redesign the math.
"""

from __future__ import annotations


def cristian_offset_ms(server_date_ms: float, rtt_ms: float, pc_at_t2_ms: float) -> float:
    """Cristian's algorithm: offset = (Ts + RTT/2) - t2_pc.

    Mirrors `Get-OffsetMs` in src/measurement.ps1.
    """
    return (server_date_ms + rtt_ms / 2.0) - pc_at_t2_ms
```

- [ ] **Step 4: Run test, expect pass**

```bash
python3 -m unittest mac.tests.test_measurement -v
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add mac/measurement.py mac/tests/__init__.py mac/tests/test_measurement.py
git commit -m "feat(mac): add cristian_offset_ms with tests"
```

---

## Task 3: measurement.py — median, stddev, ci95

**Files:**
- Modify: `mac/measurement.py`
- Test: `mac/tests/test_measurement.py`

- [ ] **Step 1: Append failing tests for stats helpers**

Append to `mac/tests/test_measurement.py`:

```python
from measurement import median, stddev_sample, ci95_ms


class StatsHelperTest(unittest.TestCase):
    def test_median_odd(self):
        self.assertEqual(median([3.0, 1.0, 2.0]), 2.0)

    def test_median_even(self):
        self.assertEqual(median([1.0, 2.0, 3.0, 4.0]), 2.5)

    def test_median_empty_raises(self):
        with self.assertRaises(ValueError):
            median([])

    def test_stddev_sample_two_values(self):
        # Bessel-corrected stddev of [1, 3] = sqrt(2)
        self.assertAlmostEqual(stddev_sample([1.0, 3.0]), 2.0 ** 0.5, places=6)

    def test_stddev_sample_single_value_returns_zero(self):
        self.assertEqual(stddev_sample([5.0]), 0.0)

    def test_ci95_ms_uses_t_table(self):
        # n=10 -> t=2.262
        vals = [1.0] * 10
        self.assertAlmostEqual(ci95_ms(vals), 0.0, places=6)
```

- [ ] **Step 2: Run, expect FAIL (ImportError)**

```bash
python3 -m unittest mac.tests.test_measurement -v
```

- [ ] **Step 3: Implement helpers in `mac/measurement.py`**

Append to `mac/measurement.py`:

```python
import math


def median(values):
    n = len(values)
    if n == 0:
        raise ValueError("median of empty sequence")
    s = sorted(values)
    if n % 2 == 1:
        return float(s[n // 2])
    return (float(s[n // 2 - 1]) + float(s[n // 2])) / 2.0


def stddev_sample(values):
    n = len(values)
    if n < 2:
        return 0.0
    mean = sum(values) / n
    sq = sum((v - mean) ** 2 for v in values)
    return math.sqrt(sq / (n - 1))


def _t_value(n: int) -> float:
    if n >= 30:
        return 1.96
    if n >= 10:
        return 2.262
    if n >= 5:
        return 2.776
    return 4.303


def ci95_ms(values):
    n = len(values)
    if n < 2:
        return 0.0
    sigma = stddev_sample(values)
    return _t_value(n) * sigma / math.sqrt(n)
```

- [ ] **Step 4: Run, expect PASS**

```bash
python3 -m unittest mac.tests.test_measurement -v
```

- [ ] **Step 5: Commit**

```bash
git add mac/measurement.py mac/tests/test_measurement.py
git commit -m "feat(mac): add median/stddev/ci95 helpers with tests"
```

---

## Task 4: measurement.py — edge detection from samples

**Files:**
- Modify: `mac/measurement.py`
- Test: `mac/tests/test_measurement.py`

- [ ] **Step 1: Append failing tests**

Append to `mac/tests/test_measurement.py`:

```python
from measurement import select_edge_offsets, reduce_samples


def _sample(rtt_ms, server_date_ms, pc_at_t2_ms):
    raw_offset = (server_date_ms + rtt_ms / 2.0) - pc_at_t2_ms
    return {
        "rtt_ms": rtt_ms,
        "server_date_ms": server_date_ms,
        "pc_at_t2_ms": pc_at_t2_ms,
        "raw_offset_ms": raw_offset,
    }


class EdgeDetectionTest(unittest.TestCase):
    def test_edge_detected_when_date_increments(self):
        samples = [
            _sample(rtt_ms=50, server_date_ms=1_000_000_000, pc_at_t2_ms=999_999_980),
            _sample(rtt_ms=50, server_date_ms=1_000_001_000, pc_at_t2_ms=1_000_000_500),
        ]
        edges = select_edge_offsets(samples)
        self.assertEqual(len(edges), 1)

    def test_no_edge_when_date_repeats(self):
        samples = [
            _sample(rtt_ms=50, server_date_ms=1_000_000_000, pc_at_t2_ms=999_999_980),
            _sample(rtt_ms=50, server_date_ms=1_000_000_000, pc_at_t2_ms=999_999_990),
        ]
        self.assertEqual(select_edge_offsets(samples), [])

    def test_reduce_uses_edge_method_when_edges_present(self):
        samples = [
            _sample(rtt_ms=50, server_date_ms=1_000_000_000, pc_at_t2_ms=999_999_980),
            _sample(rtt_ms=50, server_date_ms=1_000_001_000, pc_at_t2_ms=1_000_000_500),
            _sample(rtt_ms=50, server_date_ms=1_000_002_000, pc_at_t2_ms=1_000_001_500),
        ]
        result = reduce_samples(samples)
        self.assertEqual(result["method"], "edge")
        self.assertGreaterEqual(result["accepted_count"], 1)

    def test_reduce_falls_back_when_no_edges(self):
        # All samples share the same Date second -> no transitions detectable.
        samples = [
            _sample(rtt_ms=50 + i, server_date_ms=1_000_000_000, pc_at_t2_ms=999_999_980 + i)
            for i in range(10)
        ]
        result = reduce_samples(samples)
        self.assertEqual(result["method"], "upper-envelope")
```

- [ ] **Step 2: Run, expect FAIL**

```bash
python3 -m unittest mac.tests.test_measurement -v
```

- [ ] **Step 3: Implement edge detection + reduce_samples**

Append to `mac/measurement.py`:

```python
def select_low_jitter(samples, min_count=3):
    rtts = [s["rtt_ms"] for s in samples]
    rtt_med = median(rtts)
    threshold = rtt_med * 1.5 + 2
    low = [s for s in samples if s["rtt_ms"] <= threshold]
    if len(low) < min_count:
        low = list(samples)
    return low, rtt_med


def select_quantized_offsets(samples):
    low, _ = select_low_jitter(samples, min_count=5)
    raws = sorted((s["raw_offset_ms"] for s in low), reverse=True)
    candidate_count = max(3, int(len(raws) * 0.08))
    return raws[:candidate_count]


def select_edge_offsets(samples):
    edges = []
    for prev, curr in zip(samples, samples[1:]):
        if prev.get("server_date_ms") is None or curr.get("server_date_ms") is None:
            continue
        step = curr["server_date_ms"] - prev["server_date_ms"]
        if step < 900 or step > 1100:
            continue
        prev_event_pc = prev["pc_at_t2_ms"] - prev["rtt_ms"] / 2.0
        curr_event_pc = curr["pc_at_t2_ms"] - curr["rtt_ms"] / 2.0
        if curr_event_pc <= prev_event_pc:
            continue
        edge_pc = (prev_event_pc + curr_event_pc) / 2.0
        edges.append(curr["server_date_ms"] - edge_pc)
    return edges


def reduce_samples(samples):
    candidates = select_edge_offsets(samples)
    method = "edge"
    if not candidates:
        candidates = select_quantized_offsets(samples)
        method = "upper-envelope"
    rtts = [s["rtt_ms"] for s in samples]
    return {
        "offset_ms": median(candidates),
        "sigma_ms": stddev_sample(candidates),
        "ci95_ms": ci95_ms(candidates),
        "rtt_median_ms": median(rtts),
        "sample_count": len(samples),
        "accepted_count": len(candidates),
        "method": method,
    }
```

- [ ] **Step 4: Run, expect PASS**

```bash
python3 -m unittest mac.tests.test_measurement -v
```

- [ ] **Step 5: Commit**

```bash
git add mac/measurement.py mac/tests/test_measurement.py
git commit -m "feat(mac): add edge detection and reduce_samples"
```

---

## Task 5: measurement.py — adaptive count calculation

**Files:**
- Modify: `mac/measurement.py`
- Test: `mac/tests/test_measurement.py`

- [ ] **Step 1: Append failing test**

Append to `mac/tests/test_measurement.py`:

```python
from measurement import adaptive_count


class AdaptiveCountTest(unittest.TestCase):
    def test_low_rtt_clamps_to_max(self):
        # Window 6000 / (50 + 50) = 60 -> clamp at 60
        self.assertEqual(adaptive_count(rtt_median_ms=50, interval_ms=50), 60)

    def test_mid_rtt(self):
        # ceil(6000 / (150 + 50)) = 30
        self.assertEqual(adaptive_count(rtt_median_ms=150, interval_ms=50), 30)

    def test_high_rtt_uses_estimated(self):
        # ceil(6000 / (300 + 50)) = 18
        self.assertEqual(adaptive_count(rtt_median_ms=300, interval_ms=50), 18)

    def test_huge_rtt_clamps_to_min(self):
        self.assertEqual(adaptive_count(rtt_median_ms=10_000, interval_ms=50), 10)
```

- [ ] **Step 2: Run, expect FAIL**

```bash
python3 -m unittest mac.tests.test_measurement -v
```

- [ ] **Step 3: Implement**

Append to `mac/measurement.py`:

```python
def adaptive_count(rtt_median_ms, interval_ms=50, target_window_ms=6000,
                   min_count=10, max_count=60):
    estimated = math.ceil(target_window_ms / (rtt_median_ms + interval_ms))
    return max(min_count, min(max_count, estimated))
```

- [ ] **Step 4: Run, expect PASS**

```bash
python3 -m unittest mac.tests.test_measurement -v
```

- [ ] **Step 5: Commit**

```bash
git add mac/measurement.py mac/tests/test_measurement.py
git commit -m "feat(mac): add adaptive_count with tests"
```

---

## Task 6: measurement.py — head_probe + naver_probe (real network)

**Files:**
- Modify: `mac/measurement.py`

No unit test (network-dependent). Manual verification only.

- [ ] **Step 1: Add module-level imports + constants**

Insert near the top of `mac/measurement.py` after the docstring:

```python
import http.client
import re
import time
from email.utils import parsedate_to_datetime
from urllib.parse import urlparse

PROBE_USER_AGENT = "ServerTimeProbe/1.0 (personal-use)"
HTTP_TIMEOUT_SEC = 5
NAVER_API_URL = (
    "https://ts-proxy.naver.com/dcontent/util/time.naver"
    "?passportKey=9964bf6d4645e3a94ca5e72c231b50a3c18fb688"
    "&_format=yyyy/MM/dd/HH/mm/ss/SSS&site=naver"
)
NAVER_TIME_RE = re.compile(r'"(\d{4}/\d{2}/\d{2}/\d{2}/\d{2}/\d{2}/\d{3})"')
```

- [ ] **Step 2: Add monotonic clock anchor + helpers**

Append to `mac/measurement.py`:

```python
class MonotonicAnchor:
    """Mirrors src/anchor.ps1: monotonic-anchored UTC ms.

    pc_utc_now_ms() returns wall-clock UTC ms but stays smooth across
    NTP adjustments because it advances via time.monotonic_ns().
    """

    def __init__(self):
        self._wall_ms_at_start = time.time() * 1000.0
        self._mono_ns_at_start = time.monotonic_ns()

    def pc_utc_now_ms(self) -> float:
        elapsed_ms = (time.monotonic_ns() - self._mono_ns_at_start) / 1_000_000.0
        return self._wall_ms_at_start + elapsed_ms


def _parse_http_date_ms(date_hdr: str) -> float:
    dt = parsedate_to_datetime(date_hdr)
    return dt.timestamp() * 1000.0


def _parse_naver_time_ms(naver_time: str) -> float:
    # Format: yyyy/MM/dd/HH/mm/ss/SSS in KST
    parts = naver_time.split("/")
    if len(parts) != 7:
        raise ValueError(f"Invalid Naver time: {naver_time}")
    import datetime as _dt
    kst_tz = _dt.timezone(_dt.timedelta(hours=9))
    dt = _dt.datetime(
        int(parts[0]), int(parts[1]), int(parts[2]),
        int(parts[3]), int(parts[4]), int(parts[5]),
        int(parts[6]) * 1000,
        tzinfo=kst_tz,
    )
    return dt.timestamp() * 1000.0
```

- [ ] **Step 3: Add `head_probe`**

Append to `mac/measurement.py`:

```python
def is_naver_clock_url(url: str) -> bool:
    try:
        return urlparse(url).hostname == "naver.com"
    except Exception:
        return False


def head_probe(url: str, anchor: MonotonicAnchor):
    """One HTTP HEAD probe, falls back to GET Range: bytes=0-0 on 405.

    Returns dict with rtt_ms, server_date_ms, pc_at_t2_ms, raw_offset_ms,
    date_hdr.
    """
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        raise ValueError(f"Unsupported scheme: {parsed.scheme}")
    host = parsed.hostname
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    path = parsed.path or "/"
    if parsed.query:
        path = f"{path}?{parsed.query}"

    if parsed.scheme == "https":
        conn = http.client.HTTPSConnection(host, port, timeout=HTTP_TIMEOUT_SEC)
    else:
        conn = http.client.HTTPConnection(host, port, timeout=HTTP_TIMEOUT_SEC)

    headers = {"User-Agent": PROBE_USER_AGENT, "Connection": "keep-alive"}
    try:
        t1 = time.monotonic_ns()
        try:
            conn.request("HEAD", path, headers=headers)
            resp = conn.getresponse()
            resp.read()  # drain
            if resp.status == 405:
                raise RuntimeError("HEAD not allowed")
        except Exception:
            t1 = time.monotonic_ns()
            conn.request("GET", path, headers={**headers, "Range": "bytes=0-0"})
            resp = conn.getresponse()
            resp.read()
        t2 = time.monotonic_ns()
        pc_at_t2_ms = anchor.pc_utc_now_ms()
        date_hdr = resp.getheader("Date")
        if not date_hdr:
            raise RuntimeError("Date header missing")
        rtt_ms = (t2 - t1) / 1_000_000.0
        server_date_ms = _parse_http_date_ms(date_hdr)
        raw = (server_date_ms + rtt_ms / 2.0) - pc_at_t2_ms
        return {
            "rtt_ms": rtt_ms,
            "server_date_ms": server_date_ms,
            "pc_at_t2_ms": pc_at_t2_ms,
            "raw_offset_ms": raw,
            "date_hdr": date_hdr,
        }
    finally:
        try:
            conn.close()
        except Exception:
            pass
```

- [ ] **Step 4: Add `naver_probe`**

Append to `mac/measurement.py`:

```python
def naver_probe(anchor: MonotonicAnchor):
    parsed = urlparse(NAVER_API_URL)
    conn = http.client.HTTPSConnection(parsed.hostname, 443, timeout=HTTP_TIMEOUT_SEC)
    path = parsed.path + "?" + parsed.query
    try:
        t1 = time.monotonic_ns()
        conn.request("GET", path, headers={"User-Agent": PROBE_USER_AGENT})
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", errors="replace")
        t2 = time.monotonic_ns()
        pc_at_t2_ms = anchor.pc_utc_now_ms()
        m = NAVER_TIME_RE.search(body)
        if not m:
            raise RuntimeError(f"Naver API unexpected response: {body[:200]}")
        rtt_ms = (t2 - t1) / 1_000_000.0
        server_date_ms = _parse_naver_time_ms(m.group(1))
        raw = (server_date_ms + rtt_ms / 2.0) - pc_at_t2_ms
        return {
            "rtt_ms": rtt_ms,
            "server_date_ms": server_date_ms,
            "pc_at_t2_ms": pc_at_t2_ms,
            "raw_offset_ms": raw,
            "date_hdr": m.group(1),
        }
    finally:
        try:
            conn.close()
        except Exception:
            pass
```

- [ ] **Step 5: Manual smoke test**

```bash
python3 -c "
import sys; sys.path.insert(0,'mac')
from measurement import MonotonicAnchor, head_probe
a = MonotonicAnchor()
print(head_probe('https://www.google.com/', a))
"
```

Expected: dict with non-zero `rtt_ms` and a recent `server_date_ms`. If it fails, fix before proceeding.

- [ ] **Step 6: Commit**

```bash
git add mac/measurement.py
git commit -m "feat(mac): add head_probe and naver_probe with monotonic anchor"
```

---

## Task 7: measurement.py — adaptive_multi_sample orchestration

**Files:**
- Modify: `mac/measurement.py`

- [ ] **Step 1: Implement orchestrator**

Append to `mac/measurement.py`:

```python
def adaptive_multi_sample(url: str, anchor: MonotonicAnchor,
                          interval_ms=50, target_window_ms=6000,
                          min_count=10, max_count=60, rtt_probe_count=3):
    """Mirror Invoke-AdaptiveMultiSample. Returns dict from reduce_samples()."""
    use_naver = is_naver_clock_url(url)
    samples = []
    for _ in range(rtt_probe_count):
        try:
            s = naver_probe(anchor) if use_naver else head_probe(url, anchor)
            samples.append(s)
        except Exception:
            pass
        time.sleep(interval_ms / 1000.0)

    if not samples:
        raise RuntimeError("All initial RTT probes failed")

    rtt_med = median([s["rtt_ms"] for s in samples])
    count = adaptive_count(rtt_med, interval_ms=interval_ms,
                           target_window_ms=target_window_ms,
                           min_count=min_count, max_count=max_count)

    while len(samples) < count:
        try:
            s = naver_probe(anchor) if use_naver else head_probe(url, anchor)
            samples.append(s)
        except Exception:
            pass
        if len(samples) < count:
            time.sleep(interval_ms / 1000.0)

    if len(samples) < int(count * 0.5):
        raise RuntimeError(f"Too many failed samples: {len(samples)}/{count}")

    if use_naver:
        # Naver API gives ms-precision -> use precise reducer
        return _reduce_precise(samples)
    return reduce_samples(samples)


def _reduce_precise(samples):
    low, rtt_med = select_low_jitter(samples, min_count=3)
    offsets = [(s["server_date_ms"] + s["rtt_ms"] / 2.0) - s["pc_at_t2_ms"] for s in low]
    return {
        "offset_ms": median(offsets),
        "sigma_ms": stddev_sample(offsets),
        "ci95_ms": ci95_ms(offsets),
        "rtt_median_ms": rtt_med,
        "sample_count": len(samples),
        "accepted_count": len(offsets),
        "method": "naver-time-api",
    }
```

- [ ] **Step 2: Manual smoke test**

```bash
python3 -c "
import sys; sys.path.insert(0,'mac')
from measurement import MonotonicAnchor, adaptive_multi_sample
a = MonotonicAnchor()
print(adaptive_multi_sample('https://www.google.com/', a))
"
```

Expected: dict with `offset_ms`, `accepted_count >= 1`, `method` either `edge` or `upper-envelope`. Should take ~6 seconds.

- [ ] **Step 3: Run unit tests, expect all pass**

```bash
python3 -m unittest mac.tests.test_measurement -v
```

- [ ] **Step 4: Commit**

```bash
git add mac/measurement.py
git commit -m "feat(mac): add adaptive_multi_sample orchestration"
```

---

## Task 8: state.py — thread-safe state store

**Files:**
- Create: `mac/state.py`

- [ ] **Step 1: Create state.py**

```python
"""Thread-safe state store. Mirrors New-StateStore in src/http-server.ps1."""

from __future__ import annotations

import threading
from urllib.parse import urlparse


class StateStore:
    def __init__(self):
        self._lock = threading.RLock()
        self.host = ""
        self.target_url = ""
        self.pending_target_change = False
        self.offset_ms = 0.0
        self.last_measure_at_ms = None
        self.last_measure_requested_at_ms = None
        self.last_remeasure_finished_at_ms = None
        self.last_remeasure_result = ""
        self.last_remeasure_delta_ms = None
        self.last_remeasure_attempts = 0
        self.measure_in_progress = False
        self.page_served = False
        self.rtt_median_ms = 0.0
        self.sigma_ms = 0.0
        self.ci95_ms = 0.0
        self.status = "idle"
        self.ntp_info = None  # always None on macOS port

    def lock(self):
        return self._lock

    def set_target(self, url: str, now_ms: float):
        with self._lock:
            same = (self.target_url == url and self.last_measure_at_ms is not None)
            self.host = urlparse(url).hostname or ""
            self.target_url = url
            self.pending_target_change = not same
            self.last_measure_requested_at_ms = now_ms
            self.last_remeasure_finished_at_ms = None
            self.last_remeasure_result = ""
            self.last_remeasure_delta_ms = None
            self.last_remeasure_attempts = 0
            if not same:
                self.last_measure_at_ms = None
                self.rtt_median_ms = 0.0
                self.sigma_ms = 0.0
                self.ci95_ms = 0.0
            self.measure_in_progress = False
            self.status = "queued"

    def snapshot(self):
        with self._lock:
            return {
                "host": self.host,
                "target_url": self.target_url,
                "offset_ms": self.offset_ms,
                "last_measure_at_ms": self.last_measure_at_ms,
                "last_measure_requested_at_ms": self.last_measure_requested_at_ms,
                "last_remeasure_finished_at_ms": self.last_remeasure_finished_at_ms,
                "last_remeasure_result": self.last_remeasure_result,
                "last_remeasure_delta_ms": self.last_remeasure_delta_ms,
                "last_remeasure_attempts": self.last_remeasure_attempts,
                "rtt_median_ms": self.rtt_median_ms,
                "sigma_ms": self.sigma_ms,
                "ci95_ms": self.ci95_ms,
                "status": self.status,
                "ntp_info": self.ntp_info,
            }


def normalize_target_url(url: str) -> str:
    """Mirror Normalize-TargetUrl in src/http-server.ps1."""
    value = (url or "").strip()
    if not value:
        raise ValueError("URL을 입력하세요.")
    if not _has_scheme(value):
        value = "https://" + value
    parsed = urlparse(value)
    if parsed.scheme not in ("http", "https"):
        raise ValueError("http 또는 https URL만 지원합니다.")
    if not parsed.hostname:
        raise ValueError("호스트가 없는 URL입니다.")
    return value


def _has_scheme(value: str) -> bool:
    import re
    return bool(re.match(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://", value))
```

- [ ] **Step 2: Smoke test**

```bash
python3 -c "
import sys; sys.path.insert(0,'mac')
from state import StateStore, normalize_target_url
s = StateStore()
s.set_target(normalize_target_url('google.com'), 1.0)
print(s.snapshot())
"
```

Expected: dict with `target_url='https://google.com'`, `host='google.com'`, `status='queued'`.

- [ ] **Step 3: Commit**

```bash
git add mac/state.py
git commit -m "feat(mac): add StateStore and normalize_target_url"
```

---

## Task 9: server.py — HTTP server + handler

**Files:**
- Create: `mac/server.py`

- [ ] **Step 1: Create server.py**

```python
"""ThreadingHTTPServer wrapper. Port of src/http-server.ps1.

Routes:
  GET /, /index.html   -> serve web/index.html and trigger background remeasure
  GET /clock.js, /clock.css -> static
  GET /api/state       -> JSON snapshot
  POST /api/target     -> set target URL (body: {"url": "..."})
"""

from __future__ import annotations

import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from state import normalize_target_url


def make_handler(state, anchor, web_root, trigger_remeasure):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return  # silence default access log

        def _send_static(self, path, content_type):
            try:
                with open(path, "rb") as f:
                    body = f.read()
            except FileNotFoundError:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _send_json(self, payload, status=200):
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            path = self.path.split("?", 1)[0]
            if path in ("/", "/index.html"):
                with state.lock():
                    if not state.page_served:
                        state.page_served = True
                    elif (state.target_url and not state.measure_in_progress
                          and state.status != "measuring"):
                        state.last_measure_requested_at_ms = anchor.pc_utc_now_ms()
                        state.last_remeasure_result = ""
                        state.last_remeasure_delta_ms = None
                        state.last_remeasure_attempts = 0
                        state.measure_in_progress = True
                        state.status = "measuring"
                        trigger_remeasure()
                self._send_static(os.path.join(web_root, "index.html"),
                                  "text/html; charset=utf-8")
            elif path == "/clock.css":
                self._send_static(os.path.join(web_root, "clock.css"),
                                  "text/css; charset=utf-8")
            elif path == "/clock.js":
                self._send_static(os.path.join(web_root, "clock.js"),
                                  "application/javascript; charset=utf-8")
            elif path == "/api/state":
                snap = state.snapshot()
                snap["pcSendTimeAtMs"] = anchor.pc_utc_now_ms()
                snap = _to_camel(snap)
                self._send_json(snap)
            else:
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b"Not Found")

        def do_POST(self):
            path = self.path.split("?", 1)[0]
            if path == "/api/target":
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length) if length else b""
                try:
                    payload = json.loads(raw.decode("utf-8")) if raw else {}
                    url = normalize_target_url(payload.get("url", ""))
                    state.set_target(url, anchor.pc_utc_now_ms())
                    trigger_remeasure()
                    self._send_json({"ok": True, "host": state.host,
                                     "targetUrl": state.target_url})
                except Exception as e:
                    self._send_json({"ok": False, "error": str(e)}, status=400)
            else:
                self.send_response(404)
                self.end_headers()

    return Handler


def _to_camel(snap):
    """Convert snake_case keys to camelCase to match the existing front-end."""
    mapping = {
        "host": "host",
        "target_url": "targetUrl",
        "offset_ms": "offsetMs",
        "last_measure_at_ms": "lastMeasureAtMs",
        "last_measure_requested_at_ms": "lastMeasureRequestedAtMs",
        "last_remeasure_finished_at_ms": "lastRemeasureFinishedAtMs",
        "last_remeasure_result": "lastRemeasureResult",
        "last_remeasure_delta_ms": "lastRemeasureDeltaMs",
        "last_remeasure_attempts": "lastRemeasureAttempts",
        "rtt_median_ms": "rttMedianMs",
        "sigma_ms": "sigmaMs",
        "ci95_ms": "ci95Ms",
        "status": "status",
        "ntp_info": "ntpInfo",
        "pcSendTimeAtMs": "pcSendTimeAtMs",
    }
    out = {}
    for k, v in snap.items():
        out[mapping.get(k, k)] = v
    # Match windows JSON shape: lastMeasureAt as ISO string (front-end parses it).
    # Convert ms timestamps to ISO so existing clock.js continues to work.
    import datetime as _dt
    for ms_key, iso_key in (
        ("lastMeasureAtMs", "lastMeasureAt"),
        ("lastMeasureRequestedAtMs", "lastMeasureRequestedAt"),
        ("lastRemeasureFinishedAtMs", "lastRemeasureFinishedAt"),
    ):
        ms = out.pop(ms_key, None)
        out[iso_key] = (
            _dt.datetime.fromtimestamp(ms / 1000.0, tz=_dt.timezone.utc).isoformat()
            if ms is not None else None
        )
    return out


def start_server(state, anchor, web_root, trigger_remeasure, prefer_port=8765):
    port = prefer_port
    last_err = None
    for _ in range(10):
        try:
            handler_cls = make_handler(state, anchor, web_root, trigger_remeasure)
            httpd = ThreadingHTTPServer(("127.0.0.1", port), handler_cls)
            return httpd, port
        except OSError as e:
            last_err = e
            port += 1
    raise RuntimeError(f"Failed to bind any port in {prefer_port}..{prefer_port+9}: {last_err}")
```

- [ ] **Step 2: Smoke test (start, hit /api/state, stop)**

```bash
python3 -c "
import sys, threading, urllib.request, time
sys.path.insert(0,'mac')
from state import StateStore
from measurement import MonotonicAnchor
from server import start_server
s = StateStore(); a = MonotonicAnchor()
httpd, port = start_server(s, a, 'mac/web', lambda: None, prefer_port=8765)
t = threading.Thread(target=httpd.serve_forever, daemon=True); t.start()
time.sleep(0.3)
print('port', port)
print(urllib.request.urlopen(f'http://127.0.0.1:{port}/api/state').read()[:200])
httpd.shutdown()
"
```

Expected: prints port and a JSON snapshot containing `\"status\": \"idle\"`.

- [ ] **Step 3: Commit**

```bash
git add mac/server.py
git commit -m "feat(mac): add ThreadingHTTPServer with /api/state and /api/target"
```

---

## Task 10: server_time_probe.py — main entry + measurement worker

**Files:**
- Create: `mac/server_time_probe.py`

- [ ] **Step 1: Create main**

```python
#!/usr/bin/env python3
"""Main entry. Mirror src/probe.ps1 control flow on macOS."""

from __future__ import annotations

import argparse
import os
import sys
import threading
import time
import webbrowser

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from measurement import MonotonicAnchor, adaptive_multi_sample
from server import start_server
from state import StateStore, normalize_target_url


REMEASURE_THRESHOLD_MS = 100


def run_measurement(state: StateStore, anchor: MonotonicAnchor):
    if not state.target_url:
        with state.lock():
            state.status = "idle"
            state.measure_in_progress = False
        return
    with state.lock():
        previous_offset_ms = state.offset_ms
        is_target_change = state.pending_target_change or state.last_measure_at_ms is None
        target_url = state.target_url
        state.measure_in_progress = True
        state.status = "measuring"

    accepted = False
    last_result = None
    last_delta = None
    for attempt in (1, 2):
        try:
            r = adaptive_multi_sample(target_url, anchor)
        except Exception as e:
            with state.lock():
                state.status = "failed"
                state.measure_in_progress = False
            print(f"측정 실패: {e}", file=sys.stderr)
            return
        last_result = r
        last_delta = abs(r["offset_ms"] - previous_offset_ms)
        with state.lock():
            state.last_remeasure_attempts = attempt
            state.last_remeasure_delta_ms = last_delta
        if is_target_change or last_delta <= REMEASURE_THRESHOLD_MS:
            accepted = True
            break

    with state.lock():
        if accepted and last_result is not None:
            state.offset_ms = last_result["offset_ms"]
            state.rtt_median_ms = last_result["rtt_median_ms"]
            state.sigma_ms = last_result["sigma_ms"]
            state.ci95_ms = last_result["ci95_ms"]
            state.last_measure_at_ms = anchor.pc_utc_now_ms()
            state.last_remeasure_result = "accepted"
            state.pending_target_change = False
            state.status = "ok"
        else:
            state.last_remeasure_result = "rejected"
            state.status = "ok"
        state.last_remeasure_finished_at_ms = anchor.pc_utc_now_ms()
        state.measure_in_progress = False


class Worker:
    """Single-flight measurement worker. trigger() coalesces concurrent requests."""

    def __init__(self, state, anchor):
        self.state = state
        self.anchor = anchor
        self._cv = threading.Condition()
        self._pending = False
        self._stop = False
        self._thread = threading.Thread(target=self._loop, daemon=True)

    def start(self):
        self._thread.start()

    def trigger(self):
        with self._cv:
            self._pending = True
            self._cv.notify()

    def stop(self):
        with self._cv:
            self._stop = True
            self._cv.notify()

    def _loop(self):
        while True:
            with self._cv:
                while not self._pending and not self._stop:
                    self._cv.wait()
                if self._stop:
                    return
                self._pending = False
            try:
                run_measurement(self.state, self.anchor)
            except Exception as e:
                print(f"worker error: {e}", file=sys.stderr)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--target-url", default="")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()

    web_root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "web")
    anchor = MonotonicAnchor()
    state = StateStore()
    worker = Worker(state, anchor)
    worker.start()

    if args.target_url:
        try:
            url = normalize_target_url(args.target_url)
            state.set_target(url, anchor.pc_utc_now_ms())
            worker.trigger()
        except Exception as e:
            print(f"잘못된 URL: {e}", file=sys.stderr)

    httpd, port = start_server(state, anchor, web_root, worker.trigger,
                               prefer_port=args.port)
    print(f"HTTP 서버: http://127.0.0.1:{port}/")

    if not args.no_browser:
        try:
            webbrowser.open(f"http://127.0.0.1:{port}/")
        except Exception:
            pass

    print("Ctrl+C로 종료")
    server_thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    server_thread.start()
    try:
        while True:
            time.sleep(1)
    except KeyboardInterrupt:
        print("\n종료 중...")
    finally:
        httpd.shutdown()
        worker.stop()


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Smoke test — boot, open browser-less, hit /api/state**

```bash
python3 mac/server_time_probe.py --no-browser --port 8765 &
SERVER_PID=$!
sleep 1
curl -s http://127.0.0.1:8765/api/state
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null
```

Expected: a JSON response with `"status":"idle"`. Process exits cleanly.

- [ ] **Step 3: Commit**

```bash
git add mac/server_time_probe.py
git commit -m "feat(mac): add server_time_probe.py main entry with worker"
```

---

## Task 11: run.command launcher

**Files:**
- Create: `mac/run.command`

- [ ] **Step 1: Create launcher**

```bash
#!/bin/bash
# Double-click launcher for the macOS server-time probe.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3가 설치되어 있지 않습니다."
  echo "다음 명령으로 Xcode Command Line Tools를 설치하세요:"
  echo "  xcode-select --install"
  read -n 1 -s -r -p "아무 키나 누르면 종료합니다..."
  exit 1
fi

exec python3 server_time_probe.py "$@"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x mac/run.command
```

- [ ] **Step 3: Verify shebang and permission**

```bash
ls -l mac/run.command
head -1 mac/run.command
```

Expected: `-rwxr-xr-x` and `#!/bin/bash`.

- [ ] **Step 4: Commit**

```bash
git add mac/run.command
git commit -m "feat(mac): add run.command launcher with python3 check"
```

---

## Task 12: README_MAC.md

**Files:**
- Create: `mac/README_MAC.md`

- [ ] **Step 1: Write README**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add mac/README_MAC.md
git commit -m "docs(mac): add README_MAC.md"
```

---

## Task 13: End-to-end verification

**Files:** none

- [ ] **Step 1: Run all unit tests**

```bash
python3 -m unittest discover mac/tests -v
```

Expected: all tests pass (≈12 tests across cristian/stats/edge/adaptive).

- [ ] **Step 2: Boot and exercise full flow**

```bash
python3 mac/server_time_probe.py --no-browser --port 8765 &
SERVER_PID=$!
sleep 1
echo "--- initial state ---"
curl -s http://127.0.0.1:8765/api/state
echo
echo "--- set target ---"
curl -s -X POST http://127.0.0.1:8765/api/target \
  -H "Content-Type: application/json" \
  -d '{"url":"https://www.google.com/"}'
echo
sleep 8
echo "--- state after measurement ---"
curl -s http://127.0.0.1:8765/api/state
echo
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true
```

Expected:
- initial state: `status=idle`
- after POST: `ok=true`
- after 8s: `status=ok`, non-zero `offsetMs`, `rttMedianMs > 0`

- [ ] **Step 3: Verify static assets serve**

```bash
python3 mac/server_time_probe.py --no-browser --port 8765 &
SERVER_PID=$!
sleep 1
curl -sI http://127.0.0.1:8765/ | head -1
curl -sI http://127.0.0.1:8765/clock.js | head -1
curl -sI http://127.0.0.1:8765/clock.css | head -1
kill $SERVER_PID
wait $SERVER_PID 2>/dev/null || true
```

Expected: three `HTTP/1.0 200 OK` lines.

- [ ] **Step 4: Final commit (if any fixups were needed)**

If steps above required code changes, commit them:

```bash
git status
git add -A
git commit -m "fix(mac): resolve issues found during e2e verification"
```

If no changes were needed, skip this step.
