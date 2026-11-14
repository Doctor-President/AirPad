#!/usr/bin/env python3
"""Mac D fix-up B2 — a Brave Search stand-in: answers /res/v1/web|news/search with one result and logs whether the
   request's X-Subscription-Token equals the EXPECTED dummy key (never the key itself).  brave_stub.py <port> <expected>"""
import sys, json
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
PORT, EXPECTED = int(sys.argv[1]), sys.argv[2]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        tok = self.headers.get('X-Subscription-Token', '')
        print(f"request {self.path.split('?')[0]} token={'match' if tok == EXPECTED else ('absent' if not tok else 'other')}", flush=True)
        r = {"title": "Stub result", "url": "https://example.com/stub", "description": "A stub search result.", "age": "1 day ago"}
        body = json.dumps({"web": {"results": [r]}, "results": [r]}).encode()
        self.send_response(200); self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)

ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
