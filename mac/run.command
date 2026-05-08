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
