"""Thread-safe state store. Mirrors New-StateStore in src/http-server.ps1."""

from __future__ import annotations

import re
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
        self.ntp_info = None

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


_SCHEME_RE = re.compile(r"^[a-zA-Z][a-zA-Z0-9+.\-]*://")


def normalize_target_url(url: str) -> str:
    """Mirror Normalize-TargetUrl in src/http-server.ps1."""
    value = (url or "").strip()
    if not value:
        raise ValueError("URL을 입력하세요.")
    if not _SCHEME_RE.match(value):
        value = "https://" + value
    parsed = urlparse(value)
    if parsed.scheme not in ("http", "https"):
        raise ValueError("http 또는 https URL만 지원합니다.")
    if not parsed.hostname:
        raise ValueError("호스트가 없는 URL입니다.")
    return value
