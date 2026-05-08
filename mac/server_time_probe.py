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
