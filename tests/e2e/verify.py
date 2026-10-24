#!/usr/bin/env python3
"""Kiểm tra các hàng mà Vector đã gửi tới (ClickHouse giả). Trả về mã thoát 0 nếu mọi kiểm tra đạt.

    python3 verify.py <file_nhan_duoc.jsonl>
"""
import json
import sys

path = sys.argv[1]
rows = [json.loads(line) for line in open(path, encoding='utf-8')]

FLOWS_COLS = {'ts', 'exporter', 'src', 'dst', 'nat_src', 'nat_dst', 'src_port', 'dst_port', 'proto', 'in_if', 'out_if',
              'flow_id', 'fw_event', 'app', 'user', 'bytes', 'packets'}
TRAFFIC_COLS = {'ts', 'src', 'dst', 'src_user', 'app', 'category', 'rule', 'from_zone', 'to_zone', 'dst_country', 'dport',
                'bytes_sent', 'bytes_received', 'elapsed'}
OPTIONAL_TRAFFIC = {'vendor', 'device'}      # chỉ được ghi sau migration 04 (nếu chưa có cột thì ClickHouse bỏ qua)

flows, traffic = [], []
for r in rows:
    target = flows if '"flows"' in r['query'] else traffic if '"traffic"' in r['query'] else None
    if target is None:
        continue
    assert r['settings'].get('input_format_skip_unknown_fields') == '1', 'sink phải bật skip_unknown_fields'
    for line in r['body'].strip().splitlines():
        target.append(json.loads(line))

results = []
def check(name, cond, detail=''):
    results.append((name, bool(cond)))
    print(('PASS  ' if cond else 'FAIL  ') + name + ('' if cond else f'   -> {detail}'))

# ---- Schema: mọi khóa phải khớp cột đã có ----
check('flows: mọi khóa JSON đều là cột của panos.flows', all(set(x) <= FLOWS_COLS for x in flows), [set(x) - FLOWS_COLS for x in flows])
check('traffic: mọi khóa là cột hiện có hoặc vendor/device', all(set(x) <= TRAFFIC_COLS | OPTIONAL_TRAFFIC for x in traffic),
      [set(x) - TRAFFIC_COLS - OPTIONAL_TRAFFIC for x in traffic])
check('traffic: kiểu số nguyên đúng (dport, bytes_*, elapsed, ts)',
      all(isinstance(x[k], int) for x in traffic for k in ('dport', 'bytes_sent', 'bytes_received', 'elapsed', 'ts')))
check('flows: kiểu số nguyên đúng', all(isinstance(x[k], int) for x in flows for k in ('bytes', 'packets', 'src_port', 'dst_port', 'ts')))

# ---- NetFlow (pipeline gốc, đa phiên bản/đa hãng) ----
def flow(**kw):
    return [x for x in flows if all(x.get(k) == v for k, v in kw.items())]

check('NetFlow v5: 2 chiều được giải mã', flow(src='10.5.5.5', dst='9.9.9.9', bytes=777, proto='TCP') and flow(src='9.9.9.9', dst='10.5.5.5', bytes=8888))
check('NetFlow v9 (exporter không phải Palo Alto): app/user/NAT rỗng',
      any(x['app'] == '' and x['user'] == '' and x['nat_dst'] == '' for x in flow(src='10.1.1.10', dst='8.8.8.8', bytes=5000)))
check('NetFlow v9 chiều tải xuống', flow(src='8.8.8.8', dst='10.1.1.10', bytes=90000))
palo = flow(flow_id=424242)
check('NetFlow v9 kiểu Palo Alto: App-ID, User-ID, NAT, flow_id, fw_event',
      palo and palo[0]['app'] == 'ssl' and palo[0]['user'] == 'DOM\\alice' and palo[0]['nat_dst'] == '10.1.1.20' and palo[0]['fw_event'] == 2, palo)
check('IPFIX (UDP)', flow(src='10.7.7.7', dst='1.0.0.1', bytes=12345, proto='UDP'))

# ---- Syslog ----
p = [x for x in traffic if x['src_user'] == 'e2e-palo']
check('Palo Alto syslog (pipeline gốc): đúng 1 hàng, không có vendor', len(p) == 1 and 'vendor' not in p[0] and p[0]['bytes_sent'] == 100, p)
f = [x for x in traffic if x.get('vendor') == 'fortigate']
check('FortiGate: chỉ log close được ghi (log start bị bỏ) -> đúng 1 hàng', len(f) == 1, f)
check('FortiGate: trường được ánh xạ đúng',
      f and f[0]['src'] == '10.1.1.10' and f[0]['dst'] == '8.8.4.4' and f[0]['dport'] == 443 and f[0]['bytes_sent'] == 1234
      and f[0]['bytes_received'] == 5678 and f[0]['rule'] == 'LAN-to-WAN' and f[0]['device'] == 'FGT-E2E' and f[0]['src_user'] == 'DOM\\alice', f)
c = [x for x in traffic if x.get('vendor') == 'checkpoint']
check('Check Point: 2 bản ghi cùng loguid được gộp, tổng cộng 2 hàng', len(c) == 2, c)
merged = [x for x in c if x['bytes_sent'] == 300]
check('Check Point: lấy byte lớn nhất của bản cập nhật, dport không bị cộng dồn',
      merged and merged[0]['bytes_received'] == 3000 and merged[0]['dport'] == 443, merged)

failed = [n for n, ok in results if not ok]
print(f"\nKẾT QUẢ E2E: {len(results) - len(failed)}/{len(results)} đạt")
sys.exit(1 if failed else 0)
