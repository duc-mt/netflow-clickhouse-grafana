#!/usr/bin/env bash
#
# Kiểm thử các hàm của deploy.sh trên BẢN SAO tạm của repo (không cần root, Docker hay apt).
#   ./tests/test_deploy.sh                      # chỉ test offline
#   RUN_NETWORK_TESTS=1 ./tests/test_deploy.sh  # thêm test tải GoFlow2 thật từ GitHub + kiểm tra SHA256
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

t()  { local d="$1"; shift; if "$@" >/tmp/pg-t.out 2>&1; then PASS=$((PASS+1)); printf 'PASS  %s\n' "$d"; else FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$d"; sed 's/^/        /' /tmp/pg-t.out; fi; }
nt() { local d="$1"; shift; if "$@" >/tmp/pg-t.out 2>&1; then FAIL=$((FAIL+1)); printf 'FAIL  %s (đáng lẽ phải lỗi)\n' "$d"; else PASS=$((PASS+1)); printf 'PASS  %s\n' "$d"; fi; }

W="$(mktemp -d)"
trap 'rm -rf "${W}"' EXIT
mkdir -p "${W}/repo"
tar -C "${ROOT}" --exclude='./.cache' --exclude='./.git' --exclude='./.env' -cf - . | tar -C "${W}/repo" -xf -
cd "${W}/repo" || exit 1
SRC="${W}/repo/deploy.sh"

mkenv() { # mkenv user chpass gfpass ip [vendors]
  printf 'CLICKHOUSE_USER=%s\nCLICKHOUSE_PASSWORD=%s\nGRAFANA_ADMIN_PASSWORD=%s\nCOLLECTOR_IP=%s\nVENDORS=%s\n' "$1" "$2" "$3" "$4" "${5:-}" > "${W}/repo/.env"
}
run() { ( source "${SRC}"; "$@" ); }

echo "== is_ipv4 =="
for ip in 10.1.2.3 192.168.0.1 255.255.255.255; do t "hợp lệ $ip" run is_ipv4 "$ip"; done
for ip in 256.1.1.1 1.2.3 1.2.3.4.5 abc 1.2.3.x ""; do nt "sai '$ip'" run is_ipv4 "$ip"; done

echo "== check_repo_layout =="
t  "repo đầy đủ" run check_repo_layout
mv grafana/dashboards/dashboard-bang-thong.json "${W}/x.json"
nt "thiếu dashboard -> dừng" run check_repo_layout
mv "${W}/x.json" grafana/dashboards/dashboard-bang-thong.json

echo "== validate_env =="
rm -f .env
nt "chưa có .env -> tạo từ mẫu rồi dừng" run validate_env
t  ".env được tạo với quyền 600" test "$(stat -c %a .env)" = "600"
mkenv panos 'doi-mat-khau-nay' 'GoodPass12345' 10.1.1.5;   nt "mật khẩu mẫu bị từ chối" run validate_env
mkenv panos 'Short1' 'GoodPass12345' 10.1.1.5;             nt "mật khẩu ngắn bị từ chối" run validate_env
mkenv panos 'Bad$Pass12345x' 'GoodPass12345' 10.1.1.5;     nt "mật khẩu chứa \$ bị từ chối" run validate_env
mkenv panos 'GoodPass12345' 'GoodPass12345' '';            nt "COLLECTOR_IP trống bị từ chối" run validate_env
mkenv panos 'GoodPass12345' 'GoodPass12345' 127.0.0.1;     nt "COLLECTOR_IP 127.0.0.1 bị từ chối" run validate_env
mkenv panos 'GoodPass12345' 'GoodPass12345' 300.1.1.1;     nt "COLLECTOR_IP không hợp lệ bị từ chối" run validate_env
mkenv '1bad' 'GoodPass12345' 'GoodPass12345' 10.1.1.5;     nt "CLICKHOUSE_USER sai định dạng bị từ chối" run validate_env
mkenv panos 'GoodPass12345' 'GoodPass12345' 10.1.1.5;      t  ".env hợp lệ được chấp nhận" run validate_env
printf 'CLICKHOUSE_USER=panos\r\nCLICKHOUSE_PASSWORD="GoodPass12345"\r\nGRAFANA_ADMIN_PASSWORD=GoodPass12345\r\nCOLLECTOR_IP=10.1.1.5\r\n' > .env
t  ".env CRLF + dấu nháy vẫn đọc đúng" run validate_env

echo "== configure_vendors =="
vend() { ( source "${SRC}"; configure_vendors >/dev/null; printf '%s;' "${VENDORS_ENABLED[*]:-}"; for f in "${COMPOSE_FILES[@]}"; do printf '%s,' "${f#"${INSTALL_DIR}"/}"; done ); }
mkenv panos 'GoodPass12345' 'GoodPass12345' 10.1.1.5 ''
t  "VENDORS trống -> chỉ docker-compose.yml" bash -c "[[ \"\$($(declare -f vend); SRC='${SRC}' vend)\" == ';docker-compose.yml,' ]]"
mkenv panos 'GoodPass12345' 'GoodPass12345' 10.1.1.5 'fortigate'
t  "VENDORS=fortigate -> thêm vendors.yml + fortigate.yml" bash -c "[[ \"\$($(declare -f vend); SRC='${SRC}' vend)\" == 'fortigate;docker-compose.yml,compose/vendors.yml,compose/fortigate.yml,' ]]"
mkenv panos 'GoodPass12345' 'GoodPass12345' 10.1.1.5 ' fortigate , checkpoint ,fortigate '
t  "khoảng trắng + trùng lặp được xử lý" bash -c "[[ \"\$($(declare -f vend); SRC='${SRC}' vend)\" == 'fortigate checkpoint;docker-compose.yml,compose/vendors.yml,compose/fortigate.yml,compose/checkpoint.yml,' ]]"
mkenv panos 'GoodPass12345' 'GoodPass12345' 10.1.1.5 'fortigate,juniper'
nt "vendor không hỗ trợ bị từ chối" run configure_vendors
mkenv panos 'GoodPass12345' 'GoodPass12345' 10.1.1.5 'checkpoint'
mv vector/vendors/checkpoint.yaml "${W}/cp.yaml"
nt "thiếu file cấu hình vendor -> dừng" run configure_vendors
mv "${W}/cp.yaml" vector/vendors/checkpoint.yaml
t  "vendor_port fortigate=5515, checkpoint=5516" bash -c "source '${SRC}'; [[ \"\$(vendor_port fortigate)\$(vendor_port checkpoint)\" == '55155516' ]]"

echo "== install_cron (idempotent, giữ cron khác) =="
mkdir -p "${W}/bin"
cat > "${W}/bin/crontab" <<'CEOF'
#!/usr/bin/env bash
store="${FAKE_CRON_STORE:?}"
if [[ "${1:-}" == "-l" ]]; then [[ -s "$store" ]] && cat "$store" || { echo "no crontab" >&2; exit 1; }
else cp "$1" "$store"; fi
CEOF
chmod +x "${W}/bin/crontab"
export FAKE_CRON_STORE="${W}/cron.store" VN_LOG="${W}/vn.log" LOGROTATE_FILE="${W}/logrotate.conf"
cron_test() {
  export PATH="${W}/bin:${PATH}"
  ( source "${SRC}"; install_cron; install_cron; install_cron ) >/dev/null 2>&1 || return 1
  [[ "$(grep -cF 'update_vn_prefixes.py' "${FAKE_CRON_STORE}")" == "1" ]] || return 2
  [[ "$(grep -cF 'managed-by: netflow-clickhouse-grafana' "${FAKE_CRON_STORE}")" == "1" ]] || return 3
}
rm -f "${FAKE_CRON_STORE}"
t "3 lần từ crontab rỗng -> đúng 1 dòng" cron_test
printf '0 1 * * * /usr/bin/backup.sh\n' > "${FAKE_CRON_STORE}"
t "3 lần khi đã có cron khác -> vẫn đúng 1 dòng" cron_test
t "cron khác của người dùng được giữ" grep -qF '/usr/bin/backup.sh' "${FAKE_CRON_STORE}"
t "logrotate được ghi" grep -q 'copytruncate' "${LOGROTATE_FILE}"

echo "== apply_permissions (stub chown) =="
perm_test() {
  ( source "${SRC}"
    # shellcheck disable=SC2329  # được deploy.sh gọi gián tiếp
    chown() { echo "chown $*" >> "${W}/chown.log"; }
    mkdir -p clickhouse/data grafana/data clickhouse/user_files goflow2; : > goflow2/goflow2
    : > "${W}/chown.log"; apply_permissions
  ) >/dev/null 2>&1
  grep -q 'chown -R 101:101 .*/clickhouse/user_files' "${W}/chown.log" && grep -q 'chown -R 472:0 .*/grafana/data' "${W}/chown.log"
}
t "gán 101:101 (ClickHouse) và 472:0 (Grafana)" perm_test

echo "== refresh_vn_prefixes: fallback khi không tải được APNIC =="
# Chặn mạng bằng cách trỏ python3 vào một script luôn lỗi, để test không phụ thuộc Internet
cat > "${W}/bin/python3" <<'PEOF'
#!/usr/bin/env bash
exit 1
PEOF
chmod +x "${W}/bin/python3"
rm -f clickhouse/user_files/vn_prefixes.csv
fb() { export PATH="${W}/bin:${PATH}"; ( source "${SRC}"; refresh_vn_prefixes ); }
nt "không có CSV cũ + APNIC lỗi -> dừng" fb
printf 'prefix,label\r\n10.0.0.0/8,Nội bộ\r\n' > clickhouse/user_files/vn_prefixes.csv
t  "có CSV cũ + APNIC lỗi -> giữ CSV cũ, không dừng" fb

if [[ "${RUN_NETWORK_TESTS:-0}" == "1" ]]; then
  echo "== GoFlow2: tải thật + SHA256 (RUN_NETWORK_TESTS=1) =="
  mkenv panos 'GoodPass12345' 'GoodPass12345' 10.1.1.5 ''
  rm -f goflow2/goflow2 goflow2/.version
  t  "tải GoFlow2 v2.2.7" bash -c "source '${SRC}'; install_goflow2 && [[ -x goflow2/goflow2 ]] && [[ \"\$(cat goflow2/.version)\" == 2.2.7-* ]]"
  t  "chạy lại thì bỏ qua tải" bash -c "source '${SRC}'; install_goflow2 | grep -q 'bỏ qua'"
  REAL="$(sha256sum goflow2/goflow2 | cut -d' ' -f1)"
  rm -f goflow2/goflow2 goflow2/.version
  echo 'GOFLOW2_SHA256=0000000000000000000000000000000000000000000000000000000000000000' >> .env
  nt "SHA256 sai bị từ chối" bash -c "source '${SRC}'; install_goflow2"
  rm -f goflow2/goflow2 goflow2/.version
  grep -v '^GOFLOW2_SHA256=' .env > .env.tmp && mv .env.tmp .env && echo "GOFLOW2_SHA256=${REAL}" >> .env
  t  "SHA256 đúng được chấp nhận" bash -c "source '${SRC}'; install_goflow2"
fi

echo; echo "KẾT QUẢ: ${PASS} PASS, ${FAIL} FAIL"
[[ ${FAIL} -eq 0 ]]
