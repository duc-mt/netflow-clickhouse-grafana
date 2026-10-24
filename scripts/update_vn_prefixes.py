#!/usr/bin/env python3
"""Tao danh sach dai IP Viet Nam cho ClickHouse (dictionary panos.vn_prefix).

Nguon: file delegated cua APNIC (cap nhat hang ngay).
Ket qua: CSV co 2 cot prefix,label:
  - "Trong nước" : dai IPv4 APNIC cap cho VN
  - "Nội bộ"     : dai IP rieng (RFC1918, CGNAT)
  - overrides.csv: dai IP muon ep nhan (vi du ep mot dai la "Trong nước")
IP khong khop dai nao se duoc ClickHouse gan "Quốc tế".

Chay hang ngay bang cron, vi du:
  15 3 * * * /usr/bin/python3 /opt/netflow-clickhouse-grafana/scripts/update_vn_prefixes.py
"""
import argparse
import csv
import ipaddress
import os
import sys
import urllib.request

APNIC_URL = "https://ftp.apnic.net/stats/apnic/delegated-apnic-latest"
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "..", "clickhouse", "user_files", "vn_prefixes.csv")
DEFAULT_OVERRIDES = os.path.join(HERE, "overrides.csv")

PRIVATE = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10"]


def load_delegated(source):
    if source.startswith("http"):
        with urllib.request.urlopen(source, timeout=120) as r:
            return r.read().decode("utf-8", "replace").splitlines()
    with open(source, encoding="utf-8") as f:
        return f.read().splitlines()


def vn_networks(lines):
    nets = []
    for line in lines:
        p = line.strip().split("|")
        if len(p) < 7 or p[1] != "VN" or p[2] != "ipv4":
            continue
        if p[6] not in ("allocated", "assigned"):
            continue
        start = ipaddress.IPv4Address(p[3])
        end = start + int(p[4]) - 1
        nets.extend(ipaddress.summarize_address_range(start, end))
    return list(ipaddress.collapse_addresses(nets))


def load_overrides(path):
    rows = []
    if not os.path.exists(path):
        return rows
    with open(path, encoding="utf-8") as f:
        for r in csv.reader(f):
            if not r or r[0].strip().startswith("#") or r[0].strip() == "prefix":
                continue
            net = ipaddress.ip_network(r[0].strip(), strict=False)
            if net.version != 4:
                continue  # bang hien chi phan loai IPv4
            rows.append((str(net), r[1].strip()))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", default=APNIC_URL, help="URL hoac file delegated-apnic")
    ap.add_argument("--out", default=DEFAULT_OUT)
    ap.add_argument("--overrides", default=DEFAULT_OVERRIDES)
    a = ap.parse_args()

    vn = vn_networks(load_delegated(a.source))
    if len(vn) < 100:  # bao ve: file tai ve loi thi khong ghi de danh sach cu
        sys.exit(f"Chi tim thay {len(vn)} dai VN, nghi ngo file nguon loi. Khong cap nhat.")

    rows = [(n, "Nội bộ") for n in PRIVATE]
    rows += [(str(n), "Trong nước") for n in vn]
    rows += load_overrides(a.overrides)  # dai cu the hon se thang (longest prefix match)

    os.makedirs(os.path.dirname(os.path.abspath(a.out)), exist_ok=True)
    tmp = a.out + ".tmp"
    with open(tmp, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["prefix", "label"])
        w.writerows(rows)
    os.replace(tmp, a.out)
    print(f"Da ghi {len(rows)} dai IP ({len(vn)} dai VN) vao {a.out}")


if __name__ == "__main__":
    main()
