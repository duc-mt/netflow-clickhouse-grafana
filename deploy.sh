#!/usr/bin/env bash
#
# deploy.sh - Bootstrap "zero-touch" cho netflow-clickhouse-grafana trên Ubuntu mới.
#
#   - Idempotent: chạy lại nhiều lần an toàn (cron không bị nhân đôi).
#   - Yêu cầu quyền root:   sudo ./deploy.sh
#   - Mọi bí mật và COLLECTOR_IP đọc từ file .env (không hard-code).
#   - VENDORS trong .env (tùy chọn): bật thu Syslog của hãng khác, ví dụ VENDORS=fortigate,checkpoint
#     (NetFlow/IPFIX từ mọi hãng luôn đi vào UDP/2055, không cần bật gì thêm).
#
set -euo pipefail
set -o errtrace
umask 022

# ----------------------------------------------------------------------------
# Hằng số
# ----------------------------------------------------------------------------
readonly GOFLOW2_VERSION="2.2.7"
readonly GOFLOW2_BASE_URL="https://github.com/netsampler/goflow2/releases/download/v${GOFLOW2_VERSION}"
readonly CLICKHOUSE_UID="101"
readonly CLICKHOUSE_GID="101"
readonly GRAFANA_UID="472"
readonly GRAFANA_GID="0"
readonly CRON_SCHEDULE="15 3 * * *"
readonly CRON_MARKER="# managed-by: netflow-clickhouse-grafana/update_vn_prefixes"
readonly VN_LOG="${VN_LOG:-/var/log/vn_prefixes.log}"
readonly LOGROTATE_FILE="${LOGROTATE_FILE:-/etc/logrotate.d/netflow-clickhouse-grafana}"
readonly WAIT_TIMEOUT=180
readonly GRAFANA_URL="http://127.0.0.1:3000"
readonly KNOWN_VENDORS="fortigate checkpoint"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALL_DIR="${SCRIPT_DIR}"
readonly ENV_FILE="${INSTALL_DIR}/.env"
readonly ENV_EXAMPLE="${INSTALL_DIR}/.env.example"
readonly UPDATE_SCRIPT="${INSTALL_DIR}/scripts/update_vn_prefixes.py"
readonly VN_CSV="${INSTALL_DIR}/clickhouse/user_files/vn_prefixes.csv"

TMP_DIR=""
FAILURES=0
CH_USER=""
COLLECTOR_IP=""
GF_PASS=""
VENDORS_ENABLED=()
COMPOSE_FILES=("${INSTALL_DIR}/docker-compose.yml")

# ----------------------------------------------------------------------------
# Log, bắt lỗi, dọn dẹp
# ----------------------------------------------------------------------------
log()  { printf '[INFO]  %s\n' "$*"; }
ok()   { printf '[ OK ]  %s\n' "$*"; }
warn() { printf '[WARN]  %s\n' "$*" >&2; }
fail() { printf '[FAIL]  %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

on_error() {
  local code="$1" line="$2"
  printf '[ERROR] deploy.sh dừng tại dòng %s (mã thoát %s).\n' "${line}" "${code}" >&2
  printf '        Xem README.md > Troubleshooting. Chạy lại ./deploy.sh là an toàn.\n' >&2
}

cleanup() {
  if [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]]; then
    rm -rf "${TMP_DIR}"
  fi
}

trap 'on_error $? $LINENO' ERR
trap cleanup EXIT

compose() {
  local -a args=(--project-directory "${INSTALL_DIR}")
  local f
  for f in "${COMPOSE_FILES[@]}"; do
    args+=(-f "${f}")
  done
  docker compose "${args[@]}" "$@"
}

vendor_port() {
  case "$1" in
    fortigate)  printf '5515' ;;
    checkpoint) printf '5516' ;;
    *) die "Vendor không có cổng được định nghĩa: $1" ;;
  esac
}

# ----------------------------------------------------------------------------
# Kiểm tra điều kiện tiên quyết
# ----------------------------------------------------------------------------
require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Cần quyền root. Chạy: sudo ./deploy.sh"
}

check_os() {
  local os_id="" os_version=""
  if [[ -r /etc/os-release ]]; then
    os_id="$(. /etc/os-release && printf '%s' "${ID:-}")"
    os_version="$(. /etc/os-release && printf '%s' "${VERSION_ID:-}")"
  fi
  if [[ "${os_id}" == "ubuntu" ]]; then
    ok "Hệ điều hành: Ubuntu ${os_version}"
  else
    warn "Hệ điều hành là '${os_id:-không rõ}'; script nhắm tới Ubuntu 22.04/24.04. Tiếp tục có rủi ro."
  fi
  command -v apt-get >/dev/null 2>&1 || die "Không tìm thấy apt-get (script chỉ hỗ trợ họ Debian/Ubuntu)"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    *) die "Kiến trúc CPU không được hỗ trợ: $(uname -m)" ;;
  esac
}

check_repo_layout() {
  local f missing=0
  for f in \
    docker-compose.yml \
    .env.example \
    vector/vector.yaml \
    goflow2/mapping.yaml \
    scripts/update_vn_prefixes.py \
    clickhouse/init/01_schema.sql \
    clickhouse/init/02_netflow.sql \
    grafana/provisioning/datasources/clickhouse.yaml \
    grafana/provisioning/dashboards/dashboards.yaml \
    grafana/dashboards/dashboard-bang-thong.json \
    grafana/dashboards/dashboard-thoi-gian-thuc.json; do
    if [[ ! -f "${INSTALL_DIR}/${f}" ]]; then
      warn "Thiếu file bắt buộc: ${f}"
      missing=1
    fi
  done
  (( missing == 0 )) || die "Repo không đầy đủ, dừng triển khai"
  ok "Cấu trúc repo đầy đủ"
}

# ----------------------------------------------------------------------------
# .env
# ----------------------------------------------------------------------------
env_get() {
  local key="$1" value
  value="$(grep -E "^${key}=" "${ENV_FILE}" | tail -n 1 | cut -d= -f2- | tr -d '\r' || true)"
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  printf '%s' "${value}"
}

is_ipv4() {
  local ip="$1" octet
  local -a parts
  [[ "${ip}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS='.' read -r -a parts <<< "${ip}"
  for octet in "${parts[@]}"; do
    (( 10#${octet} <= 255 )) || return 1
  done
  return 0
}

validate_env() {
  local key value

  if [[ ! -f "${ENV_FILE}" ]]; then
    [[ -f "${ENV_EXAMPLE}" ]] || die "Thiếu cả .env lẫn .env.example tại ${INSTALL_DIR}"
    install -m 600 "${ENV_EXAMPLE}" "${ENV_FILE}"
    die "Đã tạo ${ENV_FILE} từ .env.example. Hãy điền CLICKHOUSE_PASSWORD, GRAFANA_ADMIN_PASSWORD, COLLECTOR_IP rồi chạy lại ./deploy.sh"
  fi
  chmod 600 "${ENV_FILE}"

  for key in CLICKHOUSE_USER CLICKHOUSE_PASSWORD GRAFANA_ADMIN_PASSWORD COLLECTOR_IP; do
    value="$(env_get "${key}")"
    [[ -n "${value}" ]] || die "Biến ${key} đang trống trong ${ENV_FILE}"
  done

  CH_USER="$(env_get CLICKHOUSE_USER)"
  GF_PASS="$(env_get GRAFANA_ADMIN_PASSWORD)"
  COLLECTOR_IP="$(env_get COLLECTOR_IP)"

  [[ "${CH_USER}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,31}$ ]] \
    || die "CLICKHOUSE_USER chỉ gồm chữ, số, dấu gạch dưới và phải bắt đầu bằng chữ"

  for key in CLICKHOUSE_PASSWORD GRAFANA_ADMIN_PASSWORD; do
    value="$(env_get "${key}")"
    [[ "${value}" != "doi-mat-khau-nay" ]] || die "Hãy đổi mật khẩu mẫu 'doi-mat-khau-nay' của ${key} trong .env"
    [[ "${value}" =~ ^[A-Za-z0-9._-]{12,}$ ]] \
      || die "${key} phải dài >= 12 ký tự và chỉ gồm A-Z a-z 0-9 . _ -"
  done

  is_ipv4 "${COLLECTOR_IP}" || die "COLLECTOR_IP='${COLLECTOR_IP}' không phải IPv4 hợp lệ"
  case "${COLLECTOR_IP}" in
    0.*|127.*) die "COLLECTOR_IP phải là IP mà Palo Alto truy cập được, không thể là ${COLLECTOR_IP}" ;;
  esac

  ok ".env hợp lệ (COLLECTOR_IP=${COLLECTOR_IP})"
}

# Đọc VENDORS từ .env, kiểm tra hợp lệ và thêm các file compose tương ứng.
configure_vendors() {
  local raw v
  local -a requested=()
  raw="$(env_get VENDORS)"
  raw="${raw//[[:space:]]/}"
  if [[ -z "${raw}" ]]; then
    log "VENDORS trống: chỉ thu Palo Alto (Syslog UDP/5514) và NetFlow/IPFIX (UDP/2055)"
    return 0
  fi

  IFS=',' read -r -a requested <<< "${raw}"
  for v in "${requested[@]}"; do
    [[ -n "${v}" ]] || continue
    case " ${KNOWN_VENDORS} " in
      *" ${v} "*) ;;
      *) die "VENDORS: '${v}' không được hỗ trợ (hợp lệ: ${KNOWN_VENDORS// /, })" ;;
    esac
    if [[ " ${VENDORS_ENABLED[*]:-} " == *" ${v} "* ]]; then
      continue
    fi
    [[ -f "${INSTALL_DIR}/compose/${v}.yml" && -f "${INSTALL_DIR}/vector/vendors/${v}.yaml" ]] \
      || die "Thiếu file cấu hình của vendor '${v}' (compose/${v}.yml hoặc vector/vendors/${v}.yaml)"
    VENDORS_ENABLED+=("${v}")
  done

  if (( ${#VENDORS_ENABLED[@]} > 0 )); then
    [[ -f "${INSTALL_DIR}/compose/vendors.yml" ]] || die "Thiếu compose/vendors.yml"
    COMPOSE_FILES+=("${INSTALL_DIR}/compose/vendors.yml")
    for v in "${VENDORS_ENABLED[@]}"; do
      COMPOSE_FILES+=("${INSTALL_DIR}/compose/${v}.yml")
    done
    ok "Vendor được bật: ${VENDORS_ENABLED[*]}"
  fi
}

# ----------------------------------------------------------------------------
# Gói hệ thống & Docker
# ----------------------------------------------------------------------------
ensure_packages() {
  local pkg
  local -a missing=()
  for pkg in ca-certificates curl gnupg python3 cron iproute2 logrotate; do
    dpkg -s "${pkg}" >/dev/null 2>&1 || missing+=("${pkg}")
  done
  if (( ${#missing[@]} > 0 )); then
    log "Cài các gói còn thiếu: ${missing[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
  fi
  systemctl enable --now cron >/dev/null 2>&1 || true
  ok "Gói hệ thống đầy đủ"
}

install_docker() {
  local codename arch
  codename="$(. /etc/os-release && printf '%s' "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
  [[ -n "${codename}" ]] || die "Không xác định được codename Ubuntu để thêm kho Docker"
  arch="$(dpkg --print-architecture)"

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL --retry 3 https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "${arch}" "${codename}" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    log "Chưa có Docker -> cài Docker Engine từ kho apt chính thức của Docker"
    install_docker
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || die "Docker daemon không phản hồi (docker info lỗi). Xem: journalctl -u docker"

  if ! docker compose version >/dev/null 2>&1; then
    log "Thiếu Docker Compose plugin -> cài đặt"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin \
      || DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-v2
  fi
  docker compose version >/dev/null 2>&1 || die "Vẫn không có lệnh 'docker compose' sau khi cài"
  ok "Docker $(docker --version | cut -d' ' -f3 | tr -d ',') / Compose $(docker compose version --short)"
}

# ----------------------------------------------------------------------------
# Thư mục, GoFlow2, danh sách IP Việt Nam, phân quyền
# ----------------------------------------------------------------------------
prepare_directories() {
  mkdir -p \
    "${INSTALL_DIR}/clickhouse/data" \
    "${INSTALL_DIR}/clickhouse/user_files" \
    "${INSTALL_DIR}/vector/data" \
    "${INSTALL_DIR}/goflow2" \
    "${INSTALL_DIR}/grafana/data"
  ok "Đã chuẩn bị các thư mục runtime"
}

install_goflow2() {
  local arch url target marker sha tmp
  arch="$(detect_arch)"
  url="${GOFLOW2_BASE_URL}/goflow2-${GOFLOW2_VERSION}-linux-${arch}"
  target="${INSTALL_DIR}/goflow2/goflow2"
  marker="${INSTALL_DIR}/goflow2/.version"

  if [[ -x "${target}" && -f "${marker}" && "$(cat "${marker}")" == "${GOFLOW2_VERSION}-${arch}" ]]; then
    ok "GoFlow2 v${GOFLOW2_VERSION} (${arch}) đã có, bỏ qua bước tải"
    return 0
  fi

  TMP_DIR="${TMP_DIR:-$(mktemp -d)}"
  tmp="${TMP_DIR}/goflow2"
  log "Tải GoFlow2 v${GOFLOW2_VERSION} (${arch}) từ GitHub Releases"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "${tmp}" "${url}"
  (( $(stat -c %s "${tmp}") > 1000000 )) || die "File GoFlow2 tải về quá nhỏ, nghi ngờ tải lỗi"

  sha="$(env_get GOFLOW2_SHA256)"
  if [[ -n "${sha}" ]]; then
    printf '%s  %s\n' "${sha}" "${tmp}" | sha256sum -c - >/dev/null || die "Sai checksum SHA256 của GoFlow2"
    ok "Checksum SHA256 của GoFlow2 khớp"
  else
    warn "Chưa đặt GOFLOW2_SHA256 trong .env -> bỏ qua xác minh checksum"
  fi

  install -m 0755 "${tmp}" "${target}"
  printf '%s' "${GOFLOW2_VERSION}-${arch}" > "${marker}"
  ok "Đã cài ${target}"
}

refresh_vn_prefixes() {
  log "Tải danh sách dải IP Việt Nam từ APNIC (update_vn_prefixes.py)"
  if ! python3 "${UPDATE_SCRIPT}"; then
    if [[ -s "${VN_CSV}" ]]; then
      warn "Cập nhật từ APNIC lỗi, giữ nguyên ${VN_CSV} hiện có"
    else
      die "Không tạo được ${VN_CSV}. Kiểm tra kết nối HTTPS tới ftp.apnic.net"
    fi
  fi
  [[ -s "${VN_CSV}" ]] || die "${VN_CSV} rỗng"
  chmod 644 "${VN_CSV}"
  ok "vn_prefixes.csv sẵn sàng"
}

apply_permissions() {
  local ch_data="${INSTALL_DIR}/clickhouse/data"
  # Chỉ chown đệ quy thư mục dữ liệu lớn khi chủ sở hữu sai (tránh quét lại mỗi lần chạy).
  if [[ "$(stat -c '%u:%g' "${ch_data}")" != "${CLICKHOUSE_UID}:${CLICKHOUSE_GID}" ]]; then
    chown -R "${CLICKHOUSE_UID}:${CLICKHOUSE_GID}" "${ch_data}"
  fi
  chown -R "${CLICKHOUSE_UID}:${CLICKHOUSE_GID}" "${INSTALL_DIR}/clickhouse/user_files"
  chown -R "${GRAFANA_UID}:${GRAFANA_GID}" "${INSTALL_DIR}/grafana/data"
  chmod 755 "${INSTALL_DIR}/goflow2/goflow2"
  ok "Phân quyền: clickhouse ${CLICKHOUSE_UID}:${CLICKHOUSE_GID}, grafana ${GRAFANA_UID}:${GRAFANA_GID}"
}

# ----------------------------------------------------------------------------
# Khởi chạy stack
# ----------------------------------------------------------------------------
start_stack() {
  log "Kiểm tra cú pháp docker-compose.yml và biến .env"
  compose config -q
  log "Pull image (phiên bản đã ghim)"
  compose pull
  log "docker compose up -d"
  compose up -d --remove-orphans
}

# ----------------------------------------------------------------------------
# Crontab (idempotent) & logrotate
# ----------------------------------------------------------------------------
install_cron() {
  local py cron_line tmp n
  py="$(command -v python3)"
  cron_line="${CRON_SCHEDULE} ${py} ${UPDATE_SCRIPT} >> ${VN_LOG} 2>&1"
  tmp="$(mktemp)"

  # Giữ mọi dòng cron khác; loại dòng cũ của chính script này rồi thêm lại đúng 1 lần.
  crontab -l 2>/dev/null | grep -vF -e "${CRON_MARKER}" -e "${UPDATE_SCRIPT}" > "${tmp}" || true
  printf '%s\n%s\n' "${CRON_MARKER}" "${cron_line}" >> "${tmp}"
  crontab "${tmp}"
  rm -f "${tmp}"

  touch "${VN_LOG}"
  chmod 640 "${VN_LOG}"
  cat > "${LOGROTATE_FILE}" <<EOF
${VN_LOG} {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
EOF

  n="$(crontab -l 2>/dev/null | grep -cF "${UPDATE_SCRIPT}" || true)"
  if [[ "${n}" == "1" ]]; then
    ok "Crontab: 1 dòng '${CRON_SCHEDULE}' cập nhật dải IP Việt Nam"
  else
    fail "Crontab có ${n} dòng update_vn_prefixes.py (mong đợi đúng 1)"
  fi
}

# ----------------------------------------------------------------------------
# Healthcheck
# ----------------------------------------------------------------------------
ch_query() {
  # Chủ ý dùng nháy đơn: biến $CLICKHOUSE_* được shell TRONG container mở rộng (mật khẩu không lộ ở ps của host).
  # shellcheck disable=SC2016
  compose exec -T clickhouse sh -c \
    'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "$1"' _ "$1"
}

# Chạy một file .sql (nhiều câu lệnh) bên trong container ClickHouse.
ch_file() {
  # Chủ ý dùng nháy đơn: biến $CLICKHOUSE_* được shell TRONG container mở rộng.
  # shellcheck disable=SC2016
  compose exec -T clickhouse sh -c \
    'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery' < "$1"
}

# Khi có vendor được bật: thêm cột vendor/device vào panos.traffic (idempotent, không đụng 01/02).
apply_vendor_migration() {
  local sql="${INSTALL_DIR}/clickhouse/migrations/04_add_vendor_columns.sql"
  (( ${#VENDORS_ENABLED[@]} > 0 )) || return 0
  [[ -f "${sql}" ]] || die "Thiếu ${sql}"
  log "Áp migration 04: thêm cột vendor, device vào panos.traffic (idempotent)"
  ch_file "${sql}"
  ok "Migration 04 đã áp dụng"
}

grafana_api() {
  printf 'user = "admin:%s"\n' "${GF_PASS}" | curl -fsS --max-time 10 -K - "${GRAFANA_URL}$1"
}

verify_stack() {
  local svc cid state out count waited port tops listeners local_ips v
  local -a ports=(5514 2055)
  for v in "${VENDORS_ENABLED[@]}"; do
    ports+=("$(vendor_port "${v}")")
  done

  log "Chờ 10 giây cho các tiến trình ổn định rồi kiểm tra"
  sleep 10

  for svc in clickhouse vector grafana; do
    cid="$(compose ps -q "${svc}" 2>/dev/null || true)"
    state="missing"
    if [[ -n "${cid}" ]]; then
      state="$(docker inspect -f '{{.State.Status}}' "${cid}" 2>/dev/null || echo unknown)"
    fi
    if [[ "${state}" == "running" ]]; then
      ok "Container ${svc}: running"
    else
      fail "Container ${svc}: ${state}"
    fi
  done

  # --- ClickHouse: healthy, dictionary, bảng ---
  cid="$(compose ps -q clickhouse 2>/dev/null || true)"
  state="unknown"
  waited=0
  while (( waited < WAIT_TIMEOUT )); do
    state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cid}" 2>/dev/null || echo unknown)"
    [[ "${state}" == "healthy" ]] && break
    sleep 5
    waited=$((waited + 5))
  done

  if [[ "${state}" == "healthy" ]]; then
    ok "ClickHouse healthy (init script đã chạy xong)"

    ch_query "SYSTEM RELOAD DICTIONARY panos.vn_prefix" >/dev/null 2>&1 || true
    out="$(ch_query "SELECT dictGetOrDefault('panos.vn_prefix', 'label', tuple(toIPv4('10.1.1.1')), 'MISS')" 2>/dev/null || true)"
    if [[ "${out}" == "Nội bộ" ]]; then
      ok "Dictionary panos.vn_prefix: 10.1.1.1 -> Nội bộ"
    else
      fail "Dictionary panos.vn_prefix không phân loại được 10.1.1.1 (kết quả: '${out:-rỗng}')"
    fi

    count="$(ch_query "SELECT element_count FROM system.dictionaries WHERE database = 'panos' AND name = 'vn_prefix'" 2>/dev/null || echo 0)"
    if [[ "${count}" =~ ^[0-9]+$ ]] && (( count > 100 )); then
      ok "Dictionary đang nạp ${count} dải IP"
    else
      fail "Dictionary chỉ có '${count}' dải IP (mong đợi > 100)"
    fi

    count="$(ch_query "SELECT count() FROM system.tables WHERE database = 'panos' AND name IN ('traffic','traffic_hourly','traffic_hourly_mv','flows')" 2>/dev/null || echo 0)"
    if [[ "${count}" == "4" ]]; then
      ok "Đủ 4 đối tượng: traffic, traffic_hourly, traffic_hourly_mv, flows"
    else
      fail "Chỉ có ${count}/4 đối tượng trong DB panos"
    fi

    if (( ${#VENDORS_ENABLED[@]} > 0 )); then
      count="$(ch_query "SELECT count() FROM system.columns WHERE database = 'panos' AND table = 'traffic' AND name IN ('vendor','device')" 2>/dev/null || echo 0)"
      if [[ "${count}" == "2" ]]; then
        ok "panos.traffic có cột vendor, device"
      else
        fail "panos.traffic thiếu cột vendor/device (chạy clickhouse/migrations/04_add_vendor_columns.sql)"
      fi
    fi
  else
    fail "ClickHouse chưa healthy sau ${WAIT_TIMEOUT}s (trạng thái: ${state}). Xem: docker compose logs clickhouse"
  fi

  # --- Vector + GoFlow2 ---
  tops="$(compose top vector 2>/dev/null || true)"
  if [[ "${tops}" == *goflow2* ]]; then
    ok "Vector đang chạy tiến trình con goflow2"
  else
    fail "Không thấy tiến trình goflow2 trong container vector (thiếu quyền thực thi / sai kiến trúc?)"
  fi

  listeners="$(ss -lunH 2>/dev/null || true)"
  for port in "${ports[@]}"; do
    if grep -Eq "[:.]${port}[[:space:]]" <<< "${listeners}"; then
      ok "UDP/${port} đang lắng nghe trên host"
    else
      warn "Không thấy UDP/${port} trong 'ss -lun' (có thể do userland-proxy tắt); xác nhận bằng tcpdump"
    fi
  done

  local_ips="$(ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1 || true)"
  if grep -qxF "${COLLECTOR_IP}" <<< "${local_ips}"; then
    ok "COLLECTOR_IP ${COLLECTOR_IP} gắn trên interface của máy này"
  else
    warn "COLLECTOR_IP ${COLLECTOR_IP} không gắn trực tiếp trên interface nào (NAT/VIP?). Palo Alto vẫn phải tới được IP này"
  fi

  # --- Grafana ---
  waited=0
  until curl -fsS --max-time 5 "${GRAFANA_URL}/api/health" >/dev/null 2>&1; do
    if (( waited >= WAIT_TIMEOUT )); then
      break
    fi
    sleep 5
    waited=$((waited + 5))
  done

  if curl -fsS --max-time 5 "${GRAFANA_URL}/api/health" >/dev/null 2>&1; then
    ok "Grafana /api/health OK"

    count=0
    waited=0
    while (( waited < 60 )); do
      out="$(grafana_api "/api/search?type=dash-db" 2>/dev/null || true)"
      count="$(grep -o '"uid"' <<< "${out}" | wc -l || true)"
      (( count >= 2 )) && break
      sleep 5
      waited=$((waited + 5))
    done
    if (( count >= 2 )); then
      ok "Provisioning: Grafana đã nạp ${count} dashboard"
    else
      warn "Chưa thấy đủ 2 dashboard (có thể mật khẩu admin đã đổi trong UI, hoặc provisioning chưa xong). Xem: docker compose logs grafana"
    fi

    out="$(grafana_api "/api/datasources/uid/clickhouse-panos/health" 2>/dev/null || true)"
    if [[ "${out}" =~ \"status\"[[:space:]]*:[[:space:]]*\"OK\" ]]; then
      ok "Datasource clickhouse-panos: OK"
    else
      warn "Chưa xác nhận được health của datasource clickhouse-panos (kết quả: ${out:-rỗng})"
    fi
  else
    fail "Grafana không phản hồi tại ${GRAFANA_URL} sau ${WAIT_TIMEOUT}s. Xem: docker compose logs grafana"
  fi

  if (( FAILURES > 0 )); then
    die "Healthcheck có ${FAILURES} lỗi nghiêm trọng. Xem: docker compose logs --tail=100"
  fi
}

print_summary() {
  local v vendor_lines=""
  for v in "${VENDORS_ENABLED[@]}"; do
    vendor_lines+=" Vendor    : ${v} Syslog UDP/$(vendor_port "${v}")  ->  ${COLLECTOR_IP}"$'\n'
  done
  cat <<EOF

================================================================
 netflow-clickhouse-grafana đã triển khai xong
================================================================
 Grafana   : http://${COLLECTOR_IP}:3000  (user: admin, mật khẩu: GRAFANA_ADMIN_PASSWORD trong .env)
 Collector : Syslog UDP/5514 (Palo Alto) | NetFlow/IPFIX UDP/2055  ->  ${COLLECTOR_IP}
${vendor_lines} Cron      : ${CRON_SCHEDULE}  update_vn_prefixes.py  (log: ${VN_LOG})

 Bước tiếp theo:
   1. Mở UFW / DOCKER-USER cho Palo Alto   (README mục 2.2)
   2. Cấu hình firewall, server = ${COLLECTOR_IP}   (README mục 4)
   3. Chạy các test case                   (README mục 5)
================================================================
EOF
}

# ----------------------------------------------------------------------------
main() {
  cd "${INSTALL_DIR}"
  require_root
  check_os
  check_repo_layout
  validate_env
  configure_vendors
  ensure_packages
  ensure_docker
  prepare_directories
  install_goflow2
  refresh_vn_prefixes
  apply_permissions
  start_stack
  apply_vendor_migration
  install_cron
  verify_stack
  print_summary
}

# Chỉ chạy main khi thực thi trực tiếp (cho phép `source deploy.sh` để kiểm thử từng hàm).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
