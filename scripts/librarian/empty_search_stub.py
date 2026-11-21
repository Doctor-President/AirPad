#!/usr/bin/env python3
"""Sweep 2a — a search provider that finds nothing: every Brave web / news request gets 200 with zero results.
   python3 empty_search_stub.py <port>   (local only; used by web_bench.sh empty)"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def _send(self):
        body = json.dumps({"web": {"results": []}, "results": []}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        print(self.command, self.path.split("?")[0], flush=True)
    def do_GET(self): self._send()
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0))); self._send()
    def log_message(self, *a): pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
