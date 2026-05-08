"""Server-time probe and reduction (port of src/measurement.ps1).

All public functions return primitives or simple namedtuple-style dicts.
Algorithm parity with the PowerShell implementation is required; do not
redesign the math.
"""

from __future__ import annotations

import math


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
