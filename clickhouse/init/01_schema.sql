-- Chay tu dong lan dau khi container ClickHouse khoi dong (thu muc docker-entrypoint-initdb.d).
-- Co the chay lai bang tay: clickhouse-client --multiquery < 01_schema.sql

CREATE DATABASE IF NOT EXISTS panos;

-- 1. Danh sach dai IP -> nhan (Trong nuoc / Noi bo)
--    File do scripts/update_vn_prefixes.py sinh ra, ClickHouse tu doc lai moi 1 gio.
CREATE DICTIONARY IF NOT EXISTS panos.vn_prefix
(
    prefix String,
    label  String
)
PRIMARY KEY prefix
SOURCE(FILE(path '/var/lib/clickhouse/user_files/vn_prefixes.csv' format 'CSVWithNames'))
LAYOUT(IP_TRIE)
LIFETIME(MIN 3000 MAX 3600);

-- 2. Bang luu traffic log (moi dong = 1 phien ket noi da ket thuc)
CREATE TABLE IF NOT EXISTS panos.traffic
(
    ts             DateTime('Asia/Ho_Chi_Minh'),
    src            String,
    dst            String,
    src_user       LowCardinality(String),
    app            LowCardinality(String),
    category       LowCardinality(String),
    rule           LowCardinality(String),
    from_zone      LowCardinality(String),
    to_zone        LowCardinality(String),
    dst_country    LowCardinality(String),
    dport          UInt16,
    bytes_sent     UInt64,
    bytes_received UInt64,
    elapsed        UInt32,
    -- Huong di: tinh 1 lan luc ghi, theo dai IP dich
    direction LowCardinality(String) MATERIALIZED
        if(isIPv4String(dst),
           dictGetOrDefault('panos.vn_prefix', 'label', tuple(toIPv4OrZero(dst)), 'Quốc tế'),
           'IPv6')
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(ts)
ORDER BY (ts, app)
TTL ts + INTERVAL 90 DAY;

-- 3. Bang tong hop theo gio (giu 2 nam, rat nhe) - Grafana dung cho bao cao dai han
CREATE TABLE IF NOT EXISTS panos.traffic_hourly
(
    hour      DateTime('Asia/Ho_Chi_Minh'),
    app       LowCardinality(String),
    direction LowCardinality(String),
    src_user  LowCardinality(String),
    bytes_sent     UInt64,
    bytes_received UInt64,
    sessions  UInt64
)
ENGINE = SummingMergeTree
PARTITION BY toYYYYMM(hour)
ORDER BY (hour, app, direction, src_user)
TTL hour + INTERVAL 2 YEAR;

CREATE MATERIALIZED VIEW IF NOT EXISTS panos.traffic_hourly_mv TO panos.traffic_hourly AS
SELECT
    toStartOfHour(ts) AS hour,
    app,
    if(isIPv4String(dst),
       dictGetOrDefault('panos.vn_prefix', 'label', tuple(toIPv4OrZero(dst)), 'Quốc tế'),
       'IPv6') AS direction,
    src_user,
    sum(bytes_sent)     AS bytes_sent,
    sum(bytes_received) AS bytes_received,
    count()             AS sessions
FROM panos.traffic
GROUP BY hour, app, direction, src_user;
