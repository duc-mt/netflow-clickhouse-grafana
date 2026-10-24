#!/usr/bin/env bash
#
# Kiểm thử end-to-end KHÔNG cần Docker: chạy Vector thật + GoFlow2 thật, gửi gói UDP thật
# (Syslog Palo Alto/FortiGate/Check Point, NetFlow v5/v9/IPFIX) và đọc lại các hàng mà Vector
# sẽ INSERT vào ClickHouse (ClickHouse được giả bằng một HTTP server nhỏ).
#
# Cấu hình được nạp bằng biến VECTOR_CONFIG (dấu phẩy + glob), đúng như trong docker-compose.
# Chỉ các thay đổi sau được áp dụng lên BẢN SAO cấu hình để chạy ngoài Docker (không đụng file gốc):
# endpoint ClickHouse -> 127.0.0.1, đường dẫn goflow2/mapping/data_dir -> thư mục tạm,
# và reduce của Check Point rút ngắn từ 60s xuống 3s cho nhanh.
#
# Cần các cổng trống: UDP 5514 5515 5516 2055, TCP 8123 và 8080.
#   ./tests/e2e/run_e2e.sh
#
set -euo pipefail
set -o errtrace

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="${ROOT}/tests/e2e"
VECTOR_VERSION="0.56.0"
GOFLOW2_VERSION="2.2.7"
CACHE="${ROOT}/.cache"
WORK="${E2E_DIR:-${TMPDIR:-/tmp}/panos-e2e}"
FAKE_PID=""
VEC_PID=""

trap 'echo "[ERROR] run_e2e.sh dừng tại dòng $LINENO" >&2' ERR
cleanup() {
  [[ -n "${VEC_PID}" ]] && kill "${VEC_PID}" 2>/dev/null || true
  [[ -n "${FAKE_PID}" ]] && kill "${FAKE_PID}" 2>/dev/null || true
  pkill -f "${WORK}/goflow2" 2>/dev/null || true
}
trap cleanup EXIT

ensure_binaries() {
  local arch_v arch_g
  case "$(uname -m)" in
    x86_64|amd64)  arch_v="x86_64";  arch_g="amd64" ;;
    aarch64|arm64) arch_v="aarch64"; arch_g="arm64" ;;
    *) echo "Kiến trúc không hỗ trợ: $(uname -m)" >&2; exit 1 ;;
  esac
  mkdir -p "${CACHE}"

  if command -v vector >/dev/null 2>&1 && vector --version | grep -q "vector ${VECTOR_VERSION}"; then
    VECTOR_BIN="$(command -v vector)"
  else
    VECTOR_BIN="${CACHE}/vector-${arch_v}-unknown-linux-gnu/bin/vector"
    if [[ ! -x "${VECTOR_BIN}" ]]; then
      echo "[INFO] Tải Vector ${VECTOR_VERSION}"
      curl -fL --retry 3 -o "${CACHE}/vector.tgz" \
        "https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-${arch_v}-unknown-linux-gnu.tar.gz"
      tar -xzf "${CACHE}/vector.tgz" -C "${CACHE}" && rm -f "${CACHE}/vector.tgz"
    fi
  fi

  GOFLOW2_BIN="${ROOT}/goflow2/goflow2"
  if [[ ! -x "${GOFLOW2_BIN}" ]]; then
    GOFLOW2_BIN="${CACHE}/goflow2-${GOFLOW2_VERSION}-${arch_g}"
    if [[ ! -x "${GOFLOW2_BIN}" ]]; then
      echo "[INFO] Tải GoFlow2 ${GOFLOW2_VERSION}"
      curl -fL --retry 3 -o "${GOFLOW2_BIN}" \
        "https://github.com/netsampler/goflow2/releases/download/v${GOFLOW2_VERSION}/goflow2-${GOFLOW2_VERSION}-linux-${arch_g}"
      chmod +x "${GOFLOW2_BIN}"
    fi
  fi
}

main() {
  ensure_binaries
  export CLICKHOUSE_USER="test" CLICKHOUSE_PASSWORD="test-password-123"

  rm -rf "${WORK}"
  mkdir -p "${WORK}/cfg/vendors" "${WORK}/vdata" "${WORK}/templates"
  cp "${GOFLOW2_BIN}" "${WORK}/goflow2"
  chmod +x "${WORK}/goflow2"
  cp "${ROOT}/vector/vector.yaml" "${WORK}/cfg/vector.yaml"
  cp "${ROOT}"/vector/vendors/*.yaml "${WORK}/cfg/vendors/"
  sed -i \
    -e 's#http://clickhouse:8123#http://127.0.0.1:8123#' \
    -e "s#/opt/goflow2/goflow2#${WORK}/goflow2#" \
    -e "s#/opt/goflow2/mapping.yaml#${ROOT}/goflow2/mapping.yaml#" \
    -e "s#-templates.path=/templates#-templates.path=${WORK}/templates#" \
    -e "s#data_dir: /var/lib/vector#data_dir: ${WORK}/vdata#" \
    -e 's#expire_after_ms: 60000#expire_after_ms: 3000#' \
    -e 's#flush_period_ms: 5000#flush_period_ms: 500#' \
    "${WORK}/cfg/vector.yaml" "${WORK}"/cfg/vendors/*.yaml

  python3 "${HERE}/fake_clickhouse.py" "${WORK}/received.jsonl" 8123 &
  FAKE_PID=$!
  sleep 1

  echo "[INFO] Khởi động Vector (VECTOR_CONFIG = vector.yaml + vendors/*.yaml)"
  VECTOR_CONFIG="${WORK}/cfg/vector.yaml,${WORK}/cfg/vendors/*.yaml" "${VECTOR_BIN}" > "${WORK}/vector.log" 2>&1 &
  VEC_PID=$!
  sleep 8

  python3 "${HERE}/send_packets.py"
  sleep 16

  kill "${VEC_PID}" 2>/dev/null || true
  VEC_PID=""
  sleep 2

  if grep -E ' ERROR ' "${WORK}/vector.log" >/dev/null 2>&1; then
    echo "[WARN] Vector ghi ERROR:"
    grep -E ' ERROR ' "${WORK}/vector.log" | head -5
  fi
  [[ -s "${WORK}/received.jsonl" ]] || { echo "[ERROR] Không nhận được INSERT nào. Xem ${WORK}/vector.log" >&2; exit 1; }

  python3 "${HERE}/verify.py" "${WORK}/received.jsonl"
}

main "$@"
