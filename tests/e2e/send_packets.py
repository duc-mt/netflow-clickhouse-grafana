#!/usr/bin/env python3
"""Gửi gói thử tới Vector: syslog (Palo Alto 5514, FortiGate 5515, Check Point 5516) và NetFlow v5 / v9 / IPFIX (2055)."""
import socket, struct, time, ipaddress

def udp(port, payload):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.sendto(payload, ('127.0.0.1', port)); s.close()

def ip(a): return int(ipaddress.IPv4Address(a)).to_bytes(4, 'big')

# ---------------- Syslog ----------------
NOW_VN = time.strftime('%Y/%m/%d %H:%M:%S', time.gmtime(time.time() + 7 * 3600))
palo = ('<14>%s e2e panos: {"rtime":"%s","src":"10.99.99.99","dst":"8.8.8.8","src_user":"e2e-palo","app":"ssl","category":"any",'
        '"rule":"r1","from_zone":"lan","to_zone":"wan","dst_country":"US","dport":443,"bytes_sent":100,"bytes_received":200,"elapsed":1,"subtype":"end"}') % (NOW_VN, NOW_VN)
udp(5514, palo.encode())

fg_date, fg_time = NOW_VN.split(' ')[0].replace('/', '-'), NOW_VN.split(' ')[1]
forti = ('<189>date=%s time=%s devname="FGT-E2E" devid="FG100F0000" tz="+0700" logid="0000000013" type="traffic" subtype="forward" '
         'level="notice" vd="root" srcip=10.1.1.10 srcport=51234 srcintf="lan" dstip=8.8.4.4 dstport=443 dstintf="wan1" dstcountry="United States" '
         'action="close" policyid=5 policyname="LAN-to-WAN" app="SSL" appcat="Network.Service" duration=12 sentbyte=1234 rcvdbyte=5678 user="DOM\\alice"') % (fg_date, fg_time)
udp(5515, (forti + '\n').encode())                          # có \n cuối như rsyslog/logger thường gửi
forti_start = forti.replace('action="close"', 'action="start"')       # phải bị bỏ
udp(5515, forti_start.encode())

epoch = int(time.time())
def cp(loguid, sent, recv, seq):
    return ('<134>1 2026-10-23T03:15:00Z gw1 CheckPoint 2112 - [action:"Accept"; loguid:"%s"; origin:"192.168.1.1"; sequencenum:"%d"; time:"%d"; '
            'dst:"1.1.1.1"; src:"10.1.1.50"; service:"443"; proto:"6"; product:"VPN-1 & FireWall-1"; rule_name:"R1"; sent_bytes:"%d"; received_bytes:"%d"]') % (loguid, seq, epoch, sent, recv)
udp(5516, cp('{0xaaaa,0x0,0x1,0x2}', 100, 1000, 1).encode())          # bản đầu
time.sleep(0.3)
udp(5516, cp('{0xaaaa,0x0,0x1,0x2}', 300, 3000, 2).encode())          # bản cập nhật cùng loguid -> phải gộp, lấy max
udp(5516, cp('{0xbbbb,0x0,0x1,0x2}', 50, 60, 1).encode())             # kết nối khác

# ---------------- NetFlow ----------------
def v5():
    hdr = struct.pack('!HHIIIIBBH', 5, 2, 123456, epoch, 0, 1, 0, 0, 0)
    def rec(src, dst, pk, octets, sp, dp):
        return ip(src) + ip(dst) + ip('0.0.0.0') + struct.pack('!HHIIIIHHBBBBHHBBH', 1, 2, pk, octets, 1000, 2000, sp, dp, 0, 0x10, 6, 0, 0, 0, 24, 24, 0)
    return hdr + rec('10.5.5.5', '9.9.9.9', 10, 777, 40000, 80) + rec('9.9.9.9', '10.5.5.5', 20, 8888, 80, 40000)

def flowset(fid, body):
    pad = (-(4 + len(body))) % 4
    return struct.pack('!HH', fid, 4 + len(body) + pad) + body + b'\x00' * pad

def v9_generic():
    # Template kiểu firewall/router thông thường (không có trường riêng của hãng nào)
    fields = [(1, 4), (2, 4), (4, 1), (7, 2), (8, 4), (10, 4), (11, 2), (12, 4), (14, 4), (21, 4), (22, 4)]
    tpl = struct.pack('!HH', 256, len(fields)) + b''.join(struct.pack('!HH', t, l) for t, l in fields)
    def rec(src, dst, octets, sp, dp):
        return struct.pack('!IIB', octets, 10, 6) + struct.pack('!H', sp) + ip(src) + struct.pack('!I', 1) + struct.pack('!H', dp) + ip(dst) + struct.pack('!I', 2) + struct.pack('!II', 2000, 1000)
    data = rec('10.1.1.10', '8.8.8.8', 5000, 51234, 443) + rec('8.8.8.8', '10.1.1.10', 90000, 443, 51234)
    body = flowset(0, tpl) + flowset(256, data)
    return struct.pack('!HHIIII', 9, 3, 123456, epoch, 1, 77) + body

def v9_palo_like():
    # Template có các trường riêng của Palo Alto: flowId 148, firewallEvent 233, postNAT 225/226, App-ID 56701, User-ID 56702
    fields = [(1, 4), (2, 4), (4, 1), (7, 2), (8, 4), (10, 4), (11, 2), (12, 4), (14, 4), (21, 4), (22, 4),
              (148, 4), (233, 1), (225, 4), (226, 4), (56701, 32), (56702, 64)]
    tpl = struct.pack('!HH', 257, len(fields)) + b''.join(struct.pack('!HH', t, l) for t, l in fields)
    app = b'ssl'.ljust(32, b'\x00'); user = b'DOM\\alice'.ljust(64, b'\x00')
    rec = (struct.pack('!IIB', 70000, 50, 6) + struct.pack('!H', 443) + ip('8.8.8.8') + struct.pack('!I', 2) + struct.pack('!H', 51999) + ip('203.0.113.5')
           + struct.pack('!I', 1) + struct.pack('!II', 2000, 1000) + struct.pack('!I', 424242) + struct.pack('!B', 2) + ip('0.0.0.0') + ip('10.1.1.20') + app + user)
    body = flowset(0, tpl) + flowset(257, rec)
    return struct.pack('!HHIIII', 9, 2, 123456, epoch, 2, 88) + body

def ipfix():
    fields = [(1, 8), (2, 8), (4, 1), (7, 2), (8, 4), (10, 4), (11, 2), (12, 4), (14, 4), (152, 8), (153, 8)]
    tpl_rec = struct.pack('!HH', 258, len(fields)) + b''.join(struct.pack('!HH', t, l) for t, l in fields)
    tset = struct.pack('!HH', 2, 4 + len(tpl_rec)) + tpl_rec
    ms = epoch * 1000
    rec = (struct.pack('!QQB', 12345, 30, 17) + struct.pack('!H', 5353) + ip('10.7.7.7') + struct.pack('!I', 1) + struct.pack('!H', 53) + ip('1.0.0.1') + struct.pack('!I', 2) + struct.pack('!QQ', ms - 1000, ms))
    dset = struct.pack('!HH', 258, 4 + len(rec)) + rec
    msg = tset + dset
    return struct.pack('!HHIII', 10, 16 + len(msg), epoch, 1, 99) + msg

for name, pkt in [('v5', v5()), ('v9-generic', v9_generic()), ('v9-palo', v9_palo_like()), ('ipfix', ipfix())]:
    udp(2055, pkt); time.sleep(0.4)
print('đã gửi: palo, fortigate (close+start), checkpoint x3, netflow v5/v9/v9-palo/ipfix')
