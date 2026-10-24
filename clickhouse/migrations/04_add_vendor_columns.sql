-- Thêm cột nhận biết log đến từ hãng/thiết bị nào vào panos.traffic (TÙY CHỌN, idempotent).
-- deploy.sh tự chạy file này khi VENDORS trong .env không rỗng. Chạy tay:
--   docker compose exec -T clickhouse sh -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" --multiquery' \
--     < clickhouse/migrations/04_add_vendor_columns.sql
--
-- Không sửa 01_schema.sql / 02_netflow.sql. Dòng cũ và log Palo Alto (panos_parse không gửi vendor)
-- nhận giá trị mặc định 'paloalto'. Nếu chưa chạy file này, Vector vẫn hoạt động bình thường vì
-- sink dùng skip_unknown_fields: trường vendor/device chỉ đơn giản bị bỏ qua.

ALTER TABLE panos.traffic ADD COLUMN IF NOT EXISTS vendor LowCardinality(String) DEFAULT 'paloalto';
ALTER TABLE panos.traffic ADD COLUMN IF NOT EXISTS device LowCardinality(String) DEFAULT '';
