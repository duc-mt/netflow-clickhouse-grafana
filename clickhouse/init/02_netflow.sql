-- Bang NetFlow (gan thoi gian thuc). Server da cai tu truoc thi chay bang tay:
--   docker compose exec -T clickhouse clickhouse-client -u panos --password '<mat khau>' --multiquery < clickhouse/init/02_netflow.sql
--
-- Moi dong = mot ban ghi NetFlow mot chieu ma Palo Alto gui moi "Active Timeout" (1 phut).
--   Chieu tai len  (vao tu cong LAN): src = may noi bo, dst = may ben ngoai
--   Chieu tai xuong (vao tu cong WAN): src = may ben ngoai, nat_dst = may noi bo (sau NAT)

CREATE TABLE IF NOT EXISTS panos.flows
(
    ts        DateTime('Asia/Ho_Chi_Minh'),
    exporter  LowCardinality(String),
    src       String,
    dst       String,
    nat_src   String,
    nat_dst   String,
    src_port  UInt16,
    dst_port  UInt16,
    proto     LowCardinality(String),
    in_if     UInt32,
    out_if    UInt32,
    flow_id   UInt64,
    fw_event  UInt8,
    app       LowCardinality(String),
    user      LowCardinality(String),
    bytes     UInt64,
    packets   UInt64,

    src_label LowCardinality(String) MATERIALIZED
        if(isIPv4String(src), dictGetOrDefault('panos.vn_prefix', 'label', tuple(toIPv4OrZero(src)), 'Quốc tế'), 'IPv6'),
    -- May noi bo cua phien
    local_ip  String MATERIALIZED
        if(src_label = 'Nội bộ', src,
           if(isIPv4String(nat_dst) AND nat_dst != '0.0.0.0', nat_dst, dst)),
    -- May ben ngoai cua phien
    remote_ip String MATERIALIZED if(src_label = 'Nội bộ', dst, src),
    direction LowCardinality(String) MATERIALIZED
        if(isIPv4String(remote_ip),
           dictGetOrDefault('panos.vn_prefix', 'label', tuple(toIPv4OrZero(remote_ip)), 'Quốc tế'),
           'IPv6'),
    xfer      LowCardinality(String) MATERIALIZED if(src_label = 'Nội bộ', 'Tải lên', 'Tải xuống')
)
ENGINE = MergeTree
PARTITION BY toYYYYMMDD(ts)
ORDER BY (ts, local_ip)
TTL ts + INTERVAL 14 DAY;
