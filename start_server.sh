#!/bin/zsh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${UVC_CAM_PORT:-8443}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "오류: python3를 찾을 수 없습니다."
  exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
  echo "오류: openssl을 찾을 수 없습니다."
  exit 1
fi

WIFI_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
if [ -n "$WIFI_IP" ]; then
  echo "▶ iPad Safari에서 다음 주소로 접속하세요: https://${WIFI_IP}:${PORT}"
fi

exec python3 "${SCRIPT_DIR}/server.py"
