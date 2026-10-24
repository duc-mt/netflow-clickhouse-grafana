# netflow-clickhouse-grafana

Giám sát băng thông firewall (Syslog + NetFlow/IPFIX): **Firewall → Vector/GoFlow2 → ClickHouse → Grafana**.
Hỗ trợ **Palo Alto** (đầy đủ), **FortiGate** (Syslog + NetFlow), **Check Point** (Syslog, *BETA*) và **pfSense** / hãng khác (NetFlow/IPFIX).
Triển khai bằng Docker Compose trên Ubuntu, một lệnh `sudo ./deploy.sh`.

## 1. Tổng quan kiến trúc

```text
Palo Alto  --Syslog UDP/5514-->  [vector] --HTTP 8123--> [clickhouse] <--native 9000-- [grafana :3000]
FortiGate  --Syslog UDP/5515-->  [vector]                      ^
Check Point--Syslog UDP/5516-->  [vector]   (5515/5516 chỉ mở khi bật VENDORS trong .env)
Mọi hãng   --NetFlow/IPFIX UDP/2055--> [vector -> goflow2] ----+
                                        cron 03:15 -> update_vn_prefixes.py -> vn_prefixes.csv (APNIC)
```

| Nguồn dữ liệu | Bảng ClickHouse | TTL | Dùng cho |
| --- | --- | --- | --- |
| Traffic Log (syslog, chỉ `subtype=end`) | `panos.traffic` | 90 ngày | Báo cáo theo phiên, Sankey, top user/app |
| Tổng hợp theo giờ (Materialized View) | `panos.traffic_hourly` | 2 năm | Báo cáo dài hạn |
| NetFlow v5/v9/IPFIX từ mọi hãng (Palo Alto thêm App-ID/User-ID qua trường 56701/56702) | `panos.flows` | 14 ngày | Băng thông gần thời gian thực |

Phân loại hướng: `Nội bộ` (RFC1918 + CGNAT), `Trong nước` (dải IPv4 APNIC cấp cho VN + `scripts/overrides.csv`), `Quốc tế` (còn lại).

| Port | Giao thức | Hướng | Tiến trình | Publish ra host |
| --- | --- | --- | --- | --- |
| 5514 | UDP | Palo Alto → host | vector (socket) | Có |
| 2055 | UDP | Mọi firewall → host | vector → goflow2 (NetFlow v5/v9/IPFIX) | Có |
| 5515 | UDP | FortiGate → host | vector (socket) | Chỉ khi `VENDORS` có `fortigate` |
| 5516 | UDP | Check Point → host | vector (socket) | Chỉ khi `VENDORS` có `checkpoint` |
| 3000 | TCP | Admin → host | grafana | Có |
| 8123, 9000 | TCP | nội bộ Docker | clickhouse | Không |

Cấu trúc repo:

```text
netflow-clickhouse-grafana/
├── deploy.sh                      # Bootstrap Ubuntu mới (idempotent)
├── docker-compose.yml             # clickhouse + vector + grafana (đã ghim version)
├── compose/                       # Mảnh compose bật theo VENDORS: vendors.yml, fortigate.yml, checkpoint.yml
├── .env.example                   # Mẫu biến môi trường; .env thật KHÔNG đưa vào Git
├── paloalto/custom_log_format_traffic.txt
├── goflow2/mapping.yaml           # Binary goflow2 do deploy.sh tải về (bị .gitignore)
├── vector/vector.yaml             # Pipeline gốc Palo Alto + NetFlow (KHÔNG sửa khi thêm hãng)
├── vector/vendors/                # fortigate.yaml, checkpoint.yaml (nạp thêm qua VECTOR_CONFIG)
├── vector/tests/                  # Kiểm thử đơn vị VRL (panos, fortigate, checkpoint)
├── scripts/update_vn_prefixes.py  # + overrides.csv
├── clickhouse/init/               # 01_schema.sql, 02_netflow.sql (tự chạy lần đầu)
├── clickhouse/migrations/         # 03 (chạy tay, server cũ), 04_add_vendor_columns.sql (deploy.sh tự áp khi bật VENDORS)
├── tests/                         # run_vector_tests.sh, e2e/run_e2e.sh, test_deploy.sh
└── grafana/
    ├── dashboards/                # 2 dashboard JSON
    ├── provisioning/datasources/  # clickhouse.yaml
    └── provisioning/dashboards/   # dashboards.yaml (tự nạp dashboard)
```

## 2. Yêu cầu hệ thống

### 2.1 Phần cứng, hệ điều hành, mạng

| Hạng mục | Tối thiểu (lab/POC) | Khuyến nghị (production) |
| --- | --- | --- |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8–16 GB |
| Ổ đĩa `/opt` | 50 GB SSD | 200 GB+ SSD/NVMe |
| Mạng | 1 NIC, tới được Palo Alto | 1 NIC, IP tĩnh |
| OS | Ubuntu Server 22.04 / 24.04 LTS, x86_64 | (arm64: script có tải binary arm64 nhưng chưa kiểm chứng) |

Các con số trên là ước lượng khởi điểm. Đo thực tế sau 24 giờ bằng truy vấn dung lượng ở mục 5 (TC-12), rồi chỉnh TTL hoặc dung lượng ổ đĩa.

Kết nối **ra ngoài** (outbound) mà máy chủ cần:

| Đích | Mục đích |
| --- | --- |
| `download.docker.com`, `registry-1.docker.io` (Docker Hub) | Cài Docker, pull image |
| `github.com` (+ `release-assets.githubusercontent.com`) | Tải GoFlow2 v2.2.7 |
| `ftp.apnic.net:443` | Danh sách IP Việt Nam (cron 03:15 hằng đêm) |
| `grafana.com` | Cài plugin ClickHouse + Sankey khi container Grafana khởi động |

### 2.2 Ports cần mở (UFW)

```bash
sudo ufw allow from <ADMIN_CIDR>   to any port 22   proto tcp
sudo ufw allow from <PANOS_IP>     to any port 5514 proto udp
sudo ufw allow from <FW_IP>        to any port 2055 proto udp   # mỗi firewall gửi NetFlow/IPFIX: lặp lại theo từng IP
sudo ufw allow from <FORTIGATE_IP> to any port 5515 proto udp   # chỉ khi VENDORS có fortigate
sudo ufw allow from <CHECKPOINT_LOG_SERVER_IP> to any port 5516 proto udp   # chỉ khi VENDORS có checkpoint
sudo ufw allow from <ADMIN_CIDR>   to any port 3000 proto tcp
sudo ufw enable            # chỉ chạy sau khi chắc chắn đã cho phép SSH
sudo ufw status numbered
```

> **Cảnh báo:** cổng do Docker publish đi qua chuỗi `FORWARD`, **không** bị UFW (chuỗi `INPUT`) chặn. Các rule UFW ở trên chưa đủ để giới hạn 5514/5515/5516/2055/3000. Thêm rule vào chuỗi `DOCKER-USER`. Vì có nhiều firewall nguồn, chặn tất cả trước rồi chèn thêm các rule cho phép (chèn sau thì được xét trước):

```bash
sudo iptables -I DOCKER-USER -p udp -m multiport --dports 5514,5515,5516,2055 -j DROP
sudo iptables -I DOCKER-USER -p udp -m multiport --dports 5514,5515,5516,2055 -s <FW_IP_1> -j RETURN
sudo iptables -I DOCKER-USER -p udp -m multiport --dports 5514,5515,5516,2055 -s <FW_IP_2> -j RETURN   # lặp lại cho từng firewall
sudo iptables -I DOCKER-USER -p tcp --dport 3000 -j DROP
sudo iptables -I DOCKER-USER -p tcp --dport 3000 -s <ADMIN_CIDR> -j RETURN
sudo apt-get install -y iptables-persistent && sudo netfilter-persistent save   # giữ rule sau khi reboot
```

Kiểm tra lại bằng cách thử gửi từ một máy **không** nằm trong danh sách cho phép. Nên đặt Grafana sau reverse proxy HTTPS khi đưa vào vận hành.

## 3. Quick Start

```bash
sudo apt-get update && sudo apt-get install -y git
sudo git clone <GIT_URL> /opt/netflow-clickhouse-grafana
cd /opt/netflow-clickhouse-grafana
sudo cp .env.example .env
sudo nano .env            # điền CLICKHOUSE_PASSWORD, GRAFANA_ADMIN_PASSWORD, COLLECTOR_IP
sudo ./deploy.sh
```

`deploy.sh` thực hiện theo thứ tự (chạy lại bao nhiêu lần cũng được):

| # | Bước | Ghi chú |
| --- | --- | --- |
| 1 | Kiểm tra root, OS, đủ file trong repo | Dừng nếu thiếu |
| 2 | Kiểm tra `.env` | Nếu chưa có thì tạo từ mẫu rồi dừng để bạn điền; từ chối mật khẩu mẫu/yếu |
| 3 | Cài gói còn thiếu và Docker Engine + Compose plugin | Từ kho apt chính thức của Docker |
| 4 | Tải GoFlow2 v2.2.7 | Tùy chọn xác minh SHA256 qua `GOFLOW2_SHA256` (giá trị cho amd64 có sẵn trong `.env.example`) |
| 5 | Chạy `update_vn_prefixes.py` | Tạo `clickhouse/user_files/vn_prefixes.csv` |
| 6 | Gán quyền | ClickHouse `101:101`, Grafana `472:0` |
| 7 | `docker compose config -q` → `pull` → `up -d` | Init SQL tự chạy lần đầu |
| 8 | Cài crontab 03:15 + logrotate | Idempotent, đúng 1 dòng |
| 9 | Healthcheck | Container, dictionary, bảng, goflow2, Grafana API |

**Hãng khác Palo Alto:** thêm vào `.env` dòng `VENDORS=fortigate` (hoặc `fortigate,checkpoint`) rồi chạy lại `./deploy.sh`. `deploy.sh` sẽ mở cổng UDP tương ứng, nạp parser của hãng, và thêm cột `vendor`, `device` vào `panos.traffic` (migration 04, idempotent). NetFlow/IPFIX từ mọi hãng (FortiGate, pfSense, Cisco, MikroTik...) vào thẳng UDP/2055, **không** cần khai báo trong `VENDORS`. Chi tiết cấu hình từng hãng ở mục 4.

Đăng nhập Grafana: `http://<COLLECTOR_IP>:3000`, user `admin`, mật khẩu là `GRAFANA_ADMIN_PASSWORD`. Mật khẩu này chỉ có tác dụng ở lần khởi tạo đầu tiên của `grafana/data`. Hai dashboard nằm trong thư mục **Palo Alto Networks**.

Nếu repo được giải nén/copy từ Windows và mất quyền thực thi: `chmod +x deploy.sh scripts/update_vn_prefixes.py`.

## 4. Cấu hình trên firewall

Mức hỗ trợ theo hãng và dashboard nào có dữ liệu:

| Hãng | Cách gửi | Cổng | Nửa trên dashboard (NetFlow: băng thông, top máy) | Nửa dưới (Traffic Log: Sankey, top app/user, theo ngày) | Ứng dụng / người dùng |
| --- | --- | --- | --- | --- | --- |
| Palo Alto | Syslog + NetFlow | 5514 + 2055 | Có | Có | App-ID + User-ID |
| FortiGate | Syslog + NetFlow (nên bật cả hai) | 5515 + 2055 | Có (không có app/user) | Có | `app`, `user` từ log |
| Check Point *(BETA)* | Syslog (Log Exporter) | 5516 | Chỉ khi thiết bị cũng xuất NetFlow | Có, nếu rule bật Accounting | `appi_name`, `src_user_name` |
| pfSense | NetFlow qua softflowd | 2055 | Có (không có app/user) | **Không** (xem 4.4) | Không |
| Hãng khác (Cisco, MikroTik, Juniper...) | NetFlow v5/v9/IPFIX | 2055 | Có (không có app/user) | Không | Không |

Dữ liệu mọi hãng nằm chung trong `panos.traffic` / `panos.flows` nên các panel hiện tổng hợp tất cả firewall; dùng ô **Lọc máy** để xem riêng một máy. Cột `vendor`/`device` (traffic) và `exporter` (flows) cho biết dữ liệu đến từ thiết bị nào.

### 4.1 Palo Alto

Thay `<COLLECTOR_IP>` bằng giá trị `COLLECTOR_IP` trong `.env`. Các lệnh dưới đây ở dạng `set`. Nếu PAN-OS báo sai cú pháp, đối chiếu bằng `?`/Tab hoặc cấu hình qua GUI.

```text
set cli config-output-format set
configure

# 1) Syslog Server Profile: UDP/5514, Custom Log Format (JSON)
set shared log-settings syslog grafana-syslog format escaping escaped-characters '"\'
set shared log-settings syslog grafana-syslog format escaping escape-character \
set shared log-settings syslog grafana-syslog format traffic '{"rtime":"$receive_time","src":"$src","dst":"$dst","src_user":"$srcuser","app":"$app","category":"$category","rule":"$rule","from_zone":"$from","to_zone":"$to","dst_country":"$dstloc","dport":$dport,"bytes_sent":$bytes_sent,"bytes_received":$bytes_received,"elapsed":$elapsed,"subtype":"$subtype"}'
set shared log-settings syslog grafana-syslog server grafana-syslog transport UDP
set shared log-settings syslog grafana-syslog server grafana-syslog port 5514
set shared log-settings syslog grafana-syslog server grafana-syslog format BSD
set shared log-settings syslog grafana-syslog server grafana-syslog server <COLLECTOR_IP>
set shared log-settings syslog grafana-syslog server grafana-syslog facility LOG_USER

# 2) NetFlow Server Profile: UDP/2055, bật Enterprise Fields (App-ID 56701 / User-ID 56702)
set shared server-profile netflow grafana-netflow server grafana host <COLLECTOR_IP>
set shared server-profile netflow grafana-netflow server grafana port 2055
set shared server-profile netflow grafana-netflow template-refresh-rate minutes 1
set shared server-profile netflow grafana-netflow template-refresh-rate packets 20
set shared server-profile netflow grafana-netflow active-timeout 1
set shared server-profile netflow grafana-netflow export-enterprise-fields yes

# 3) Gắn NetFlow vào từng interface Layer 3 / tunnel cần giám sát (lặp lại cho mỗi interface)
set network interface ethernet ethernet1/2 layer3 netflow-profile grafana-netflow
set network interface tunnel units tunnel.1 netflow-profile grafana-netflow

# 4) Log Forwarding Profile: đẩy Traffic Log sang Syslog Profile (bỏ qua nếu đã có)
set shared log-settings profiles grafana-logfwd match-list traffic-all log-type traffic
set shared log-settings profiles grafana-logfwd match-list traffic-all filter "All Logs"
set shared log-settings profiles grafana-logfwd match-list traffic-all send-syslog grafana-syslog
set rulebase security rules <TEN_RULE> log-setting grafana-logfwd
set rulebase security rules <TEN_RULE> log-end yes

commit
```

- Chuỗi Custom Log Format giống hệt `paloalto/custom_log_format_traffic.txt`.
- Vector chỉ giữ log `subtype=end`, nên không cần bật log ở đầu phiên.
- Nếu collector đi qua data plane, kiểm tra **Device > Setup > Services > Service Route Configuration** cho Syslog và NetFlow.
- Đối chiếu cấu hình gốc trên firewall đang chạy bằng `show shared log-settings syslog` và `show shared server-profile netflow`.

### 4.2 FortiGate (FortiOS)

Bật `VENDORS=fortigate` trong `.env` rồi chạy lại `./deploy.sh`. Khuyến nghị gửi **cả Syslog lẫn NetFlow** để có đủ cả hai nửa dashboard.

```text
# 1) Syslog: Traffic Log tới UDP/5515, định dạng mặc định (key=value)
config log syslogd setting
    set status enable
    set server "<COLLECTOR_IP>"
    set mode udp
    set port 5515
    set format default
end
config log syslogd filter
    set severity information
    set forward-traffic enable
    set local-traffic disable
end

# 2) Ghi log cuối phiên cho từng policy cần giám sát
config firewall policy
    edit <POLICY_ID>
        set logtraffic all
    next
end

# 3) NetFlow: băng thông gần thời gian thực (UDP/2055)
config system netflow
    set collector-ip "<COLLECTOR_IP>"
    set collector-port 2055
    set active-flow-timeout 60
    set inactive-flow-timeout 15
    set template-tx-timeout 60
    set template-tx-counter 20
end
config system interface
    edit "<LAN_INTERFACE>"
        set netflow-sampler both
    next
end
```

- Chỉ log **kết thúc phiên** của lưu lượng đi qua firewall được ghi: `type=traffic`, `subtype=forward`, `action` là `close`, `timeout`, `client-rst` hoặc `server-rst`. Các log `start`, `deny`, `accept` và lưu lượng local bị bỏ.
- Thời gian lấy từ `date`/`time`/`tz` trong log; nếu thiếu `tz` thì coi là giờ Việt Nam. `srcintf`/`dstintf` được ghi vào `from_zone`/`to_zone`.
- `dst` là IP đích **trước DNAT**: phiên đi vào (VIP) có hướng `Nội bộ` và không tính vào biểu đồ quốc tế/trong nước, giống cách Palo Alto đang hoạt động.
- NetFlow: bật `netflow-sampler both` trên interface phía **LAN** và **không** bật thêm ở WAN (tránh đếm đôi); không bật sampling để số byte là số thật. Phía LAN thấy IP nội bộ thật nên cột `local_ip` đúng cả hai chiều.
- Ánh xạ trường dựa trên tài liệu FortiOS Log Message Reference; nên chạy TC-15 để xác nhận trên phiên bản FortiOS của bạn.

### 4.3 Check Point (BETA)

> **Chưa kiểm chứng với log Check Point thật.** Parser dựa trên tài liệu Log Exporter; các test đơn vị dùng log tổng hợp. Hãy làm đủ các bước xác nhận bên dưới trước khi tin số liệu. Nếu gửi cho tôi vài dòng log thật (đã che IP), parser có thể được chốt lại cho chính xác.

Bật `VENDORS=checkpoint` trong `.env` rồi chạy lại `./deploy.sh`. Log Exporter chạy trên **Management/Log Server**:

```text
cp_log_export add name netflow-clickhouse-grafana target-server <COLLECTOR_IP> target-port 5516 protocol udp format syslog read-mode semi-unified
cp_log_export restart name netflow-clickhouse-grafana
cp_log_export show
```

(Đối chiếu cú pháp bằng `cp_log_export add --help` trên phiên bản của bạn.) Trong SmartConsole, ở cột **Track** của rule cần giám sát chọn **Log + Accounting**, rồi *Install Policy*. Không có Accounting thì Check Point không ghi số byte và log bị bỏ vì không đo được lưu lượng.

Xác nhận trước khi tin dữ liệu:

```bash
# 1) Thu vài dòng log thật ngay trên collector
sudo tcpdump -ni any -A -c 5 'udp port 5516'
# 2) Kiểm tra có đủ các trường: action, src, dst, service, loguid, và (sent_bytes + received_bytes)
#    hoặc (client_outbound_bytes + client_inbound_bytes) hoặc bytes
# 3) Dán dòng thật vào vector/tests/checkpoint.test.yaml thành một test mới, rồi chạy
./tests/run_vector_tests.sh
```

Giới hạn đã biết:

- Check Point có thể xuất nhiều bản ghi cho cùng một kết nối (bản đầu rồi các bản cập nhật có số byte lũy kế). Parser gộp theo `loguid` bằng transform `reduce`, lấy số byte lớn nhất, và chỉ phát ra khi `loguid` im lặng quá `expire_after_ms` (mặc định 60 giây, sửa trong `vector/vendors/checkpoint.yaml`). Dữ liệu vì vậy trễ khoảng đó, và kết nối dài có bản cập nhật thưa hơn khoảng này có thể bị đếm hai lần.
- Cách chia `bytes_sent`/`bytes_received` có thể không khớp hướng thực tế. Các panel hiện có chỉ cộng hai cột này nên tổng không bị ảnh hưởng.

### 4.4 pfSense

pfSense chỉ gửi được **NetFlow** hữu ích. Log `filterlog` ghi từng gói được cho phép/chặn chứ không có tổng byte theo phiên, nên không dùng cho báo cáo băng thông.

1. Cài gói **softflowd**: *System > Package Manager > Available Packages*.
2. *Services > softflowd*: bật dịch vụ, chọn interface **LAN** (phía nội bộ), Host = `<COLLECTOR_IP>`, Port = `2055`, NetFlow Version = `9` (hoặc `10`/IPFIX; `5` cũng được GoFlow2 giải mã), không bật sampling. Tên trường có thể khác đôi chút theo phiên bản gói.
3. Mỗi interface LAN cần giám sát dùng một instance softflowd.

Chỉ chọn interface **LAN**: ở WAN, IP đã bị NAT nên cột `local_ip` sẽ ghi IP công cộng thay vì máy nội bộ. Kết quả là nửa trên dashboard (băng thông, top máy) có dữ liệu, còn nửa dưới (Traffic Log) không có.

### 4.5 Hãng khác (Cisco, MikroTik, Juniper...)

Bất kỳ thiết bị nào xuất **NetFlow v5/v9 hoặc IPFIX** đều chỉ cần trỏ collector tới `<COLLECTOR_IP>:2055`; không phải sửa cấu hình pipeline. Dữ liệu vào `panos.flows` với `exporter` là IP thiết bị. `app`, `user` và các trường NAT sẽ rỗng nếu thiết bị không gửi trường tương ứng. Nếu thiết bị chỉ xuất NetFlow ở phía có NAT, hãy chuyển sang interface phía nội bộ như 4.4. Hỗ trợ Syslog cho hãng khác cần thêm một parser mới trong `vector/vendors/` (sao chép `fortigate.yaml` làm mẫu), thêm một file `compose/<hãng>.yml` và tên hãng vào `KNOWN_VENDORS` của `deploy.sh`.

## 5. Kịch bản kiểm thử (Verification)

Chạy trong `/opt/netflow-clickhouse-grafana`. Khai báo hàm hỗ trợ một lần:

```bash
cd /opt/netflow-clickhouse-grafana
chq() { docker compose exec -T clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --query "$1"' _ "$1"; }
COLLECTOR_IP="$(grep -E '^COLLECTOR_IP=' .env | cut -d= -f2)"
```

| TC | Tầng | Kiểm tra | Kết quả mong đợi |
| --- | --- | --- | --- |
| TC-01 | L3 | IP collector gắn trên NIC | Có dòng chứa `COLLECTOR_IP` |
| TC-02 | L3/L4 | UFW + `DOCKER-USER` | Chỉ IP Palo Alto vào 5514/2055 |
| TC-03 | L4 | `ss` thấy UDP 5514 và 2055 | 2 dòng `UNCONN` |
| TC-04 | L4 | `tcpdump` thấy Syslog từ Palo Alto | Có gói UDP/5514 |
| TC-05 | L4 | `tcpdump` thấy NetFlow | Có gói UDP/2055 trong ≤ 90 giây |
| TC-06 | L7 | `docker compose ps` | `clickhouse` healthy, `vector`/`grafana` running |
| TC-07 | L7 | Tiến trình goflow2 | Thấy `/opt/goflow2/goflow2` |
| TC-08 | L7 | Log Vector | Không có ERROR lặp lại |
| TC-09 | L7 | Dictionary | `10.1.1.1` → `Nội bộ`, `8.8.8.8` → `Quốc tế`, `element_count` > 100 |
| TC-10 | L7 | Đủ bảng | 4 đối tượng trong `panos` |
| TC-11 | L7 | Chèn log giả end-to-end | 1 dòng `app='selftest'`, `direction='Quốc tế'` |
| TC-12 | L7 | Dữ liệu thật 5 phút gần nhất | `flows` và `traffic` có dòng; `app` đọc được |
| TC-13 | L7 | Grafana | `/api/health` OK, 2 dashboard, datasource OK |
| TC-14 | Ops | Crontab idempotent | Chạy `deploy.sh` 2 lần vẫn đúng 1 dòng |
| TC-15 | L7 | FortiGate: chèn log giả end-to-end (cổng 5515) | 1 dòng `vendor='fortigate'`, `direction='Quốc tế'` |
| TC-16 | L7 | NetFlow từ nhiều firewall | Mỗi firewall xuất hiện một dòng theo `exporter` |
| TC-17 | L7 | Check Point (BETA): log thật khớp parser | Có `action`, `src`, `dst`, trường byte; kết quả trong `panos.traffic` hợp lý |
| TC-18 | L7 | Cột nhận biết hãng | `vendor`/`device` tồn tại và được điền |

```bash
# --- Layer 3/4 ---
ip -4 -o addr show | grep "${COLLECTOR_IP}"                                   # TC-01
sudo ufw status numbered; sudo iptables -S DOCKER-USER                        # TC-02
sudo ss -lunp | grep -E ':(5514|2055)\b'                                      # TC-03
sudo timeout 60 tcpdump -ni any -c 5 'udp port 5514'                          # TC-04
sudo timeout 90 tcpdump -ni any -c 5 'udp port 2055'                          # TC-05

# --- Layer 7 ---
docker compose ps                                                             # TC-06
docker compose top vector | grep goflow2                                      # TC-07
docker compose logs --tail=100 vector                                         # TC-08

chq "SYSTEM RELOAD DICTIONARY panos.vn_prefix"                                # TC-09
chq "SELECT dictGetOrDefault('panos.vn_prefix','label',tuple(toIPv4('10.1.1.1')),'MISS') AS private_ip, dictGetOrDefault('panos.vn_prefix','label',tuple(toIPv4('8.8.8.8')),'MISS') AS public_ip FORMAT Vertical"
chq "SELECT element_count FROM system.dictionaries WHERE database='panos' AND name='vn_prefix'"

chq "SELECT name FROM system.tables WHERE database='panos' ORDER BY name"     # TC-10

# TC-11: chèn 1 bản ghi Syslog giả rồi dọn
NOW="$(TZ=Asia/Ho_Chi_Minh date '+%Y/%m/%d %H:%M:%S')"
echo "<14>${NOW} test panos: {\"rtime\":\"${NOW}\",\"src\":\"10.99.99.99\",\"dst\":\"8.8.8.8\",\"src_user\":\"selftest\",\"app\":\"selftest\",\"category\":\"any\",\"rule\":\"selftest\",\"from_zone\":\"lan\",\"to_zone\":\"wan\",\"dst_country\":\"US\",\"dport\":443,\"bytes_sent\":100,\"bytes_received\":200,\"elapsed\":1,\"subtype\":\"end\"}" > "/dev/udp/${COLLECTOR_IP}/5514"
sleep 8     # batch timeout_secs: 5
chq "SELECT ts, src, dst, app, direction, bytes_sent, bytes_received FROM panos.traffic WHERE app='selftest' FORMAT PrettyCompact"
chq "ALTER TABLE panos.traffic DELETE WHERE app='selftest' SETTINGS mutations_sync=1"
chq "ALTER TABLE panos.traffic_hourly DELETE WHERE app='selftest' SETTINGS mutations_sync=1"

# TC-12: dữ liệu thật và dung lượng
chq "SELECT 'flows' AS tbl, count() AS rows_5m, max(ts) AS last_ts FROM panos.flows WHERE ts > now() - INTERVAL 5 MINUTE UNION ALL SELECT 'traffic', count(), max(ts) FROM panos.traffic WHERE ts > now() - INTERVAL 5 MINUTE FORMAT PrettyCompact"
chq "SELECT app, user, direction, xfer, count() AS n, formatReadableSize(sum(bytes)) AS vol FROM panos.flows WHERE ts > now() - INTERVAL 5 MINUTE GROUP BY app, user, direction, xfer ORDER BY sum(bytes) DESC LIMIT 10 FORMAT PrettyCompact"
chq "SELECT table, formatReadableSize(sum(bytes_on_disk)) AS size, sum(rows) AS rows FROM system.parts WHERE database='panos' AND active GROUP BY table FORMAT PrettyCompact"

# TC-13: Grafana (thay <GRAFANA_ADMIN_PASSWORD>)
curl -fsS http://127.0.0.1:3000/api/health
curl -fsS -u 'admin:<GRAFANA_ADMIN_PASSWORD>' 'http://127.0.0.1:3000/api/search?type=dash-db'

# TC-14
sudo ./deploy.sh && sudo ./deploy.sh && sudo crontab -l | grep -c update_vn_prefixes.py   # kết quả: 1

# TC-15: FortiGate (cần VENDORS=fortigate). Chèn 1 log close giả rồi dọn
NOW="$(TZ=Asia/Ho_Chi_Minh date '+%Y-%m-%d %H:%M:%S')"
echo "<189>date=${NOW% *} time=${NOW#* } devname=\"FGT-TEST\" tz=\"+0700\" logid=\"0000000013\" type=\"traffic\" subtype=\"forward\" srcip=10.99.99.98 srcport=40000 srcintf=\"lan\" dstip=8.8.8.8 dstport=443 dstintf=\"wan1\" action=\"close\" policyid=1 policyname=\"selftest\" app=\"selftest-fgt\" duration=1 sentbyte=100 rcvdbyte=200" > "/dev/udp/${COLLECTOR_IP}/5515"
sleep 8
chq "SELECT ts, src, dst, app, direction, vendor, device, bytes_sent, bytes_received FROM panos.traffic WHERE app='selftest-fgt' FORMAT PrettyCompact"
chq "ALTER TABLE panos.traffic DELETE WHERE app='selftest-fgt' SETTINGS mutations_sync=1"
chq "ALTER TABLE panos.traffic_hourly DELETE WHERE app='selftest-fgt' SETTINGS mutations_sync=1"

# TC-16: mỗi firewall gửi NetFlow phải xuất hiện (exporter = IP thiết bị)
chq "SELECT exporter, count() AS flows, formatReadableSize(sum(bytes)) AS vol FROM panos.flows WHERE ts > now() - INTERVAL 10 MINUTE GROUP BY exporter FORMAT PrettyCompact"

# TC-17: Check Point (BETA) - thu log thật rồi đối chiếu
sudo timeout 120 tcpdump -ni any -A -c 5 'udp port 5516'

# TC-18: cột nhận biết hãng (có sau migration 04, deploy.sh tự áp khi VENDORS không rỗng)
chq "SELECT vendor, device, count() AS sessions FROM panos.traffic WHERE ts > now() - INTERVAL 1 HOUR GROUP BY vendor, device FORMAT PrettyCompact"
```

Kiểm thử tự động (không cần Docker, tự tải Vector/GoFlow2 vào `.cache/` nếu thiếu):

```bash
./tests/run_vector_tests.sh        # 16 test đơn vị VRL: panos_parse gốc + FortiGate + Check Point
./tests/e2e/run_e2e.sh             # Vector + GoFlow2 thật, gói UDP thật (Syslog 3 hãng, NetFlow v5/v9/IPFIX) -> kiểm tra hàng INSERT
./tests/test_deploy.sh             # các hàm của deploy.sh; thêm RUN_NETWORK_TESTS=1 để test tải GoFlow2 + SHA256
```

Ghi chú TC-12: `app` phải là tên đọc được (ví dụ `ssl`, `web-browsing`) chứ không phải chuỗi hex hoặc rỗng hàng loạt. `user` có dạng `DOMAIN\user` nếu User-ID đang bật.

## 6. Xử lý sự cố (Troubleshooting)

| Triệu chứng | Nguyên nhân thường gặp | Cách xử lý |
| --- | --- | --- |
| `deploy.sh` dừng ở `.env` | Chưa điền biến, mật khẩu mẫu/yếu | Sửa `.env` theo `.env.example`, chạy lại |
| ClickHouse restart liên tục / `unhealthy` | Sai quyền `clickhouse/data` | `sudo chown -R 101:101 clickhouse/data clickhouse/user_files && docker compose up -d`; xem `docker compose logs clickhouse` |
| `unhealthy` mãi, chưa có bảng `panos.flows` | Init SQL không chạy (thư mục `data/` đã có dữ liệu từ trước) | Chạy tay: `docker compose exec -T clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery' < clickhouse/init/01_schema.sql`, rồi `02_netflow.sql` |
| Dictionary báo thiếu file / `direction` toàn `Quốc tế` | `vn_prefixes.csv` thiếu hoặc rỗng | `sudo python3 scripts/update_vn_prefixes.py`, rồi `chq "SYSTEM RELOAD DICTIONARY panos.vn_prefix"` |
| `tcpdump` không thấy gói từ Palo Alto | Sai `COLLECTOR_IP`, route/ACL, Service Route chưa đặt | Kiểm tra Service Route, ACL giữa firewall và collector, rule `DOCKER-USER` |
| Có `flows` nhưng không có `traffic` | Chưa gắn Log Forwarding Profile vào Security Rule, hoặc Custom Log Format sai | Làm lại mục 4 bước 4; chạy TC-11 để tách lỗi phía Palo Alto khỏi lỗi pipeline |
| `app`/`user` rỗng trong `flows` | Thiếu `export-enterprise-fields yes`, hoặc User-ID chưa bật | Kiểm tra NetFlow profile; xem JSON của goflow2 trong log Vector |
| Không thấy `goflow2` trong `docker compose top vector` | Binary thiếu quyền thực thi hoặc sai kiến trúc | `ls -l goflow2/goflow2`; xóa `goflow2/goflow2` và `goflow2/.version` rồi chạy lại `./deploy.sh` |
| Grafana thiếu plugin / panel Sankey không hiện | Máy chủ không ra được `grafana.com` | Mở outbound, rồi `docker compose restart grafana` |
| Đổi `GRAFANA_ADMIN_PASSWORD` nhưng không có tác dụng | `grafana/data` đã khởi tạo trước đó | `docker compose exec grafana grafana cli admin reset-admin-password '<mật_khẩu_mới>'` |
| Dashboard trùng / lỗi provisioning | Đã import tay 2 dashboard này trước đó | Xóa bản import tay trong UI rồi `docker compose restart grafana` |
| FortiGate không có dữ liệu trong `traffic` | Chưa bật `VENDORS=fortigate`; sai cổng; policy chưa `logtraffic all`; filter chưa bật `forward-traffic` | `docker compose ps` thấy cổng 5515; `tcpdump -ni any 'udp port 5515'`; chạy TC-15 |
| FortiGate có log nhưng không vào bảng | `action` không thuộc close/timeout/client-rst/server-rst, hoặc `subtype` không phải forward | Xem một dòng log thật; thêm test vào `vector/tests/fortigate.test.yaml` rồi chạy `./tests/run_vector_tests.sh` |
| Check Point không có dòng nào | Rule chưa bật Accounting (không có số byte) hoặc tên trường khác dự kiến | TC-17: thu log thật, đối chiếu trường byte; sửa `vector/vendors/checkpoint.yaml` |
| Check Point bị đếm gấp đôi | Kết nối dài cập nhật thưa hơn `expire_after_ms` | Tăng `expire_after_ms` trong `vector/vendors/checkpoint.yaml`, `docker compose restart vector` |
| pfSense/NetFlow ghi IP công cộng thay vì máy nội bộ | Export ở interface WAN (sau NAT) | Chuyển softflowd / sampler sang interface LAN (mục 4.4) |
| Bật `VENDORS` xong Vector không khởi động | Lỗi cấu hình vendor | `docker compose logs vector`; `./tests/run_vector_tests.sh` để kiểm tra cấu hình |
| Đĩa đầy | Log nhiều hơn dự kiến | Xem mục 7 (Stop-Conditions) |

## 7. Stop-Conditions & Rollback khẩn cấp

### 7.1 Stop-Conditions (gặp là dừng và xử lý)

| Điều kiện | Kiểm tra | Hành động |
| --- | --- | --- |
| `/opt` dùng ≥ 85% | `df -h /opt`; `du -sh clickhouse/data` | `docker compose stop vector`; giảm TTL hoặc mở rộng đĩa |
| CPU Palo Alto (management hoặc data plane) > 85% sau khi bật NetFlow/Syslog | `show system resources`; `show running resource-monitor` | Gỡ NetFlow khỏi bớt interface (7.3) |
| Disk buffer của Vector > 800 MB (80% của 1 GB) | `du -sh vector/data` | ClickHouse đang nghẽn/ngừng; kiểm tra `docker compose logs clickhouse`. Buffer đầy sẽ bỏ sự kiện mới |
| ClickHouse restart ≥ 3 lần trong 10 phút | `docker inspect -f '{{.RestartCount}}' $(docker compose ps -q clickhouse)` | `docker compose stop vector grafana`, điều tra log |
| Stack không healthy sau 5 phút kể từ `deploy.sh` | `docker compose ps` | Làm theo mục 6 |

### 7.2 Rollback trên Ubuntu

```bash
cd /opt/netflow-clickhouse-grafana
docker compose stop vector                 # 1. Dừng ghi dữ liệu ngay lập tức
docker compose down                        # 2. Dừng toàn bộ stack (dữ liệu bind-mount vẫn còn)

# 3. Quay về phiên bản trước: đặt *_TAG trong .env rồi
docker compose up -d
#    Tắt một hãng: bỏ tên hãng khỏi VENDORS trong .env rồi chạy lại ./deploy.sh
#    (cột vendor/device đã thêm vào panos.traffic được giữ nguyên, vô hại)

# 4. Gỡ cron + logrotate do deploy.sh cài
crontab -l | grep -vF -e 'managed-by: netflow-clickhouse-grafana' -e 'update_vn_prefixes.py' | crontab -
sudo rm -f /etc/logrotate.d/netflow-clickhouse-grafana

# 5. [HỦY DỮ LIỆU - cần sự đồng ý] xóa sạch dữ liệu
# docker compose down && sudo rm -rf clickhouse/data grafana/data vector/data
```

### 7.3 Rollback trên firewall

FortiGate: `config log syslogd setting` → `set status disable`; `config system netflow` → đặt lại `collector-ip` rỗng hoặc gỡ `netflow-sampler` khỏi interface. Check Point: `cp_log_export delete name netflow-clickhouse-grafana`. pfSense: tắt dịch vụ softflowd.

Palo Alto:

```text
configure
delete network interface ethernet ethernet1/2 layer3 netflow-profile
delete network interface tunnel units tunnel.1 netflow-profile
delete rulebase security rules <TEN_RULE> log-setting
commit
```

- Chưa commit: `revert config` để bỏ thay đổi đang chờ.
- Đã commit: nạp lại phiên bản cấu hình trước (`load config version <N>`) rồi `commit`. Xác nhận cú pháp bằng `?` trên phiên bản PAN-OS của bạn.

## 8. Vận hành

```bash
# Nâng cấp mã nguồn / cấu hình
cd /opt/netflow-clickhouse-grafana && sudo git pull --ff-only && sudo ./deploy.sh

# Backup nguội ClickHouse (dừng dịch vụ để dữ liệu nhất quán)
docker compose stop
sudo tar -czf /root/panos-data-$(date +%F).tgz clickhouse/data grafana/data
docker compose up -d

# Thêm dải IP ép nhãn: sửa scripts/overrides.csv, rồi
sudo python3 scripts/update_vn_prefixes.py
```

- Thêm/bớt hãng: sửa `VENDORS` trong `.env` rồi `sudo ./deploy.sh`. Trước khi đưa parser mới vào vận hành, chạy `./tests/run_vector_tests.sh` và `./tests/e2e/run_e2e.sh`.
- ClickHouse chỉ nâng được, không hạ được. Trước khi đổi `CLICKHOUSE_TAG`, backup dữ liệu.
- Phiên bản mặc định đã ghim trong `docker-compose.yml` (ClickHouse 26.8, Grafana 13.2.4, Vector 0.56.0-debian). Khi nâng cấp tại chỗ từ `latest`, đặt `*_TAG` trong `.env` cho khớp phiên bản đang chạy rồi mới chạy `deploy.sh`.
- `clickhouse/migrations/03_bo_microsoft365.sql` chỉ dành cho server đã cài trước khi bỏ nhãn Microsoft 365. Cách chạy ghi trong header của file. Server mới không cần.
- `grafana/dashboards/dashboard-thoi-gian-thuc.json` là bản cũ còn truy vấn nhãn `Microsoft 365` (luôn bằng 0). Có thể xóa file này nếu chỉ dùng `dashboard-bang-thong.json`.
