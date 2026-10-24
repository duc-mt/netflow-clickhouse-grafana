#!/usr/bin/env bash
#
# Chạy kiểm thử đơn vị VRL (vector test) cho panos_parse và các parser của từng hãng.
# Tự tải Vector (cùng phiên bản với image đã ghim) vào .cache/ nếu máy chưa có lệnh `vector`.
# Không cần Docker, không cần ClickHouse.
#
#   ./tests/run_vector_tests.sh
#
set -euo pipefail
set -o errtrace

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VECTOR_VERSION="0.56.0"
CACHE="${ROOT}/.cache"

trap 'echo "[ERROR] run_vector_tests.sh dừng tại dòng $LINENO" >&2' ERR

ensure_vector() {
  if command -v vector >/dev/null 2>&1 && vector --version | grep -q "vector ${VECTOR_VERSION}"; then
    VECTOR_BIN="$(command -v vector)"
    return 0
  fi
  local arch
  case "$(uname -m)" in
    x86_64|amd64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "Kiến trúc không hỗ trợ: $(uname -m)" >&2; exit 1 ;;
  esac
  VECTOR_BIN="${CACHE}/vector-${arch}-unknown-linux-gnu/bin/vector"
  if [[ ! -x "${VECTOR_BIN}" ]]; then
    mkdir -p "${CACHE}"
    echo "[INFO] Tải Vector ${VECTOR_VERSION} (${arch}) vào ${CACHE}"
    curl -fL --retry 3 -o "${CACHE}/vector.tgz" \
      "https://github.com/vectordotdev/vector/releases/download/v${VECTOR_VERSION}/vector-${VECTOR_VERSION}-${arch}-unknown-linux-gnu.tar.gz"
    tar -xzf "${CACHE}/vector.tgz" -C "${CACHE}"
    rm -f "${CACHE}/vector.tgz"
  fi
}

main() {
  ensure_vector
  echo "[INFO] $("${VECTOR_BIN}" --version)"

  # Biến môi trường giả để Vector nội suy ${CLICKHOUSE_*} khi nạp cấu hình
  export CLICKHOUSE_USER="test" CLICKHOUSE_PASSWORD="test-password-123"

  local -a cfgs=("${ROOT}/vector/vector.yaml")
  local f
  for f in "${ROOT}"/vector/vendors/*.yaml; do
    cfgs+=("${f}")
  done

  echo "[INFO] vector validate (cấu hình gốc + ${#cfgs[@]} file, không kết nối ClickHouse)"
  "${VECTOR_BIN}" validate --no-environment "${cfgs[@]}"

  echo "[INFO] vector test"
  "${VECTOR_BIN}" test "${cfgs[@]}" "${ROOT}"/vector/tests/*.test.yaml
}

main "$@"
