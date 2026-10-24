#!/usr/bin/env python3
"""ClickHouse giả (chỉ dùng để kiểm thử): nhận HTTP từ Vector và ghi mọi INSERT ra file JSONL.

    python3 fake_clickhouse.py <file_ra.jsonl> [cổng]
"""
import gzip
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlparse

OUT = sys.argv[1] if len(sys.argv) > 1 else 'received.jsonl'
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8123


class Handler(BaseHTTPRequestHandler):
    def _reply(self, body=b'Ok.\n'):
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):          # healthcheck của Vector
        self._reply(b'1\n')

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        data = self.rfile.read(length) if length else b''
        if self.headers.get('Content-Encoding') == 'gzip':
            data = gzip.decompress(data)
        qs = parse_qs(urlparse(self.path).query)
        query = unquote(qs.get('query', [''])[0]) or data.decode('utf-8', 'replace')[:200]
        record = {
            'query': query,
            'settings': {k: v[0] for k, v in qs.items() if k != 'query'},
            'body': data.decode('utf-8', 'replace'),
        }
        with open(OUT, 'a', encoding='utf-8') as fh:
            fh.write(json.dumps(record, ensure_ascii=False) + '\n')
        self._reply()

    def log_message(self, *args):
        pass


ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
