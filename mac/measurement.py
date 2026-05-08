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
