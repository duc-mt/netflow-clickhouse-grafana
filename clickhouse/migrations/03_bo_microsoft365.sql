-- Bo nhan "Microsoft 365": du lieu da luu chuyen ve "Quốc tế".
-- Chay SAU KHI da chay lai scripts/update_vn_prefixes.py (khong co --m365):
--   docker compose exec -T clickhouse clickhouse-client -u panos --password '<mat khau>' \
--     --multiquery < clickhouse/migrations/03_bo_microsoft365.sql

SYSTEM RELOAD DICTIONARY panos.vn_prefix;

-- Tinh lai cot direction theo danh sach IP moi
ALTER TABLE panos.traffic MATERIALIZE COLUMN direction SETTINGS mutations_sync = 1;
ALTER TABLE panos.flows   MATERIALIZE COLUMN direction SETTINGS mutations_sync = 1;

-- Bang tong hop theo gio: chuyen so lieu Microsoft 365 sang Quoc te
INSERT INTO panos.traffic_hourly
SELECT hour, app, 'Quốc tế', src_user, bytes_sent, bytes_received, sessions
FROM panos.traffic_hourly FINAL
WHERE direction = 'Microsoft 365';

ALTER TABLE panos.traffic_hourly DELETE WHERE direction = 'Microsoft 365' SETTINGS mutations_sync = 1;

-- Kiem tra: khong con dong nao la Microsoft 365
SELECT 'traffic' AS bang, direction, count() FROM panos.traffic GROUP BY direction
UNION ALL
SELECT 'flows', direction, count() FROM panos.flows GROUP BY direction;
