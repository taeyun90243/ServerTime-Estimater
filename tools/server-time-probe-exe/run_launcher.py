import os
import subprocess
import sys


def app_dir():
    if getattr(sys, "frozen", False):
        return os.path.dirname(sys.executable)
    return os.path.dirname(os.path.abspath(__file__))


def main():
    root = app_dir()
    script = os.path.join(root, "src", "probe.ps1")

    if not os.path.exists(script):
        print("src\\probe.ps1 not found.")
        print("Put this EXE in the project root folder.")
        input("\nPress Enter to exit...")
        return 1

    os.chdir(root)
    cmd = [
        "powershell",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        script,
    ]

    try:
        return subprocess.call(cmd)
    finally:
        print()
        print("[program ended]")
        input("Press Enter to exit...")


if __name__ == "__main__":
    raise SystemExit(main())
