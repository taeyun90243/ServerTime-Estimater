"""ThreadingHTTPServer wrapper. Port of src/http-server.ps1.

Routes:
  GET /, /index.html       -> serve web/index.html and trigger background remeasure
  GET /clock.js, /clock.css -> static
  GET /api/state           -> JSON snapshot
  POST /api/target         -> set target URL (body: {"url": "..."})
"""

from __future__ import annotations

import datetime as _dt
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from state import normalize_target_url


def make_handler(state, anchor, web_root, trigger_remeasure):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            return

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
                self._send_json(_to_camel(snap))
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
    """Convert snake_case keys to the camelCase JSON shape clock.js expects."""
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
    out = {mapping.get(k, k): v for k, v in snap.items()}
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
    raise RuntimeError(
        f"Failed to bind any port in {prefer_port}..{prefer_port+9}: {last_err}"
    )
