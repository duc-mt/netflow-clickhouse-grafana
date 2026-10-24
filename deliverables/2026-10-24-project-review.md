# Đánh giá Dự án panos-grafana (Project Review)

**Ngày thực hiện:** 2026-10-24  
**Phạm vi:** Toàn bộ kiến trúc hệ thống, mã nguồn pipeline Vector (VRL), ClickHouse schema & SQL queries, script tự động hóa [deploy.sh](file:///home/nms-net/panos-grafana/deploy.sh), Python tools và bộ test suite.

---

## 1. Tổng quan Kiến trúc & Điểm mạnh

Dự án triển khai giải pháp giám sát lưu lượng firewall tập trung (**Palo Alto**, **FortiGate**, **Check Point**, và NetFlow/IPFIX chung):
```
Firewall (Syslog / NetFlow UDP) 
   ──► Vector (+ GoFlow2 sidecar) 
   ──► ClickHouse (MergeTree / SummingMergeTree) 
   ──► Grafana (ClickHouse Plugin + Sankey Panel)
```

### Điểm sáng kỹ thuật (High Marks):
1. **Phân tách trách nhiệm rõ ràng (Separation of Concerns)**:
   - Pipeline cấu hình modular (`compose/vendors.yml`, `vector/vendors/*.yaml`), giữ nguyên core [docker-compose.yml](file:///home/nms-net/panos-grafana/docker-compose.yml) và [vector/vector.yaml](file:///home/nms-net/panos-grafana/vector/vector.yaml).
2. **Cơ chế Test tự động rất ấn tượng**:
   - Bộ VRL tests ([tests/run_vector_tests.sh](file:///home/nms-net/panos-grafana/tests/run_vector_tests.sh)) đạt **16/16 test suites pass** cho cả 3 vendor.
   - Deploy harness test ([tests/test_deploy.sh](file:///home/nms-net/panos-grafana/tests/test_deploy.sh)) đạt **35/35 test cases pass** kiểm tra tính idempotent, validation IP/mật khẩu, quyền thư mục và logrotate.
3. **Hiệu năng lưu trữ & xử lý ClickHouse**:
   - Tận dụng `IP_TRIE` dictionary cho phân loại dải IP Việt Nam (`panos.vn_prefix`).
   - Sử dụng `MATERIALIZED` column và `LowCardinality(String)` tối ưu hóa kích thước bảng và tốc độ nén dữ liệu.
   - Áp dụng `SummingMergeTree` cho `panos.traffic_hourly` giúp tối ưu hóa truy vấn dài hạn mà không tốn dung lượng.
4. **An toàn mạng (Network Isolation)**:
   - ClickHouse không publish port 8123 / 9000 ra ngoài host; toàn bộ giao tiếp nằm trong Docker network nội bộ.

---

## 2. Các điểm cần lưu ý & Khuyến nghị (Actionable Findings)

### ⚠️ [SHOULD FIX] Giới hạn tài nguyên bộ nhớ cho GoFlow2 & Vector Buffering
- **Hiện trạng:**
  - `vector` service trong [docker-compose.yml](file:///home/nms-net/panos-grafana/docker-compose.yml) chạy GoFlow2 qua `type: exec` streaming từ stdout.
  - Khi lưu lượng NetFlow tăng đột biến (> 20.000 - 50.000 pkts/giây), GoFlow2 và Vector có thể tiêu tốn nhiều RAM. Hiện chưa cấu hình `deploy.resources.limits` cho container `vector` hoặc `clickhouse`.
- **Khuyến nghị:**
  - Bổ sung `mem_limit` hoặc `limits.memory` trong `docker-compose.yml` để tránh hiện tượng Linux OOM Killer tắt mất dịch vụ database hoặc collector khi burst traffic.

### ⚠️ [SHOULD FIX] Tải & Cập nhật Atomic cho APNIC Prefix (`update_vn_prefixes.py`)
- **Hiện trạng:**
  - Trong [scripts/update_vn_prefixes.py](file:///home/nms-net/panos-grafana/scripts/update_vn_prefixes.py), script ghi trực tiếp vào đường dẫn đích mà ClickHouse đọc qua DICTIONARY.
- **Khuyến nghị:**
  - Đảm bảo script python ghi ra file tạm (`.tmp`) rồi thực hiện `os.replace` để bảo đảm tính Atomic, tránh trường hợp ClickHouse reload dictionary trúng lúc file đang được ghi dở.

### 💡 [OPTIMIZATION] Khóa Index và Partitioning cho bảng `flows`
- **Hiện trạng:**
  - Bảng `panos.flows` ([clickhouse/init/02_netflow.sql](file:///home/nms-net/panos-grafana/clickhouse/init/02_netflow.sql#L43-L44)) phân vùng theo ngày: `PARTITION BY toYYYYMMDD(ts)` và `ORDER BY (ts, local_ip)`.
- **Nhận xét:**
  - Nếu hệ thống có lưu lượng lớn từ nhiều exporter, truy vấn theo khoảng thời gian (`ts`) và lọc theo `app` hoặc `remote_ip` có thể phải scan nhiều data part nếu không được bổ sung Secondary Index (Data Skipping Index) như `INDEX idx_remote_ip remote_ip TYPE bloom_filter GRANULARITY 4`.

---

## 3. Tổng kết Đánh giá

| Tiêu chí | Điểm đánh giá | Nhận xét |
| :--- | :---: | :--- |
| **Tính đúng đắn (Correctness)** | **9.5/10** | Pipeline VRL và GoFlow mapping hoạt động trơn tru, đầy đủ case test biên. |
| **Bảo mật (Security)** | **9.0/10** | Không để lộ secret ra git, cô lập port ClickHouse, kiểm tra umask và quyền file nghiêm ngặt. |
| **Độ tin cậy & Vận hành (DevOps)** | **9.5/10** | Script cài đặt `deploy.sh` hỗ trợ idempotent, quản lý logrotate, cron update và healthcheck tiêu chuẩn. |
| **Tài liệu (Documentation)** | **10/10** | [README.md](file:///home/nms-net/panos-grafana/README.md) cực kỳ chi tiết, hướng dẫn cụ thể từng vendor và quy trình xử lý sự cố. |
