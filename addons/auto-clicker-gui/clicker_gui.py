import ctypes
import datetime as dt
import json
import queue
import re
import threading
import time
import tkinter as tk
from tkinter import messagebox, ttk
from urllib.error import URLError
from urllib.request import Request, urlopen


KST = dt.timezone(dt.timedelta(hours=9))
DEFAULT_API_BASE = "http://127.0.0.1:8765"


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [
        ("dx", ctypes.c_long),
        ("dy", ctypes.c_long),
        ("mouseData", ctypes.c_ulong),
        ("dwFlags", ctypes.c_ulong),
        ("time", ctypes.c_ulong),
        ("dwExtraInfo", ctypes.POINTER(ctypes.c_ulong)),
    ]


class INPUT(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_ulong),
        ("mi", MOUSEINPUT),
    ]


INPUT_MOUSE = 0
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
USER32 = ctypes.WinDLL("user32", use_last_error=True)
USER32.SendInput.argtypes = (ctypes.c_uint, ctypes.POINTER(INPUT), ctypes.c_int)
USER32.SendInput.restype = ctypes.c_uint


def left_click_once():
    inputs = (INPUT * 2)()
    inputs[0].type = INPUT_MOUSE
    inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN
    inputs[1].type = INPUT_MOUSE
    inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTUP
    sent = USER32.SendInput(2, inputs, ctypes.sizeof(INPUT))
    if sent != 2:
        raise ctypes.WinError(ctypes.get_last_error())


def unix_ms_from_utc(value):
    return value.timestamp() * 1000.0


def dt_from_unix_ms_kst(value_ms):
    return dt.datetime.fromtimestamp(value_ms / 1000.0, tz=dt.timezone.utc).astimezone(KST)


def parse_target_time(value):
    value = value.strip()
    formats = [
        "%Y-%m-%d %H:%M:%S.%f",
        "%Y-%m-%d %H:%M:%S",
        "%Y/%m/%d %H:%M:%S.%f",
        "%Y/%m/%d %H:%M:%S",
        "%H:%M:%S.%f",
        "%H:%M:%S",
    ]
    parsed = None
    matched_format = None
    for fmt in formats:
        try:
            parsed = dt.datetime.strptime(value, fmt)
            matched_format = fmt
            break
        except ValueError:
            pass
    if parsed is None:
        raise ValueError('Use "20:00:00.000" or "2026-05-02 20:00:00.000".')

    has_date = bool(re.match(r"^\d{4}[-/]\d{2}[-/]\d{2}", value))
    now_kst = dt.datetime.now(KST)
    if not has_date:
        parsed = dt.datetime(
            now_kst.year,
            now_kst.month,
            now_kst.day,
            parsed.hour,
            parsed.minute,
            parsed.second,
            parsed.microsecond,
            tzinfo=KST,
        )
        if parsed <= now_kst:
            parsed += dt.timedelta(days=1)
    else:
        parsed = parsed.replace(tzinfo=KST)

    return unix_ms_from_utc(parsed.astimezone(dt.timezone.utc)), matched_format


def fetch_state_estimate(api_base):
    url = api_base.rstrip("/") + "/api/state"
    req = Request(url, headers={"Cache-Control": "no-store"})
    t0 = time.perf_counter()
    with urlopen(req, timeout=2) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    t1 = time.perf_counter()
    api_rtt_ms = (t1 - t0) * 1000.0

    status = payload.get("status", "")
    if not payload.get("targetUrl"):
        raise RuntimeError("No measured target URL. Run main run.bat first.")
    if status in ("idle", "queued", "measuring"):
        raise RuntimeError("Measurement is not ready yet. status=%s" % status)
    if status == "failed":
        raise RuntimeError("Measurement failed in the main tool.")

    base_server_ms = (
        float(payload.get("pcSendTimeAtMs", 0.0))
        + float(payload.get("offsetMs", 0.0))
        + api_rtt_ms / 2.0
    )
    return {
        "state": payload,
        "base_tick": t1,
        "base_server_ms": base_server_ms,
        "api_rtt_ms": api_rtt_ms,
    }


def estimated_server_now_ms(estimate):
    return estimate["base_server_ms"] + (time.perf_counter() - estimate["base_tick"]) * 1000.0


def wait_until_server_ms(estimate, target_ms, final_spin_ms, cancel_event, progress_cb):
    last_progress = 0.0
    while not cancel_event.is_set():
        remaining = target_ms - estimated_server_now_ms(estimate)
        now = time.perf_counter()
        if now - last_progress >= 0.05:
            progress_cb(max(0.0, remaining))
            last_progress = now
        if remaining <= final_spin_ms:
            break
        sleep_ms = max(1.0, min(100.0, remaining - final_spin_ms))
        time.sleep(sleep_ms / 1000.0)

    while not cancel_event.is_set() and estimated_server_now_ms(estimate) < target_ms:
        pass


class ClickerApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Server Time Clicker")
        self.root.geometry("520x420")
        self.root.resizable(False, False)

        self.messages = queue.Queue()
        self.worker = None
        self.cancel_event = threading.Event()
        self.armed = False

        self.target_var = tk.StringVar(value="20:00:00.000")
        self.api_var = tk.StringVar(value=DEFAULT_API_BASE)
        self.lead_var = tk.StringVar(value="0")
        self.resync_var = tk.StringVar(value="3000")
        self.spin_var = tk.StringVar(value="25")
        self.status_var = tk.StringVar(value="Run main run.bat first, then refresh state.")
        self.detail_var = tk.StringVar(value="")
        self.countdown_var = tk.StringVar(value="Not armed")

        self.build_ui()
        self.root.after(50, self.drain_messages)

    def build_ui(self):
        pad = {"padx": 12, "pady": 6}

        frame = ttk.Frame(self.root)
        frame.pack(fill="both", expand=True, padx=14, pady=12)

        ttk.Label(frame, text="Target server time (KST)").grid(row=0, column=0, sticky="w", **pad)
        ttk.Entry(frame, textvariable=self.target_var, width=30).grid(row=0, column=1, sticky="ew", **pad)

        hint = "Examples: 20:00:00.000 / 20:00:00 / 2026-05-02 20:00:00.000"
        ttk.Label(frame, text=hint, foreground="#555").grid(row=1, column=0, columnspan=2, sticky="w", padx=12)

        ttk.Label(frame, text="State API").grid(row=2, column=0, sticky="w", **pad)
        ttk.Entry(frame, textvariable=self.api_var, width=30).grid(row=2, column=1, sticky="ew", **pad)

        ttk.Label(frame, text="Lead ms").grid(row=3, column=0, sticky="w", **pad)
        ttk.Entry(frame, textvariable=self.lead_var, width=12).grid(row=3, column=1, sticky="w", **pad)

        ttk.Label(frame, text="Resync before ms").grid(row=4, column=0, sticky="w", **pad)
        ttk.Entry(frame, textvariable=self.resync_var, width=12).grid(row=4, column=1, sticky="w", **pad)

        ttk.Label(frame, text="Final spin ms").grid(row=5, column=0, sticky="w", **pad)
        ttk.Entry(frame, textvariable=self.spin_var, width=12).grid(row=5, column=1, sticky="w", **pad)

        button_frame = ttk.Frame(frame)
        button_frame.grid(row=6, column=0, columnspan=2, sticky="ew", pady=(12, 8))

        self.refresh_btn = ttk.Button(button_frame, text="Refresh State", command=self.refresh_state)
        self.refresh_btn.pack(side="left", padx=6)
        self.arm_btn = ttk.Button(button_frame, text="Arm", command=self.arm)
        self.arm_btn.pack(side="left", padx=6)
        self.cancel_btn = ttk.Button(button_frame, text="Cancel", command=self.cancel, state="disabled")
        self.cancel_btn.pack(side="left", padx=6)
        self.test_btn = ttk.Button(button_frame, text="Test Click", command=self.test_click)
        self.test_btn.pack(side="left", padx=6)

        ttk.Separator(frame).grid(row=7, column=0, columnspan=2, sticky="ew", pady=10)

        ttk.Label(frame, textvariable=self.countdown_var, font=("Segoe UI", 16, "bold")).grid(
            row=8, column=0, columnspan=2, sticky="w", padx=12, pady=8
        )
        ttk.Label(frame, textvariable=self.status_var, wraplength=470).grid(
            row=9, column=0, columnspan=2, sticky="w", padx=12, pady=4
        )
        ttk.Label(frame, textvariable=self.detail_var, foreground="#555", wraplength=470).grid(
            row=10, column=0, columnspan=2, sticky="w", padx=12, pady=4
        )

        frame.columnconfigure(1, weight=1)

    def parse_int(self, var, name, minimum, maximum):
        try:
            value = int(var.get().strip())
        except ValueError:
            raise ValueError("%s must be an integer." % name)
        if value < minimum or value > maximum:
            raise ValueError("%s must be between %d and %d." % (name, minimum, maximum))
        return value

    def set_controls_armed(self, armed):
        self.armed = armed
        self.arm_btn.config(state="disabled" if armed else "normal")
        self.cancel_btn.config(state="normal" if armed else "disabled")
        self.refresh_btn.config(state="disabled" if armed else "normal")
        self.test_btn.config(state="disabled" if armed else "normal")

    def refresh_state(self):
        def task():
            try:
                estimate = fetch_state_estimate(self.api_var.get())
                state = estimate["state"]
                self.messages.put(("state", estimate, state))
            except Exception as exc:
                self.messages.put(("error", str(exc)))

        threading.Thread(target=task, daemon=True).start()

    def arm(self):
        if self.armed:
            return
        try:
            target_ms, _ = parse_target_time(self.target_var.get())
            lead_ms = self.parse_int(self.lead_var, "Lead ms", 0, 1000)
            resync_before_ms = self.parse_int(self.resync_var, "Resync before ms", 0, 60000)
            final_spin_ms = self.parse_int(self.spin_var, "Final spin ms", 1, 500)
        except Exception as exc:
            messagebox.showerror("Invalid setting", str(exc))
            return

        fire_ms = target_ms - lead_ms
        self.cancel_event = threading.Event()
        self.set_controls_armed(True)
        self.status_var.set("Arming...")
        self.detail_var.set("Move the mouse to the click position before the countdown ends.")

        args = (fire_ms, target_ms, lead_ms, resync_before_ms, final_spin_ms, self.cancel_event)
        self.worker = threading.Thread(target=self.run_schedule, args=args, daemon=True)
        self.worker.start()

    def cancel(self):
        self.cancel_event.set()
        self.status_var.set("Cancel requested.")

    def test_click(self):
        if messagebox.askyesno("Test Click", "Left-click once at the current mouse position?"):
            try:
                left_click_once()
                self.status_var.set("Test click done.")
            except Exception as exc:
                messagebox.showerror("Click failed", str(exc))

    def run_schedule(self, fire_ms, target_ms, lead_ms, resync_before_ms, final_spin_ms, cancel_event):
        try:
            estimate = fetch_state_estimate(self.api_var.get())
            remaining = fire_ms - estimated_server_now_ms(estimate)
            if remaining <= 0:
                raise RuntimeError("Fire time has already passed.")

            self.messages.put(("armed", estimate, remaining, target_ms, fire_ms, lead_ms))

            if remaining > resync_before_ms + 250:
                wait_ms = remaining - resync_before_ms
                deadline = time.perf_counter() + wait_ms / 1000.0
                while not cancel_event.is_set() and time.perf_counter() < deadline:
                    left_ms = (deadline - time.perf_counter()) * 1000.0 + resync_before_ms
                    self.messages.put(("countdown", left_ms))
                    time.sleep(0.05)

                if cancel_event.is_set():
                    self.messages.put(("cancelled",))
                    return

                estimate = fetch_state_estimate(self.api_var.get())
                remaining = fire_ms - estimated_server_now_ms(estimate)
                if remaining <= 0:
                    raise RuntimeError("Fire time has already passed after resync.")
                self.messages.put(("resynced", estimate, remaining))

            wait_until_server_ms(
                estimate,
                fire_ms,
                final_spin_ms,
                cancel_event,
                lambda ms: self.messages.put(("countdown", ms)),
            )
            if cancel_event.is_set():
                self.messages.put(("cancelled",))
                return

            click_start = time.perf_counter()
            estimated_click_ms = estimated_server_now_ms(estimate)
            left_click_once()
            click_call_ms = (time.perf_counter() - click_start) * 1000.0
            self.messages.put(("clicked", estimated_click_ms, fire_ms, click_call_ms, target_ms))
        except (URLError, TimeoutError) as exc:
            self.messages.put(("error", "State API request failed: %s" % exc))
        except Exception as exc:
            self.messages.put(("error", str(exc)))

    def drain_messages(self):
        try:
            while True:
                msg = self.messages.get_nowait()
                self.handle_message(msg)
        except queue.Empty:
            pass
        self.root.after(50, self.drain_messages)

    def handle_message(self, msg):
        kind = msg[0]
        if kind == "state":
            estimate, state = msg[1], msg[2]
            self.status_var.set("State ready: status=%s, host=%s" % (state.get("status"), state.get("host", "")))
            self.detail_var.set(
                "apiRtt=%.3fms, offset=%.3fms, ci95=%.3fms"
                % (
                    estimate["api_rtt_ms"],
                    float(state.get("offsetMs", 0.0)),
                    float(state.get("ci95Ms", 0.0)),
                )
            )
        elif kind == "armed":
            estimate, remaining, target_ms, fire_ms, lead_ms = msg[1:]
            self.countdown_var.set("Remaining: %.1f ms" % remaining)
            self.status_var.set("Armed. Target=%s" % dt_from_unix_ms_kst(target_ms).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])
            self.detail_var.set(
                "Fire=%s, LeadMs=%d, apiRtt=%.3fms, ci95=%.3fms"
                % (
                    dt_from_unix_ms_kst(fire_ms).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3],
                    lead_ms,
                    estimate["api_rtt_ms"],
                    float(estimate["state"].get("ci95Ms", 0.0)),
                )
            )
        elif kind == "resynced":
            estimate, remaining = msg[1], msg[2]
            self.status_var.set("Resynced. Final wait started.")
            self.detail_var.set("apiRtt=%.3fms, remaining=%.1fms" % (estimate["api_rtt_ms"], remaining))
        elif kind == "countdown":
            self.countdown_var.set("Remaining: %.1f ms" % msg[1])
        elif kind == "clicked":
            estimated_click_ms, fire_ms, click_call_ms, target_ms = msg[1:]
            error_ms = estimated_click_ms - fire_ms
            self.countdown_var.set("Clicked")
            self.status_var.set(
                "Estimated click time=%s"
                % dt_from_unix_ms_kst(estimated_click_ms).strftime("%Y-%m-%d %H:%M:%S.%f")[:-3]
            )
            self.detail_var.set("targetError=%.3fms, clickCall=%.3fms" % (error_ms, click_call_ms))
            self.set_controls_armed(False)
        elif kind == "cancelled":
            self.countdown_var.set("Cancelled")
            self.status_var.set("Schedule cancelled. You can set another target.")
            self.detail_var.set("")
            self.set_controls_armed(False)
        elif kind == "error":
            self.countdown_var.set("Not armed")
            self.status_var.set("Error: %s" % msg[1])
            self.detail_var.set("")
            self.set_controls_armed(False)


def main():
    root = tk.Tk()
    try:
        ttk.Style().theme_use("vista")
    except tk.TclError:
        pass
    ClickerApp(root)
    root.mainloop()


if __name__ == "__main__":
    main()
