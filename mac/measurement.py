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
