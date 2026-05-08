"""Server-time probe and reduction (port of src/measurement.ps1).

All public functions return primitives or simple namedtuple-style dicts.
Algorithm parity with the PowerShell implementation is required; do not
redesign the math.
"""

from __future__ import annotations

import http.client
import math
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


def cristian_offset_ms(server_date_ms: float, rtt_ms: float, pc_at_t2_ms: float) -> float:
    """Cristian's algorithm: offset = (Ts + RTT/2) - t2_pc.

    Mirrors `Get-OffsetMs` in src/measurement.ps1.
    """
    return (server_date_ms + rtt_ms / 2.0) - pc_at_t2_ms


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


def adaptive_count(rtt_median_ms, interval_ms=50, target_window_ms=6000,
                   min_count=10, max_count=60):
    estimated = math.ceil(target_window_ms / (rtt_median_ms + interval_ms))
    return max(min_count, min(max_count, estimated))


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


def is_naver_clock_url(url: str) -> bool:
    try:
        return urlparse(url).hostname == "naver.com"
    except Exception:
        return False


def head_probe(url: str, anchor: MonotonicAnchor):
    """One HTTP HEAD probe, falls back to GET Range: bytes=0-0 on failure."""
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
            resp.read()
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
