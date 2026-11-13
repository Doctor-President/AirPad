#!/usr/bin/env python3
"""Mac D0.1 harness — a server that lists one model (generic OpenAI shape) but never answers a chat.
   silent_server.py [port=8790]. Proves the own-server-first deadline hands the entry to Apple Intelligence."""
import sys, time, json
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.rstrip('/') == '/v1/models':
            body = json.dumps({"data": [{"id": "silent-model", "object": "model"}]}).encode()
            self.send_response(200); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def do_POST(self):
        print("chat request held", flush=True)
        time.sleep(120)

ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 8790), H).serve_forever()
