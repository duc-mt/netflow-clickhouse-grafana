-- Cau truy van cua dashboard-bang-thong.json (1 dashboard, 9 panel).
-- $__timeFilter, $__timeInterval, $__interval_s, $__fromTime, $__toTime: macro cua plugin ClickHouse.
-- ${client}: o 'Loc may' tren dashboard.

-- Bang thong quoc te / trong nuoc (NetFlow)
SELECT
  $__timeInterval(ts) AS time,
  sumIf(bytes, direction = 'Quốc tế')    * 8 / $__interval_s AS `Quốc tế`,
  sumIf(bytes, direction = 'Trong nước') * 8 / $__interval_s AS `Trong nước`
FROM panos.flows
WHERE $__timeFilter(ts) AND ('${client}' = '' OR local_ip = '${client}')
GROUP BY time
ORDER BY time;

-- Top 10 may (NetFlow)
SELECT $__timeInterval(ts) AS time, local_ip AS client, sum(bytes) * 8 / $__interval_s AS bps
FROM panos.flows
WHERE $__timeFilter(ts) AND direction IN ('Quốc tế', 'Trong nước') AND ('${client}' = '' OR local_ip = '${client}')
  AND local_ip IN (
    SELECT local_ip FROM panos.flows
    WHERE $__timeFilter(ts) AND direction IN ('Quốc tế', 'Trong nước') AND ('${client}' = '' OR local_ip = '${client}')
    GROUP BY local_ip ORDER BY sum(bytes) DESC LIMIT 10)
GROUP BY time, client
ORDER BY time;

-- May dang dung nhieu nhat, 5 phut (NetFlow)
WITH dateDiff('second', $__fromTime, $__toTime) AS dur
SELECT
  local_ip AS `Máy`,
  anyIf(user, user != '') AS `Người dùng`,
  sumIf(bytes, direction = 'Quốc tế')    * 8 / dur AS `Quốc tế`,
  sumIf(bytes, direction = 'Trong nước') * 8 / dur AS `Trong nước`,
  sum(bytes) * 8 / dur AS `Tổng`
FROM panos.flows
WHERE $__timeFilter(ts) AND direction IN ('Quốc tế', 'Trong nước') AND ('${client}' = '' OR local_ip = '${client}')
GROUP BY `Máy`
ORDER BY `Tổng` DESC
LIMIT 20;

-- Ung dung dang dung nhieu nhat, 5 phut (NetFlow)
WITH dateDiff('second', $__fromTime, $__toTime) AS dur
SELECT
  if(app = '', '(chưa rõ)', app) AS `Ứng dụng`,
  sumIf(bytes, direction = 'Quốc tế')    * 8 / dur AS `Quốc tế`,
  sumIf(bytes, direction = 'Trong nước') * 8 / dur AS `Trong nước`,
  sum(bytes) * 8 / dur AS `Tổng`
FROM panos.flows
WHERE $__timeFilter(ts) AND direction IN ('Quốc tế', 'Trong nước') AND ('${client}' = '' OR local_ip = '${client}')
GROUP BY `Ứng dụng`
ORDER BY `Tổng` DESC
LIMIT 20;

-- Ty le quoc te / trong nuoc (traffic log)
SELECT
  sumIf(bytes_sent + bytes_received, direction = 'Quốc tế')    AS `Quốc tế`,
  sumIf(bytes_sent + bytes_received, direction = 'Trong nước') AS `Trong nước`
FROM panos.traffic
WHERE $__timeFilter(ts) AND ('${client}' = '' OR src = '${client}');

-- Top 20 ung dung (traffic log)
SELECT
  app AS `Ứng dụng`,
  sumIf(bytes_sent + bytes_received, direction = 'Quốc tế')    AS `Quốc tế`,
  sumIf(bytes_sent + bytes_received, direction = 'Trong nước') AS `Trong nước`,
  round(100 * `Quốc tế` / nullIf(`Quốc tế` + `Trong nước`, 0), 1) AS `% quốc tế`
FROM panos.traffic
WHERE $__timeFilter(ts) AND direction IN ('Quốc tế', 'Trong nước') AND ('${client}' = '' OR src = '${client}')
GROUP BY `Ứng dụng`
ORDER BY `Quốc tế` DESC
LIMIT 20;

-- Top 15 nguoi dung quoc te (traffic log)
SELECT if(src_user = '', src, src_user) AS `Người dùng`, sum(bytes_sent + bytes_received) AS `Quốc tế`
FROM panos.traffic
WHERE $__timeFilter(ts) AND direction = 'Quốc tế' AND ('${client}' = '' OR src = '${client}')
GROUP BY `Người dùng`
ORDER BY `Quốc tế` DESC
LIMIT 15;

-- Ung dung -> huong (traffic log)
SELECT app AS source, direction AS target, sum(bytes_sent + bytes_received) AS value
FROM panos.traffic
WHERE $__timeFilter(ts) AND direction IN ('Quốc tế', 'Trong nước') AND ('${client}' = '' OR src = '${client}')
GROUP BY source, target
ORDER BY value DESC
LIMIT 40;

-- Theo ngay, 30 ngay (bang tong hop)
SELECT
  toDate(hour) AS `Ngày`,
  sumIf(bytes_sent + bytes_received, direction = 'Quốc tế')    AS `Quốc tế`,
  sumIf(bytes_sent + bytes_received, direction = 'Trong nước') AS `Trong nước`
FROM panos.traffic_hourly
WHERE $__timeFilter(hour)
GROUP BY `Ngày`
ORDER BY `Ngày`;

