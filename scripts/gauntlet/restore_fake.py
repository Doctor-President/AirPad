#!/usr/bin/env python3
# live-18 (0a) — a fake "AirPad Host + Ollama" pair for test_restore.sh, on scratch ports only. It reproduces the
# behaviour the restore depends on, nothing more:
#   ollama <port> <dir>               /api/version · /api/ps · /api/tags · /api/generate (load with keep_alive + num_ctx)
#   host <port> <ollama-port> <dir>   on start: if an Ollama already answers on <ollama-port> it ATTACHES (does not
#                                     spawn — the real Host's "[ollama] already serving … attaching"); otherwise it
#                                     spawns its own fake Ollama, and kills it when it quits (as the real Host does).
#                                     /health · /v1/models/load (always-on: keep_alive -1, num_ctx 20480, marks held
#                                     in <dir>/residency.json) · /v1/models/eject.
#                                     FAKE_HOST_NO_SPAWN=1 → never spawns (an Ollama that can't start).
#   ctl running|open|quit <dir> <host-port> <ollama-port>
#                                     the Host-control commands the restore runs: `open` is a no-op when the Host is
#                                     already running (as `open -a` is); `quit` stops it (and the Ollama it spawned).
# State lives in <dir>/ps.json (what the "Ollama" has resident), so a restarted Ollama starts empty, as a real one does.
import json, os, signal, subprocess, sys, time, urllib.request
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

def answers(port):
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/api/version", timeout=1).read(); return True
    except Exception:
        return False

def serve(port, handler):
    ThreadingHTTPServer.allow_reuse_address = True
    ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()

class Base(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

def run_ollama(port, d):
    ps = os.path.join(d, "ps.json")
    json.dump({"models": []}, open(ps, "w"))   # a fresh Ollama has nothing resident
    class H(Base):
        def do_GET(self):
            if self.path == "/api/version": return self.send(200, {"version": "fake"})
            if self.path == "/api/ps": return self.send(200, json.load(open(ps)))
            if self.path == "/api/tags":
                return self.send(200, {"models": [{"name": n, "digest": "fake"} for n in
                                                  ("qwen3:4b-instruct-2507-q4_K_M", "qwen3:8b-q4_K_M")]})
            self.send(404, {})
        def do_POST(self):
            if self.path != "/api/generate": return self.send(404, {})
            b = self.body(); name = b["model"]; ka = b.get("keep_alive", "15m")
            ctx = (b.get("options") or {}).get("num_ctx", 4096)
            state = json.load(open(ps)); state["models"] = [m for m in state["models"] if m["name"] != name]
            if ka not in (0, "0"):
                if ka in (-1, "-1"): exp = "2319-01-01T00:00:00Z"
                else:
                    secs = int(ka) if isinstance(ka, int) else int(str(ka).rstrip("s")) if str(ka).endswith("s") else int(str(ka).rstrip("m")) * 60
                    exp = (datetime.now(timezone.utc) + timedelta(seconds=secs)).isoformat()
                state["models"].append({"name": name, "model": name, "context_length": ctx, "expires_at": exp})
            json.dump(state, open(ps, "w")); self.send(200, {"done": True})
    serve(port, H)

def run_host(port, oport, d):
    child = None
    if answers(oport):
        print(f"[ollama] already serving on 127.0.0.1:{oport} — attaching (not spawning)", flush=True)
    elif os.environ.get("FAKE_HOST_NO_SPAWN") != "1":
        child = subprocess.Popen([sys.executable, __file__, "ollama", str(oport), d])
        print(f"[ollama] spawned pid={child.pid}", flush=True)
    def bye(*_):
        if child: child.terminate()
        sys.exit(0)
    signal.signal(signal.SIGTERM, bye); signal.signal(signal.SIGINT, bye)
    res = os.path.join(d, "residency.json")
    if not os.path.exists(res): json.dump({"mode": "always-on", "held": []}, open(res, "w"))
    def ollama(path, body):
        req = urllib.request.Request(f"http://127.0.0.1:{oport}{path}", json.dumps(body).encode(),
                                     {"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=5).read()
    class H(Base):
        def do_GET(self):
            if self.path == "/health": return self.send(200, {"ok": True, "hostPublicKey": "fake"})
            self.send(404, {})
        def do_POST(self):
            if self.headers.get("Authorization") != "Bearer fake-token": return self.send(401, {})
            b = self.body(); name = b.get("catalogId") or b.get("model")
            try:
                if self.path == "/v1/models/load":
                    ollama("/api/generate", {"model": name, "keep_alive": -1, "options": {"num_ctx": 20480}})
                    r = json.load(open(res)); r["held"] = sorted(set(r["held"]) | {name}); json.dump(r, open(res, "w"))
                    return self.send(200, {"result": "loaded", "tag": name})
                if self.path == "/v1/models/eject":
                    ollama("/api/generate", {"model": name, "keep_alive": 0})
                    r = json.load(open(res)); r["held"] = [h for h in r["held"] if h != name]; json.dump(r, open(res, "w"))
                    return self.send(200, {"result": "ejected"})
            except Exception:
                return self.send(502, {"error": {"code": "upstream_error", "message": "load failed"}})
            self.send(404, {})
    serve(port, H)

def ctl(cmd, d, hport, oport):
    pidf = os.path.join(d, "host.pid")
    def alive():
        try: os.kill(int(open(pidf).read()), 0); return True
        except Exception: return False
    if cmd == "running": sys.exit(0 if alive() else 1)
    if cmd == "open":
        if alive(): return
        p = subprocess.Popen([sys.executable, __file__, "host", hport, oport, d],
                             stdout=open(os.path.join(d, "host.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
        open(pidf, "w").write(str(p.pid))
    if cmd == "quit" and alive():
        pid = int(open(pidf).read()); os.kill(pid, signal.SIGTERM)
        for _ in range(50):
            try: os.kill(pid, 0); time.sleep(0.1)
            except Exception: break

if __name__ == "__main__":
    kind = sys.argv[1]
    if kind == "ctl": ctl(*sys.argv[2:6])
    if kind == "ollama": run_ollama(int(sys.argv[2]), sys.argv[3])
    elif kind == "host": run_host(int(sys.argv[2]), int(sys.argv[3]), sys.argv[4])
